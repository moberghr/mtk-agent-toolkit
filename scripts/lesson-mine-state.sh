#!/usr/bin/env bash
set -euo pipefail

# lesson-mine-state.sh — deterministic state for `lessons mine`.
#
# Mining used to re-read the same last-7-days window on every sweep, re-propose
# candidates the engineer had already rejected, and trust quotes nobody had
# checked against the transcript. This script holds the three pieces of state
# that stop that, under <project root>/.mtk/lessons/:
#
#   mine-watermark.json  {"<session>.jsonl": byte_offset} — how far each
#                        transcript has been mined. Only ever moves forward.
#   decisions.md         append-only ledger, one line per ruled candidate:
#                        "- <id> accepted|rejected <YYYY-MM-DD> — <reason>"
#   watching.jsonl       append-only, one {"id","session","quote","date"} per
#                        session that backs a candidate still below the
#                        two-session floor, so a later sweep can count it.
#
# Subcommands:
#   window [--days N] [--projects-dir D]
#       Print "<session_id>\t<path>\t<from_offset>" for every transcript under
#       ${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<sanitized-root>/*.jsonl that
#       has bytes past its watermark. A file never mined falls back to the
#       --days window (default 7, by mtime) and starts at offset 0.
#       --projects-dir overrides the transcript directory (test seam). A
#       missing or transcript-less directory is an empty window, named on stderr.
#   advance <session_file|session_id> <offset>
#       Move that transcript's watermark forward. Exit 1 on a backward move.
#   id <text...>
#       Print the stable candidate id mine-<sha256(lowercased,
#       whitespace-collapsed text)[:12]>.
#   decide <id> accepted|rejected <reason...>
#       Append one ledger line to decisions.md. Never rewrites the file.
#   filter <id>...
#       Print the ids that have no recorded decision, in input order.
#   watch <id> <session_id|path> <quote>
#       Append one watching record (stored by session id). The same id+session
#       is recorded once. Not a decision: `filter` still passes the id.
#   evidence [--projects-dir D] <session_id|path> <quote>
#       Exit 0 iff <quote> is a substring of one DECODED message text in that
#       transcript (each line json-decoded, message content strings walked,
#       malformed lines skipped), else exit 1. Raw `grep -F` on JSONL misses
#       quotes containing `"`, newlines or non-ASCII, which JSON escapes.
#   evidence-count [--projects-dir D] [--id <id>] [<session> <quote>]...
#       Print how many DISTINCT sessions have a pair whose quote passes
#       `evidence`. With --id, that id's watching records join the pairs and
#       are re-verified the same way; a record whose transcript is gone does
#       not count. Each skipped pair prints "transcript not found: <x>" on
#       stderr. The A2/A3 ">= 2 sessions" floor reads this number.
#
# Project root: $CLAUDE_PROJECT_DIR, else the git top level, else pwd (same as
# lesson-anchors.sh). Usage errors and a missing python3 exit 2.

if ! command -v python3 >/dev/null 2>&1; then
  echo "lesson-mine-state: python3 is required (S3.3 baseline) — install it and re-run" >&2
  exit 2
fi

case "${1:-}" in
  ""|-h|--help) sed -n '4,52p' "$0" | sed 's/^# \{0,1\}//'; [ -n "${1:-}" ] && exit 0; exit 2 ;;
esac

ROOT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

exec python3 - "$ROOT_DIR" "$@" <<'PY'
import datetime
import hashlib
import json
import os
import re
import sys
import time

root = sys.argv[1]
cmd = sys.argv[2]
args = sys.argv[3:]

STATE_DIR = os.path.join(root, ".mtk", "lessons")
WATERMARK = os.path.join(STATE_DIR, "mine-watermark.json")
DECISIONS = os.path.join(STATE_DIR, "decisions.md")
WATCHING = os.path.join(STATE_DIR, "watching.jsonl")
ID_RE = re.compile(r"^mine-[0-9a-f]{12}$")
LEDGER_RE = re.compile(r"^- (mine-[0-9a-f]{12}) (accepted|rejected) ")


def die(msg, code=2):
    sys.stderr.write("lesson-mine-state: %s\n" % msg)
    sys.exit(code)


def default_projects_dir():
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    # Claude Code names the per-project directory after the cwd with every
    # non-alphanumeric character replaced by '-'.
    return os.path.join(cfg, "projects", re.sub(r"[^A-Za-z0-9]", "-", root))


def take_projects_dir(argv):
    """Strip an optional --projects-dir D from argv; return (dir, rest)."""
    pdir, rest, i = None, [], 0
    while i < len(argv):
        if argv[i] == "--projects-dir":
            if i + 1 >= len(argv):
                die("--projects-dir needs a directory")
            pdir = argv[i + 1]
            i += 2
            continue
        rest.append(argv[i])
        i += 1
    return (pdir or default_projects_dir()), rest


def session_key(ref):
    """Watermark key for a transcript: its file name, so the key survives a
    moved config dir. Accepts a path or a bare session id."""
    base = os.path.basename(ref)
    return base if base.endswith(".jsonl") else base + ".jsonl"


def load_watermarks():
    try:
        with open(WATERMARK, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        die("cannot read %s: %s" % (WATERMARK, exc))
    if not isinstance(data, dict):
        die("%s is not a JSON object" % WATERMARK)
    return data


def write_watermarks(data):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = WATERMARK + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, WATERMARK)


def resolve_transcript(ref, pdir):
    if os.path.isfile(ref):
        return ref
    cand = os.path.join(pdir, session_key(ref))
    return cand if os.path.isfile(cand) else None


def message_texts(path):
    """Yield every decoded text string of every message in a transcript."""

    def walk(node):
        if isinstance(node, str):
            yield node
        elif isinstance(node, list):
            for item in node:
                yield from walk(item)
        elif isinstance(node, dict):
            for key in ("text", "content"):
                if key in node:
                    yield from walk(node[key])

    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue  # malformed line: skipped, never fatal
            if not isinstance(obj, dict):
                continue
            msg = obj.get("message")
            if isinstance(msg, dict) and "content" in msg:
                yield from walk(msg["content"])
            elif isinstance(msg, str):
                yield msg


def quote_in(path, quote):
    return any(quote in text for text in message_texts(path))


def need_quote(quote):
    if quote == "":
        die("an empty quote matches everything — pass the verbatim excerpt")


def cmd_window(argv):
    pdir, rest = take_projects_dir(argv)
    days = 7
    i = 0
    while i < len(rest):
        if rest[i] == "--days" and i + 1 < len(rest):
            if not re.fullmatch(r"[0-9]+", rest[i + 1]):
                die("--days must be a non-negative integer")
            days = int(rest[i + 1])
            i += 2
        else:
            die("window: unknown argument %r" % rest[i])
    # No transcripts for this project is an empty window, not an error, but
    # name the directory: a wrong sanitized path looks exactly like "nothing new".
    if not os.path.isdir(pdir):
        sys.stderr.write("lesson-mine-state: projects dir not found: %s\n" % pdir)
        return 0
    names = [n for n in os.listdir(pdir)
             if n.endswith(".jsonl") and os.path.isfile(os.path.join(pdir, n))]
    if not names:
        sys.stderr.write("lesson-mine-state: no transcripts in projects dir: %s\n" % pdir)
        return 0
    marks = load_watermarks()
    cutoff = time.time() - days * 86400
    rows = []
    for name in names:
        path = os.path.join(pdir, name)
        st = os.stat(path)
        if name in marks:
            start = int(marks[name])
            if st.st_size <= start:
                continue
        else:
            if st.st_mtime < cutoff:
                continue
            start = 0
        rows.append((st.st_mtime, path, name[: -len(".jsonl")], start))
    for _, path, sid, start in sorted(rows):
        print("%s\t%s\t%d" % (sid, path, start))
    return 0


def cmd_advance(argv):
    if len(argv) != 2:
        die("usage: advance <session_file|session_id> <offset>")
    ref, off = argv
    if not re.fullmatch(r"[0-9]+", off):
        die("advance: offset must be a non-negative integer byte count")
    key, new = session_key(ref), int(off)
    marks = load_watermarks()
    old = int(marks.get(key, 0))
    if new < old:
        die("advance: refusing to move %s backward (%d -> %d)" % (key, old, new), 1)
    if key not in marks or new > old:
        marks[key] = new
        write_watermarks(marks)
    return 0


def cmd_id(argv):
    text = " ".join(argv)
    norm = " ".join(text.lower().split())
    if not norm:
        die("usage: id <rule text>")
    print("mine-" + hashlib.sha256(norm.encode("utf-8")).hexdigest()[:12])
    return 0


def cmd_decide(argv):
    if len(argv) < 3:
        die("usage: decide <mine-id> accepted|rejected <reason>")
    cid, verdict, reason = argv[0], argv[1], " ".join(" ".join(argv[2:]).split())
    if not ID_RE.match(cid):
        die("decide: %r is not a mine-<hash12> id (use `id <text>`)" % cid)
    if verdict not in ("accepted", "rejected"):
        die("decide: verdict must be accepted or rejected")
    if not reason:
        die("decide: a reason is required")
    os.makedirs(STATE_DIR, exist_ok=True)
    new = not os.path.exists(DECISIONS)
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    with open(DECISIONS, "a", encoding="utf-8") as fh:
        if new:
            fh.write("# Lesson-mining decisions (append-only; written by lesson-mine-state.sh)\n\n")
        fh.write("- %s %s %s — %s\n" % (cid, verdict, today, reason))
    return 0


def cmd_filter(argv):
    decided = set()
    try:
        with open(DECISIONS, encoding="utf-8") as fh:
            for line in fh:
                m = LEDGER_RE.match(line)
                if m:
                    decided.add(m.group(1))
    except FileNotFoundError:
        pass
    seen = set()
    for cid in argv:
        if cid in decided or cid in seen:
            continue
        seen.add(cid)
        print(cid)
    return 0


def load_watching(cid=None):
    """Watching records, optionally only those for one id. Malformed lines are
    skipped with a stderr note, never fatal."""
    out = []
    try:
        with open(WATCHING, encoding="utf-8") as fh:
            for n, line in enumerate(fh, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    rec = None
                if not (isinstance(rec, dict) and isinstance(rec.get("id"), str)
                        and isinstance(rec.get("session"), str)
                        and isinstance(rec.get("quote"), str)):
                    sys.stderr.write("lesson-mine-state: %s:%d malformed, skipped\n" % (WATCHING, n))
                    continue
                if cid is None or rec["id"] == cid:
                    out.append(rec)
    except FileNotFoundError:
        pass
    except OSError as exc:
        die("cannot read %s: %s" % (WATCHING, exc))
    return out


def session_id(ref):
    return session_key(ref)[: -len(".jsonl")]


def cmd_watch(argv):
    if len(argv) != 3:
        die("usage: watch <mine-id> <session_id|path> <quote>")
    cid, ref, quote = argv
    if not ID_RE.match(cid):
        die("watch: %r is not a mine-<hash12> id (use `id <text>`)" % cid)
    need_quote(quote)
    sid = session_id(ref)
    if not sid:
        die("watch: a session id or transcript path is required")
    if any(r["session"] == sid for r in load_watching(cid)):
        return 0  # already watching this id in this session: one record per pair
    os.makedirs(STATE_DIR, exist_ok=True)
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    with open(WATCHING, "a", encoding="utf-8") as fh:
        fh.write(json.dumps({"id": cid, "session": sid, "quote": quote, "date": today},
                            ensure_ascii=False) + "\n")
    return 0


def cmd_evidence(argv):
    pdir, rest = take_projects_dir(argv)
    if len(rest) != 2:
        die("usage: evidence [--projects-dir D] <session_id|path> <quote>")
    ref, quote = rest
    need_quote(quote)
    path = resolve_transcript(ref, pdir)
    if path is None:
        sys.stderr.write("lesson-mine-state: transcript not found: %s\n" % ref)
        return 1
    return 0 if quote_in(path, quote) else 1


def cmd_evidence_count(argv):
    pdir, rest = take_projects_dir(argv)
    usage = "usage: evidence-count [--projects-dir D] [--id <id>] [<session> <quote>]..."
    cid, pairs, i = None, [], 0
    while i < len(rest):
        if rest[i] == "--id":
            if i + 1 >= len(rest) or not ID_RE.match(rest[i + 1]):
                die("evidence-count: --id needs a mine-<hash12> id")
            cid = rest[i + 1]
            i += 2
            continue
        pairs.append(rest[i])
        i += 1
    if len(pairs) % 2 or (not pairs and cid is None):
        die(usage)
    checks = list(zip(pairs[0::2], pairs[1::2]))
    for ref, quote in checks:
        need_quote(quote)
    if cid is not None:
        checks += [(r["session"], r["quote"]) for r in load_watching(cid) if r["quote"]]
    sessions = set()
    for ref, quote in checks:
        path = resolve_transcript(ref, pdir)
        if path is None:
            sys.stderr.write("lesson-mine-state: transcript not found: %s\n" % ref)
            continue
        if quote_in(path, quote):
            sessions.add(session_key(path))
    print(len(sessions))
    return 0


COMMANDS = {
    "window": cmd_window,
    "advance": cmd_advance,
    "id": cmd_id,
    "decide": cmd_decide,
    "filter": cmd_filter,
    "watch": cmd_watch,
    "evidence": cmd_evidence,
    "evidence-count": cmd_evidence_count,
}

if cmd not in COMMANDS:
    die("unknown subcommand %r (window | advance | id | decide | filter | watch | evidence | evidence-count)" % cmd)
sys.exit(COMMANDS[cmd](args))
PY
