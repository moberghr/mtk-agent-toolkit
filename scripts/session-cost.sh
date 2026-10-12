#!/usr/bin/env bash
set -euo pipefail

# session-cost.sh — API-equivalent token cost estimates per session, from Claude
# Code transcripts. Written by the cost-tracker Stop hook (`record`), read by the
# implement run receipt (`window`).
#
# Transcripts are an INTERNAL, unstable Claude Code format, not a contract. The
# parser is therefore defensive: a malformed line is skipped, and any failure
# beyond that records NOTHING — never a zero-filled row that would read as "this
# session cost nothing". Only counts, model ids, the session id and timestamps
# are written; no transcript content is ever copied into the metrics.
#
# Usage:
#   session-cost.sh record --transcript P --session S [--metrics-dir D]
#   session-cost.sh window --since ISO --until ISO [--json] [--metrics-dir D]
#   session-cost.sh --help
#
# record: for the main transcript and each <dir-of-P>/<S>/subagents/agent-<id>.jsonl,
#   sums assistant-message usage deduplicated by message.id (last line wins),
#   compares it with the per-source cumulative snapshot D/sessions/<S>.json, and
#   appends one JSONL row per source whose delta is non-zero to D/costs.jsonl:
#     {"ts","session_id","source":"main"|"subagent:<id>","model",
#      "tokens":{"input","output","cache_write_5m","cache_write_1h","cache_read"},
#      "est_usd":number|null,"unpriced_tokens","pricing_as_of"}
#   A source whose cumulative total went down (rewritten transcript) takes the new
#   cumulative as its delta. Pricing: hooks/lib/model-pricing.tsv, exact model-id
#   match after stripping a trailing "[...]" and "-YYYYMMDD". Unpriced models add
#   to unpriced_tokens; est_usd is null only when nothing in the delta was priced.
#
# window: sums rows with since <= ts <= until. Prints "not recorded" (or
#   {"status":"not recorded"} with --json) when no row falls in the window.
#   When D/.last-error exists (written by hooks/cost-tracker.sh after a failed
#   record: "<ts>\t<rc>\t<msg>"), a line
#     warning: cost tracking failed at <ts> (rc=<rc>): <msg> — rows after that point may be missing
#   is printed first (before the table or "not recorded"); with --json the
#   object gains "last_error": {"ts","rc","msg"}.
#
# D defaults to <project root>/.mtk/metrics, where project root is
# $CLAUDE_PROJECT_DIR -> git top-level -> pwd.
#
# Exit: 0 ok (including "nothing to record") · 1 record failed, nothing written ·
#       2 usage error or python3 missing.

usage() {
  # The leading comment block, by shape (no hard-coded line range to go stale).
  awk 'NR < 3 { next } /^#/ { started = 1; sub(/^# ?/, ""); print; next } started { exit }' "$0"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRICING="${SCRIPT_DIR}/../hooks/lib/model-pricing.tsv"

MODE="${1:-}"
case "$MODE" in
  -h|--help|help) usage; exit 0 ;;
  record|window) shift ;;
  "") usage >&2; exit 2 ;;
  *) echo "session-cost.sh: unknown mode '$MODE' (record|window|--help)" >&2; exit 2 ;;
esac

TRANSCRIPT="" SESSION="" METRICS_DIR="" SINCE="" UNTIL="" JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --transcript) TRANSCRIPT="${2:-}"; shift 2 || { echo "session-cost.sh: --transcript needs a value" >&2; exit 2; } ;;
    --session) SESSION="${2:-}"; shift 2 || { echo "session-cost.sh: --session needs a value" >&2; exit 2; } ;;
    --metrics-dir) METRICS_DIR="${2:-}"; shift 2 || { echo "session-cost.sh: --metrics-dir needs a value" >&2; exit 2; } ;;
    --since) SINCE="${2:-}"; shift 2 || { echo "session-cost.sh: --since needs a value" >&2; exit 2; } ;;
    --until) UNTIL="${2:-}"; shift 2 || { echo "session-cost.sh: --until needs a value" >&2; exit 2; } ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "session-cost.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "session-cost.sh: python3 is required (accepted baseline, S3.3) but was not found on PATH" >&2
  exit 2
fi

if [ "$MODE" = "record" ]; then
  if [ -z "$TRANSCRIPT" ] || [ -z "$SESSION" ]; then
    echo "session-cost.sh: record needs --transcript and --session" >&2
    exit 2
  fi
else
  if [ -z "$SINCE" ] || [ -z "$UNTIL" ]; then
    echo "session-cost.sh: window needs --since and --until" >&2
    exit 2
  fi
fi

if [ -z "$METRICS_DIR" ]; then
  ROOT=""
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}" ]; then
    ROOT="$CLAUDE_PROJECT_DIR"
  fi
  [ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  METRICS_DIR="${ROOT}/.mtk/metrics"
fi

python3 - "$MODE" "$METRICS_DIR" "$PRICING" "$TRANSCRIPT" "$SESSION" "$SINCE" "$UNTIL" "$JSON" <<'PY'
import sys
sys.stdout.reconfigure(newline="\n")  # LF even on Windows python3
import glob
import json
import os
import re
from datetime import datetime, timezone

MODE, MDIR, PRICING, TRANSCRIPT, SESSION, SINCE, UNTIL, AS_JSON = sys.argv[1:9]
KEYS = ("input", "output", "cache_write_5m", "cache_write_1h", "cache_read")
LABEL = "API-equivalent estimate"


def load_pricing(path):
    table, as_of = {}, None
    try:
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.rstrip("\n")
                if line.startswith("#"):
                    m = re.match(r"#\s*as_of:\s*(\d{4}-\d{2}-\d{2})", line)
                    if m and as_of is None:
                        as_of = m.group(1)
                    continue
                cols = line.split("\t")
                if len(cols) != 6 or not cols[0]:
                    continue
                try:
                    table[cols[0]] = tuple(float(c) for c in cols[1:])
                except ValueError:
                    continue
    except OSError:
        pass
    return table, as_of


def normalize_model(model):
    m = re.sub(r"\[[^\]]*\]$", "", model)
    m = re.sub(r"-\d{8}$", "", m)
    return m


def is_count(v):
    return isinstance(v, int) and not isinstance(v, bool) and v >= 0


def parse_transcript(path):
    """Return (per-model token totals, last model) for one transcript.

    Lines that are not valid JSON, not assistant messages, or lack a message id /
    usage block are skipped. Duplicate message ids (one line per content block)
    are counted once; the last line wins. Raises OSError when the file cannot be
    read — the caller then records nothing at all.
    """
    msgs = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if not isinstance(obj, dict) or obj.get("type") != "assistant":
                continue
            msg = obj.get("message")
            if not isinstance(msg, dict):
                continue
            mid, model, usage = msg.get("id"), msg.get("model"), msg.get("usage")
            if not isinstance(mid, str) or not mid or not isinstance(usage, dict):
                continue
            if not isinstance(model, str) or not model:
                model = "unknown"
            base = {k: usage.get(k, 0) for k in ("input_tokens", "output_tokens",
                                                 "cache_creation_input_tokens",
                                                 "cache_read_input_tokens")}
            if not all(is_count(v) for v in base.values()):
                continue
            split = usage.get("cache_creation")
            w5 = w1 = None
            if isinstance(split, dict):
                a = split.get("ephemeral_5m_input_tokens")
                b = split.get("ephemeral_1h_input_tokens")
                if is_count(a) or is_count(b):
                    w5 = a if is_count(a) else 0
                    w1 = b if is_count(b) else 0
            if w5 is None:
                w5, w1 = base["cache_creation_input_tokens"], 0
            msgs.pop(mid, None)  # re-insert so dict order tracks the LAST occurrence
            msgs[mid] = (model, {
                "input": base["input_tokens"],
                "output": base["output_tokens"],
                "cache_write_5m": w5,
                "cache_write_1h": w1,
                "cache_read": base["cache_read_input_tokens"],
            })
    by_model = {}
    for model, toks in msgs.values():
        acc = by_model.setdefault(model, {k: 0 for k in KEYS})
        for k in KEYS:
            acc[k] += toks[k]
    last_model = next(reversed(list(msgs.values())))[0] if msgs else None
    return by_model, last_model


def price(model, toks, table):
    rates = table.get(normalize_model(model))
    if rates is None:
        return None
    return sum(toks[k] * r for k, r in zip(KEYS, rates)) / 1_000_000


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_ts(s):
    if not isinstance(s, str) or not s:
        return None
    t = s.strip()
    if t.endswith("Z") or t.endswith("z"):
        t = t[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(t)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def record():
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,200}", SESSION) or SESSION in (".", ".."):
        return 1
    if not os.path.isfile(TRANSCRIPT):
        return 0  # nothing to record; the hook fires before a transcript exists
    table, as_of = load_pricing(PRICING)

    sources = {"main": TRANSCRIPT}
    sub_dir = os.path.join(os.path.dirname(os.path.abspath(TRANSCRIPT)), SESSION, "subagents")
    for p in sorted(glob.glob(os.path.join(sub_dir, "agent-*.jsonl"))):
        sid = os.path.basename(p)[len("agent-"):-len(".jsonl")]
        if sid and os.path.isfile(p):
            sources["subagent:" + sid] = p

    current = {}
    for label, path in sources.items():
        current[label] = parse_transcript(path)  # OSError aborts: record nothing

    sess_dir = os.path.join(MDIR, "sessions")
    snap_path = os.path.join(sess_dir, SESSION + ".json")
    os.makedirs(sess_dir, exist_ok=True)
    lock = open(os.path.join(MDIR, ".costs.lock"), "a")
    try:
        import fcntl  # serialise overlapping async Stop hooks; absent on Windows
        fcntl.flock(lock, fcntl.LOCK_EX)
    except ImportError:
        pass
    snapshot = {}
    if os.path.isfile(snap_path):
        with open(snap_path, encoding="utf-8") as fh:
            data = json.load(fh)  # a corrupt snapshot aborts: record nothing
        if isinstance(data, dict) and isinstance(data.get("sources"), dict):
            snapshot = data["sources"]

    ts = now_iso()
    rows = []
    new_snap = dict(snapshot)
    for label, (by_model, last_model) in current.items():
        prev = snapshot.get(label, {})
        prev = prev.get("by_model", {}) if isinstance(prev, dict) else {}
        if not isinstance(prev, dict):
            prev = {}

        def total(bm, k):
            return sum(int(t.get(k, 0)) for t in bm.values() if isinstance(t, dict))

        decreased = any(total(by_model, k) < total(prev, k) for k in KEYS) or any(
            isinstance(prev.get(m), dict) and by_model.get(m, {}).get(k, 0) < int(prev[m].get(k, 0))
            for m in prev for k in KEYS)
        delta = {}
        for model, toks in by_model.items():
            base = {} if decreased else (prev.get(model) if isinstance(prev.get(model), dict) else {})
            d = {k: toks[k] - int(base.get(k, 0)) for k in KEYS}
            if any(d.values()):
                delta[model] = d
        new_snap[label] = {"by_model": by_model}
        if not delta:
            continue
        tokens = {k: sum(d[k] for d in delta.values()) for k in KEYS}
        est, priced_any, unpriced = 0.0, False, 0
        for model, d in delta.items():
            p = price(model, d, table)
            if p is None:
                unpriced += sum(d.values())
            else:
                est += p
                priced_any = True
        rows.append({
            "ts": ts,
            "session_id": SESSION,
            "source": label,
            "model": last_model,
            "tokens": tokens,
            "est_usd": round(est, 6) if priced_any else None,
            "unpriced_tokens": unpriced,
            "pricing_as_of": as_of,
        })

    if not rows and new_snap == snapshot:
        return 0
    # Snapshot staged first, so a failure before the append leaves no rows behind.
    tmp = "%s.tmp.%d" % (snap_path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"session_id": SESSION, "updated": ts, "sources": new_snap}, fh, sort_keys=True)
        if rows:
            with open(os.path.join(MDIR, "costs.jsonl"), "a", encoding="utf-8") as fh:
                fh.write("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
        os.replace(tmp, snap_path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    return 0


def read_last_error():
    """The one-line failure marker cost-tracker.sh leaves after a failed record."""
    try:
        with open(os.path.join(MDIR, ".last-error"), encoding="utf-8", errors="replace") as fh:
            line = fh.readline().rstrip("\n")
    except OSError:
        return None
    if not line:
        return None
    parts = line.split("\t", 2)
    while len(parts) < 3:
        parts.append("")
    ts, rc, msg = parts
    try:
        rc = int(rc)
    except ValueError:
        pass
    return {"ts": ts, "rc": rc, "msg": msg}


def warning_line(err):
    return ("warning: cost tracking failed at %s (rc=%s): %s \u2014 rows after that point may be missing"
            % (err["ts"], err["rc"], err["msg"]))


def window():
    lo, hi = parse_ts(SINCE), parse_ts(UNTIL)
    if lo is None or hi is None:
        print("session-cost.sh: --since/--until must be ISO-8601 timestamps", file=sys.stderr)
        return 2
    last_error = read_last_error()
    if last_error is not None and AS_JSON != "1":
        print(warning_line(last_error))
    totals = {k: 0 for k in KEYS}
    est, any_priced, rows, unpriced = 0.0, False, 0, 0
    sources, as_of = set(), set()
    path = os.path.join(MDIR, "costs.jsonl")
    if os.path.isfile(path):
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(r, dict):
                    continue
                t = parse_ts(r.get("ts"))
                toks = r.get("tokens")
                if t is None or not (lo <= t <= hi) or not isinstance(toks, dict):
                    continue
                if not all(is_count(toks.get(k, 0)) for k in KEYS):
                    continue
                rows += 1
                for k in KEYS:
                    totals[k] += toks.get(k, 0)
                e = r.get("est_usd")
                if isinstance(e, (int, float)) and not isinstance(e, bool):
                    est += e
                    any_priced = True
                u = r.get("unpriced_tokens")
                if is_count(u):
                    unpriced += u
                if isinstance(r.get("source"), str):
                    sources.add(r["source"])
                if isinstance(r.get("pricing_as_of"), str):
                    as_of.add(r["pricing_as_of"])
    if rows == 0:
        if AS_JSON == "1":
            out = {"status": "not recorded"}
            if last_error is not None:
                out["last_error"] = last_error
            print(json.dumps(out))
        else:
            print("not recorded")
        return 0
    est_usd = round(est, 6) if any_priced else None
    if AS_JSON == "1":
        out = {
            "status": "recorded", "label": LABEL, "since": SINCE, "until": UNTIL,
            "rows": rows, "sources": sorted(sources), "tokens": totals,
            "est_usd": est_usd, "unpriced_tokens": unpriced,
            "pricing_as_of": sorted(as_of),
        }
        if last_error is not None:
            out["last_error"] = last_error
        print(json.dumps(out, sort_keys=True))
        return 0
    print("%s (%s -> %s)" % (LABEL, SINCE, UNTIL))
    for k in KEYS:
        print("  %-15s %12d" % (k, totals[k]))
    print("  %-15s %12s" % ("est_usd", "null" if est_usd is None else "%.4f" % est_usd))
    if unpriced:
        print("  %-15s %12d" % ("unpriced_tokens", unpriced))
    print("  rows: %d · sources: %s · pricing as of: %s"
          % (rows, ", ".join(sorted(sources)), ", ".join(sorted(as_of)) or "n/a"))
    return 0


if MODE == "record":
    try:
        sys.exit(record())
    except (OSError, ValueError, TypeError, AttributeError, KeyError) as exc:
        print("session-cost.sh: record failed, nothing recorded (%s)" % type(exc).__name__, file=sys.stderr)
        sys.exit(1)
else:
    sys.exit(window())
PY
