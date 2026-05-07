#!/usr/bin/env bash

set -euo pipefail

# compress-monitor.sh — PostToolUse hook that flags large Bash tool outputs
# that landed in context without being piped through `mtk-compress.sh`.
#
# Reads the Claude Code PostToolUse hook payload on stdin (JSON) and emits a
# `{"continue": true, "additionalContext": "..."}` envelope when:
#   - the tool was Bash
#   - the tool result exceeds MTK_COMPRESS_WARN_CHARS (default 5000)
#   - the bash command did NOT already include `mtk-compress`
#
# This is advisory only — it does not modify the tool result. The compression
# itself happens in the shell pipe (`<command> | bash scripts/mtk-compress.sh`).
#
# Disable per machine via `MTK_COMPRESS_MONITOR_DISABLED=1`.

if [ "${MTK_COMPRESS_MONITOR_DISABLED:-0}" = "1" ]; then
  exit 0
fi

WARN_CHARS="${MTK_COMPRESS_WARN_CHARS:-5000}"

# Read the entire hook payload to a temp file (heredoc captures stdin so we
# can't pipe payload directly into the python script).
PAYLOAD_FILE="$(mktemp)"
trap 'rm -f "$PAYLOAD_FILE"' EXIT
cat > "$PAYLOAD_FILE"
[ -s "$PAYLOAD_FILE" ] || exit 0

python3 - "$WARN_CHARS" "$PAYLOAD_FILE" <<'PY'
import json, sys
warn_chars = int(sys.argv[1])
try:
    with open(sys.argv[2]) as f:
        payload = json.load(f)
except (json.JSONDecodeError, OSError):
    sys.exit(0)

tool = payload.get("tool_name") or payload.get("tool") or ""
if tool != "Bash":
    sys.exit(0)

ti = payload.get("tool_input") or {}
if isinstance(ti, dict):
    cmd = ti.get("command", "") or ""
else:
    cmd = ""

if "mtk-compress" in cmd or "MTK_COMPRESS_DISABLED" in cmd:
    sys.exit(0)

result = payload.get("tool_result") or payload.get("result") or ""
if isinstance(result, dict):
    result = result.get("output") or result.get("stdout") or json.dumps(result)
if not isinstance(result, str):
    result = str(result)

if len(result) < warn_chars:
    sys.exit(0)

# Pick a suggested mode based on command shape.
mode = "auto"
low = cmd.lower()
if "test" in low or "pytest" in low or "vitest" in low or "jest" in low or "dotnet test" in low:
    mode = "tests"
elif "build" in low or "compile" in low or "tsc" in low or "biome" in low:
    mode = "logs"
elif "curl" in low and ("html" in low or ".html" in low):
    mode = "html"
elif low.lstrip().startswith(("jq ", "cat ")) and ".json" in low:
    mode = "json"

msg = (
    f"💡 mtk-compress: Bash output was {len(result):,} chars (warn ≥ {warn_chars:,}). "
    f"Pipe long output through `bash scripts/mtk-compress.sh {mode}` to reclaim ~70-95% of context tokens. "
    f"Set MTK_COMPRESS_MONITOR_DISABLED=1 in .claude/settings.local.json env to silence."
)

sys.stdout.write(json.dumps({"continue": True, "additionalContext": msg}))
PY
