#!/usr/bin/env bash

set -euo pipefail

# mtk-compress.sh — pipe-friendly token compression for tool output.
#
# Usage:
#   <command>             | bash scripts/mtk-compress.sh           # auto-detect
#   <command>             | bash scripts/mtk-compress.sh json
#   <command>             | bash scripts/mtk-compress.sh logs
#   <command>             | bash scripts/mtk-compress.sh tests
#   <command>             | bash scripts/mtk-compress.sh html
#   bash scripts/mtk-compress.sh stats   # session compression total
#   bash scripts/mtk-compress.sh config  # show env knobs
#
# Emits compressed text on stdout and appends one analytics line per run to
# .claude/observability/compression.jsonl when CLAUDE_CODE_SESSION_ID is set.
#
# Env knobs (set in .claude/settings.local.json env block):
#   MTK_COMPRESS_MIN_CHARS         skip compression below this (default: 1000)
#   MTK_COMPRESS_MAX_LOG_LINES     keep first/last N for log mode (default: 30 each)
#   MTK_COMPRESS_MAX_ARRAY_ITEMS   keep first/last N for JSON arrays (default: 5 each)
#   MTK_COMPRESS_DISABLED          if "1", pass through unchanged

MODE="${1:-auto}"
MIN_CHARS="${MTK_COMPRESS_MIN_CHARS:-1000}"
MAX_LOG_LINES="${MTK_COMPRESS_MAX_LOG_LINES:-30}"
MAX_ARRAY_ITEMS="${MTK_COMPRESS_MAX_ARRAY_ITEMS:-5}"
ANALYTICS_DIR=".claude/observability"
ANALYTICS_FILE="${ANALYTICS_DIR}/compression.jsonl"

if [ "${MTK_COMPRESS_DISABLED:-0}" = "1" ]; then
  cat
  exit 0
fi

case "$MODE" in
  stats)
    if [ ! -f "$ANALYTICS_FILE" ]; then
      printf 'No compression data yet (%s missing).\n' "$ANALYTICS_FILE"
      exit 0
    fi
    python3 - "$ANALYTICS_FILE" "${CLAUDE_CODE_SESSION_ID:-}" <<'PY'
import json, sys
path, session = sys.argv[1], sys.argv[2]
total_in = total_out = total_runs = 0
session_in = session_out = session_runs = 0
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try: rec = json.loads(line)
        except json.JSONDecodeError: continue
        total_in += rec.get("in_chars", 0)
        total_out += rec.get("out_chars", 0)
        total_runs += 1
        if session and rec.get("session") == session:
            session_in += rec.get("in_chars", 0)
            session_out += rec.get("out_chars", 0)
            session_runs += 1

def fmt(n): return f"{n:>12,}"
def pct(out, inp):
    if not inp: return "  0%"
    return f"{(1 - out/inp) * 100:5.1f}%"

print(f"compression stats — analytics: {path}")
print(f"  all-time:  runs={total_runs:>5}  in={fmt(total_in)}  out={fmt(total_out)}  saved={fmt(total_in-total_out)}  ratio={pct(total_out,total_in)}")
if session:
    print(f"  session:   runs={session_runs:>5}  in={fmt(session_in)}  out={fmt(session_out)}  saved={fmt(session_in-session_out)}  ratio={pct(session_out,session_in)}")
PY
    exit 0
    ;;
  config)
    cat <<EOF
mtk-compress config:
  MTK_COMPRESS_MIN_CHARS       = ${MIN_CHARS}
  MTK_COMPRESS_MAX_LOG_LINES   = ${MAX_LOG_LINES}
  MTK_COMPRESS_MAX_ARRAY_ITEMS = ${MAX_ARRAY_ITEMS}
  MTK_COMPRESS_DISABLED        = ${MTK_COMPRESS_DISABLED:-0}
  analytics file               = ${ANALYTICS_FILE}
EOF
    exit 0
    ;;
esac

INPUT="$(cat)"
IN_CHARS="${#INPUT}"

# Pass-through for short input.
if [ "$IN_CHARS" -lt "$MIN_CHARS" ]; then
  printf '%s' "$INPUT"
  exit 0
fi

# Auto-detect mode if requested.
if [ "$MODE" = "auto" ]; then
  trimmed="$(printf '%s' "$INPUT" | head -c 256)"
  case "$trimmed" in
    \{*|\[*) MODE=json ;;
    *\<html*|*\<\!DOCTYPE*) MODE=html ;;
    *)
      # Heuristic: if the input has timestamp-like prefixes on most lines, treat as logs.
      if printf '%s' "$INPUT" | head -50 | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}|^\[[0-9]{2}:[0-9]{2}|^[A-Z][a-z]{2} [0-9]{1,2}' | awk '{exit ($1 < 5)}'; then
        MODE=logs
      elif printf '%s' "$INPUT" | head -50 | grep -qE '(passed|failed|skipped|FAIL|PASS|✓|✗|×)'; then
        MODE=tests
      else
        MODE=logs
      fi
      ;;
  esac
fi

DATA_FILE="$(mktemp)"
trap 'rm -f "$DATA_FILE"' EXIT
printf '%s' "$INPUT" > "$DATA_FILE"

OUTPUT="$(python3 - "$MODE" "$MAX_LOG_LINES" "$MAX_ARRAY_ITEMS" "$DATA_FILE" <<'PY'
import json, re, sys, os

mode = sys.argv[1]
max_log = int(sys.argv[2])
max_arr = int(sys.argv[3])
with open(sys.argv[4]) as f:
    data = f.read()

def truncate_array(arr, n=5):
    if not isinstance(arr, list) or len(arr) <= 2 * n:
        return arr
    head = arr[:n]
    tail = arr[-n:]
    elided = len(arr) - 2 * n
    return head + [f"... ({elided} items elided) ..."] + tail

def shrink_json(obj):
    if isinstance(obj, dict):
        return {k: shrink_json(v) for k, v in obj.items()}
    if isinstance(obj, list):
        if len(obj) > 2 * max_arr:
            obj = truncate_array(obj, max_arr)
        return [shrink_json(x) for x in obj]
    if isinstance(obj, str) and len(obj) > 600:
        return obj[:300] + f"... [{len(obj)-600} chars elided] ..." + obj[-300:]
    return obj

def compress_logs(text):
    lines = text.split("\n")
    n = len(lines)
    if n <= 2 * max_log:
        return text
    head = lines[:max_log]
    tail = lines[-max_log:]
    elided = n - 2 * max_log
    return "\n".join(head + [f"... [{elided} log lines elided — full output preserved on disk] ..."] + tail)

def compress_tests(text):
    # Keep failures + summary; collapse PASS noise.
    lines = text.split("\n")
    keep = []
    pass_run = 0
    for line in lines:
        if re.search(r"FAIL|✗|×|Error|Exception|Traceback|^E ", line) or \
           re.search(r"\b\d+ (passed|failed|skipped|errors?)\b", line, re.I) or \
           re.match(r"^={3,}|^-{3,}", line):
            if pass_run:
                keep.append(f"... [{pass_run} passing lines elided] ...")
                pass_run = 0
            keep.append(line)
        elif re.search(r"\b(PASS|passed|✓|ok)\b", line):
            pass_run += 1
        else:
            if pass_run:
                keep.append(f"... [{pass_run} passing lines elided] ...")
                pass_run = 0
            keep.append(line)
    if pass_run:
        keep.append(f"... [{pass_run} passing lines elided] ...")
    return "\n".join(keep)

def compress_html(text):
    # Strip <script>/<style>; collapse whitespace; truncate.
    text = re.sub(r"<script\b[^>]*>.*?</script>", "<!-- script elided -->", text, flags=re.S|re.I)
    text = re.sub(r"<style\b[^>]*>.*?</style>",   "<!-- style elided -->",  text, flags=re.S|re.I)
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    text = re.sub(r"\s+", " ", text)
    if len(text) > 4000:
        text = text[:2000] + f" ... [{len(text)-4000} chars elided] ... " + text[-2000:]
    return text

if mode == "json":
    try:
        obj = json.loads(data)
        result = json.dumps(shrink_json(obj), indent=2)
    except json.JSONDecodeError:
        # Not actually JSON — fall back to log compression.
        result = compress_logs(data)
elif mode == "logs":
    result = compress_logs(data)
elif mode == "tests":
    result = compress_tests(data)
elif mode == "html":
    result = compress_html(data)
else:
    print(f"mtk-compress: unknown mode {mode!r}", file=sys.stderr); sys.exit(1)

sys.stdout.write(result)
PY
)"

OUT_CHARS="${#OUTPUT}"

# Append analytics if observability dir is writable.
if [ -d ".claude" ] && { [ -d "$ANALYTICS_DIR" ] || mkdir -p "$ANALYTICS_DIR" 2>/dev/null; }; then
  TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  SID="${CLAUDE_CODE_SESSION_ID:-}"
  printf '{"ts":"%s","session":"%s","mode":"%s","in_chars":%d,"out_chars":%d}\n' \
    "$TS" "$SID" "$MODE" "$IN_CHARS" "$OUT_CHARS" >> "$ANALYTICS_FILE" 2>/dev/null || true
fi

printf '%s' "$OUTPUT"
