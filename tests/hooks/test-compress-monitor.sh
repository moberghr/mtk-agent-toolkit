#!/usr/bin/env bash
set -euo pipefail

# compress-monitor.sh (PostToolUse hook): fires on a large Bash tool_response,
# reading the real PostToolUse field `tool_response` (not the never-populated
# tool_result/result the hook used before). Emits a model-visible
# hookSpecificOutput.additionalContext envelope, not a top-level field. Silent
# on short output, on non-Bash tools, and when the command already compresses.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/compress-monitor.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Build a payload with a big (~6000 char) result under the given key.
payload_with() {
  # $1 = result key (tool_response|tool_result|result), $2 = command
  python3 - "$1" "$2" <<'PY'
import json, sys
key, cmd = sys.argv[1], sys.argv[2]
big = "x" * 6000
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}, key: big}))
PY
}

run() { printf '%s' "$1" | bash "$HOOK" 2>&1 || true; }

# --- Case 1: realistic tool_response payload → fires (the C regression) ------
out="$(run "$(payload_with tool_response 'dotnet test')")"
echo "$out" | grep -q 'mtk-compress' \
  || fail "large tool_response should trigger the compress advisory. Got: $out"
echo "$out" | grep -q '"hookSpecificOutput"' \
  || fail "advisory must use the hookSpecificOutput envelope. Got: $out"
echo "$out" | grep -q '"hookEventName"[[:space:]]*:[[:space:]]*"PostToolUse"' \
  || fail "envelope must name PostToolUse. Got: $out"
printf '  PASS  large tool_response fires with PostToolUse envelope\n'

# --- Case 2: legacy tool_result key still honored (fallback) ----------------
out="$(run "$(payload_with tool_result 'npm run build')")"
echo "$out" | grep -q 'mtk-compress' \
  || fail "legacy tool_result fallback should still fire. Got: $out"
printf '  PASS  legacy tool_result fallback still fires\n'

# --- Case 3: short output → silent ------------------------------------------
short_payload='{"tool_name":"Bash","tool_input":{"command":"echo hi"},"tool_response":"hi"}'
out="$(run "$short_payload")"
[ -z "$out" ] || fail "short output must stay silent. Got: $out"
printf '  PASS  short output is silent\n'

# --- Case 4: command already compresses → silent ----------------------------
out="$(run "$(payload_with tool_response 'dotnet test | bash scripts/mtk-compress.sh tests')")"
[ -z "$out" ] || fail "command piping mtk-compress must stay silent. Got: $out"
printf '  PASS  already-compressed command is silent\n'

# --- Case 5: non-Bash tool → silent -----------------------------------------
non_bash='{"tool_name":"Read","tool_input":{"file_path":"/x"},"tool_response":"'"$(python3 -c 'print("x"*6000)')"'"}'
out="$(run "$non_bash")"
[ -z "$out" ] || fail "non-Bash tool must stay silent. Got: $out"
printf '  PASS  non-Bash tool is silent\n'

printf '\nAll compress-monitor checks passed.\n'
