#!/usr/bin/env bash
set -euo pipefail
# handoff-state.sh — lifecycle state for docs/handoffs/*.md notes.
#
# A handoff note carries YAML frontmatter (written by the handoff skill):
#   ---
#   state: open            # open | accepted | expired | closed
#   branch: <branch>
#   worktree: <abs path>
#   expires: <YYYY-MM-DD or ISO-8601 UTC>
#   accepted_at: <ISO-8601 UTC>   # added by `accept`
#   ---
# A workflow checkpoint (workflow-artifact.sh checkpoint) writes the same block plus
# workflow, sha, pushed (true|false|unknown), ahead, behind, next_command,
# needs_user (flow list), wait_until (ISO-8601 or -) and updated (ISO-8601 UTC),
# and renders `state: closed` for a finished workflow (--close or a non-active one).
#
# Usage:
#   handoff-state.sh list [--open] [--branch B] [--include-accepted-since <ISO>] [--dir D]
#       One line per note, newest mtime first:
#         <abs path> TAB <state> TAB <branch or -> TAB <mtime YYYY-MM-DD, local>
#       --open keeps notes in state `open` (plus `accepted` ones whose accepted_at
#       is at or after --include-accepted-since), drops notes past `expires`, and
#       counts a note with no branch — legacy (no frontmatter, read as open) or
#       frontmatter without `branch:` — only when it was modified within the
#       last 24 hours.
#       --branch B hides notes whose branch differs from B; a note with no branch
#       is still shown (subject to the 24h bound above under --open).
#       --dir D reads D instead of <project root>/docs/handoffs.
#       Keys are matched case-insensitively. A `state:` other than open /
#       accepted / expired / closed is reported on stderr and the note is
#       skipped. `closed` (a finished workflow's checkpoint) is hidden by --open
#       exactly like `expired`.
#   handoff-state.sh accept <file>   state: accepted, accepted_at: now (UTC)
#   handoff-state.sh expire <file>   state: expired
#       Both rewrite only those frontmatter lines; every other byte is kept. A
#       legacy note gains a minimal frontmatter block.
#   handoff-state.sh field <file> <key>
#       Print one frontmatter value (key case-insensitive). Values are returned
#       intact (a `#` inside next_command / needs_user is kept); only the
#       trailing comment on state / expires / accepted_at / updated is stripped.
#
# Exit: 0 ok · 1 file not found, or `field` key absent · 2 usage error or python3 missing.

if ! command -v python3 >/dev/null 2>&1; then
  echo "handoff-state.sh: python3 is required (S3.3 baseline) but was not found" >&2
  exit 2
fi

project_root() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}" ]; then
    (cd "$CLAUDE_PROJECT_DIR" && pwd -P)
    return 0
  fi
  git rev-parse --show-toplevel 2>/dev/null || pwd -P
}

usage() {
  sed -n '3,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

cmd="${1:-}"
[ -n "$cmd" ] || usage
shift

case "$cmd" in
  list)
    open=0 branch="" branch_set=0 since="" dir=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --open) open=1; shift ;;
        --branch) [ $# -ge 2 ] || usage; branch="$2"; branch_set=1; shift 2 ;;
        --include-accepted-since) [ $# -ge 2 ] || usage; since="$2"; shift 2 ;;
        --dir) [ $# -ge 2 ] || usage; dir="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "handoff-state.sh: unknown list option: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$dir" ] || dir="$(project_root)/docs/handoffs"
    [ -d "$dir" ] || exit 0
    python3 - "$dir" "$open" "$branch_set" "$branch" "$since" <<'PY'
import datetime, glob, os, re, sys

d, want_open, branch_set, branch, since = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1", sys.argv[4], sys.argv[5]
UTC = datetime.timezone.utc
now = datetime.datetime.now(UTC)

class Unparseable(ValueError):
    pass

def parse_ts(s):
    # None for an empty value; raises Unparseable for a value that is not a
    # date (e.g. 2026-13-45 or "next week"). Callers decide what that means.
    s = (s or "").strip()
    if not s:
        return None
    try:
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", s):
            # A bare date expires at the end of that day (UTC).
            day = datetime.datetime.strptime(s, "%Y-%m-%d").replace(tzinfo=UTC)
            return day + datetime.timedelta(days=1) - datetime.timedelta(seconds=1)
        ts = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, OverflowError):
        raise Unparseable(s)
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=UTC)
    return ts

def ts_or_none(s):
    # accepted_at / --include-accepted-since: unparseable reads as absent
    # (the accepted note is then not shown), as before.
    try:
        return parse_ts(s)
    except Unparseable:
        return None

def frontmatter(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None
    if not lines or lines[0].strip() != "---":
        return None
    fm = {}
    for line in lines[1:]:
        if line.strip() == "---":
            return fm
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$", line)
        if not m:
            continue
        val = re.sub(r"\s+#.*$", "", m.group(2)).strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
            val = val[1:-1]
        fm[m.group(1).lower()] = val
    return None  # unterminated block: treat as legacy

since_ts = ts_or_none(since) if since else None
rows = []
for path in glob.glob(os.path.join(d, "*.md")):
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        continue
    fm = frontmatter(path)
    if fm is None:
        state, note_branch, legacy = "open", "", True
    else:
        state = (fm.get("state") or "open").lower()
        note_branch, legacy = fm.get("branch", ""), False
        if state not in ("open", "accepted", "expired", "closed"):
            # A typo must not hide the note silently.
            sys.stderr.write("handoff-state: %s: unknown state '%s', ignored\n" % (path, fm.get("state")))
            continue
    if want_open:
        # No branch (legacy, or frontmatter without `branch:`): the note cannot
        # be tied to this branch, so it counts only while it is fresh.
        if not note_branch and now.timestamp() - mtime > 86400:
            continue
        if not legacy:
            try:
                exp = parse_ts(fm.get("expires", ""))
            except Unparseable as e:
                # One bad note must not hide the others or abort the listing:
                # it counts as open (not expired) and says so.
                sys.stderr.write("handoff-state: %s: unparseable expires '%s', treated as open\n" % (path, e))
                exp = None
            if exp is not None and exp < now:
                continue
            if state == "accepted":
                acc = ts_or_none(fm.get("accepted_at", ""))
                if since_ts is None or acc is None or acc < since_ts:
                    continue
            elif state != "open":
                continue
    if branch_set and note_branch and note_branch != branch:
        continue
    rows.append((mtime, os.path.abspath(path), state, note_branch or "-"))

rows.sort(key=lambda r: r[0], reverse=True)
for mtime, path, state, b in rows:
    # Local date: matches the `date +%Y-%m-%d` the handoff skill names notes with.
    day = datetime.datetime.fromtimestamp(mtime).strftime("%Y-%m-%d")
    print("\t".join([path, state, b, day]))
PY
    ;;
  accept|expire)
    [ $# -eq 1 ] || usage
    file="$1"
    if [ ! -f "$file" ] && [ "${file#/}" = "$file" ]; then
      root="$(project_root)"
      [ -f "$root/$file" ] && file="$root/$file"
    fi
    if [ ! -f "$file" ]; then
      echo "handoff-state.sh: no such handoff file: $1" >&2
      exit 1
    fi
    python3 - "$file" "$cmd" <<'PY'
import datetime, os, re, sys, tempfile

path, cmd = sys.argv[1], sys.argv[2]
new_state = "accepted" if cmd == "accept" else "expired"
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

with open(path, encoding="utf-8", newline="") as fh:
    text = fh.read()
lines = text.splitlines(keepends=True)
nl = "\r\n" if lines and lines[0].endswith("\r\n") else "\n"

end = None
if lines and lines[0].strip() == "---":
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break

def keep_comment(old, value):
    # Preserve a trailing "# ..." comment on the rewritten line.
    m = re.match(r"^[A-Za-z_][A-Za-z0-9_-]*:\s*[^#]*?(\s+#.*)?$", old.rstrip("\r\n"))
    tail = m.group(1) if m and m.group(1) else ""
    return value + tail

if end is None:
    head = ["---" + nl, "state: " + new_state + nl]
    if cmd == "accept":
        head.append("accepted_at: " + stamp + nl)
    head.append("---" + nl)
    out = head + lines
else:
    out = list(lines)
    state_idx = acc_idx = None
    for i in range(1, end):
        # Keys match case-insensitively, as `list` reads them.
        if re.match(r"^state:", out[i], re.I):
            state_idx = i
        elif re.match(r"^accepted_at:", out[i], re.I):
            acc_idx = i
    if state_idx is not None:
        eol = nl if out[state_idx].endswith(("\n", "\r\n")) else ""
        key = out[state_idx].split(":", 1)[0]
        out[state_idx] = keep_comment(out[state_idx], key + ": " + new_state) + eol
    else:
        out.insert(end, "state: " + new_state + nl)
        end += 1
    if cmd == "accept":
        if acc_idx is not None:
            eol = nl if out[acc_idx].endswith(("\n", "\r\n")) else ""
            out[acc_idx] = out[acc_idx].split(":", 1)[0] + ": " + stamp + eol
        else:
            out.insert(end, "accepted_at: " + stamp + nl)

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(path)), prefix=".handoff-state.")
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
        fh.write("".join(out))
    os.chmod(tmp, os.stat(path).st_mode & 0o7777)
    os.replace(tmp, path)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
    ;;
  field)
    [ $# -eq 2 ] || usage
    file="$1"
    if [ ! -f "$file" ] && [ "${file#/}" = "$file" ]; then
      root="$(project_root)"
      [ -f "$root/$file" ] && file="$root/$file"
    fi
    if [ ! -f "$file" ]; then
      echo "handoff-state.sh: no such handoff file: $1" >&2
      exit 1
    fi
    python3 - "$file" "$2" <<'PY'
import re, sys

path, key = sys.argv[1], sys.argv[2].lower()
COMMENTED = ("state", "expires", "accepted_at", "updated")
try:
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()
except OSError:
    sys.exit(1)
if not lines or lines[0].strip() != "---":
    sys.exit(1)
for line in lines[1:]:
    if line.strip() == "---":
        break
    m = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$", line)
    if not m or m.group(1).lower() != key:
        continue
    val = m.group(2)
    if key in COMMENTED:
        val = re.sub(r"\s+#.*$", "", val)
    val = val.strip()
    if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
        val = val[1:-1]
    print(val)
    sys.exit(0)
sys.exit(1)
PY
    ;;
  -h|--help) usage ;;
  *) echo "handoff-state.sh: unknown command: $cmd" >&2; exit 2 ;;
esac
