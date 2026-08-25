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

# Normalise the nag budget to its default before any case runs. This knob is
# documented for .claude/settings.local.json `env`, and a developer who sets it
# there has it exported into every shell — including this one, where it silences
# the hook and makes the suite fail with "advisory did not fire", pointing at the
# hook instead of at the ambient config. Cases that exercise the budget still
# override it with their own env prefix.
export MTK_COMPRESS_MAX_NAGS=1

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

# Each case gets a throwaway TMPDIR so the per-session nag budget starts fresh —
# otherwise case 1 spends the budget and every later case reads as "silent" for
# the wrong reason. Case 6 deliberately shares one TMPDIR to exercise the budget.
run() {
  local d out
  d="$(mktemp -d)"
  out="$(printf '%s' "$1" | TMPDIR="$d" bash "$HOOK" 2>&1 || true)"
  rm -rf "$d"
  printf '%s' "$out"
}

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

# --- Case 6: per-session nag budget -----------------------------------------
# The tip is worth one read; repeating it on every large output for a whole
# session is noise that trains the reader to ignore every hook. Budget is
# per-session, so a second session still gets its one nag.
BUDGET_TMP="$(mktemp -d)"
budget_run() {
  # $1 = session_id
  python3 - "$1" <<'PY' | TMPDIR="$BUDGET_TMP" bash "$HOOK" 2>&1 || true
import json, sys
print(json.dumps({"session_id": sys.argv[1], "tool_name": "Bash",
                  "tool_input": {"command": "dotnet build"},
                  "tool_response": "x" * 6000}))
PY
}

out="$(budget_run sess-one)"
echo "$out" | grep -q 'mtk-compress' || fail "first nag of a session must fire. Got: $out"
echo "$out" | grep -q 'once per session' || fail "final allowed nag must say it will not repeat. Got: $out"
printf '  PASS  first large output in a session nags once\n'

out="$(budget_run sess-one)"
[ -z "$out" ] || fail "second large output in the same session must stay silent. Got: $out"
printf '  PASS  budget spent — same session stays silent\n'

out="$(budget_run sess-two)"
echo "$out" | grep -q 'mtk-compress' || fail "a different session must get its own nag. Got: $out"
printf '  PASS  budget is per-session, not global\n'

out="$(MTK_COMPRESS_MAX_NAGS=0 budget_run sess-three)"
[ -z "$out" ] || fail "MTK_COMPRESS_MAX_NAGS=0 must silence without disabling. Got: $out"
printf '  PASS  MTK_COMPRESS_MAX_NAGS=0 silences\n'

out="$(MTK_COMPRESS_MAX_NAGS=2 budget_run sess-four)"
echo "$out" | grep -q 'mtk-compress' || fail "MAX_NAGS=2 first nag must fire. Got: $out"
echo "$out" | grep -q 'once per session' && fail "with budget 2 remaining, must not claim it is the last. Got: $out"
out="$(MTK_COMPRESS_MAX_NAGS=2 budget_run sess-four)"
echo "$out" | grep -q 'mtk-compress' || fail "MAX_NAGS=2 second nag must fire. Got: $out"
out="$(MTK_COMPRESS_MAX_NAGS=2 budget_run sess-four)"
[ -z "$out" ] || fail "MAX_NAGS=2 third nag must be silent. Got: $out"
printf '  PASS  MTK_COMPRESS_MAX_NAGS raises the budget\n'

rm -rf "$BUDGET_TMP"

printf '\nAll compress-monitor checks passed.\n'
