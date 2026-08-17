#!/usr/bin/env bash
set -euo pipefail

# Re-arm rule (v7.14): when an edit lands after the most recent verification
# (last_edit_seq > last_verification_seq), hooks/verify-completion must emit a
# "criteria re-armed" gap on a strong completion claim. When verification is
# fresh (last_verification_seq >= last_edit_seq) and the message cites evidence,
# no re-arm gap fires.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/verify-completion"

cd "$REPO_ROOT"

# Isolate session state in a temp TMPDIR so we never touch the live session file.
TMPDIR_OVERRIDE="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_OVERRIDE"; }
trap cleanup EXIT

# Resolve the session-file path the hook will compute under our temp TMPDIR.
SESSION_FILE="$(TMPDIR="$TMPDIR_OVERRIDE" bash -c '
  source "'"$REPO_ROOT"'/hooks/lib/hook-io.sh"
  mtk_session_file
')"

write_state() {
  # $1 last_edit_seq  $2 last_verification_seq
  cat > "$SESSION_FILE" <<EOF
reads=0
files=''
mods=0
ops=0
event_seq=$1
last_edit_epoch=1000
last_edit_seq=$1
last_verification_epoch=900
last_verification_seq=$2
last_verification_command='dotnet test'
last_verification_summary='14/14 pass'
bytes_read=0
EOF
}

run_hook() {
  # Stop-event contract: JSON on stdin carrying transcript_path. The "message"
  # under test is written as the last assistant message in a fake transcript.
  local msg="$1"
  local stop_active="${2:-false}"
  local transcript="$TMPDIR_OVERRIDE/transcript.jsonl"
  python3 - "$transcript" "$msg" <<'PY'
import json, sys
with open(sys.argv[1], "w") as fh:
    fh.write(json.dumps({"type": "assistant", "message": {"role": "assistant",
             "content": [{"type": "text", "text": sys.argv[2]}]}}) + "\n")
PY
  local payload
  payload="$(python3 - "$transcript" "$stop_active" <<'PY'
import json, sys
print(json.dumps({"hook_event_name": "Stop", "transcript_path": sys.argv[1],
                  "stop_hook_active": sys.argv[2] == "true"}))
PY
)"
  printf '%s' "$payload" | TMPDIR="$TMPDIR_OVERRIDE" MTK_HOOKS_TIER2=1 bash "$HOOK" 2>&1 || true
}

run_codex_hook() {
  local msg="$1"
  local stop_active="${2:-false}"
  local payload
  payload="$(python3 - "$msg" "$stop_active" <<'PY'
import json, sys
print(json.dumps({"hook_event_name": "Stop", "last_assistant_message": sys.argv[1],
                  "stop_hook_active": sys.argv[2] == "true"}))
PY
)"
  printf '%s' "$payload" | TMPDIR="$TMPDIR_OVERRIDE" MTK_HOOKS_TIER2=1 bash "$HOOK" 2>&1 || true
}

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# --- Case 1: edit after verification → re-arm gap fires --------------------
write_state 5 3
out="$(run_hook 'All done. Task complete. ✅')"
echo "$out" | grep -qi 're-arm' \
  || fail "stale edit (seq 5>3) did not emit a re-arm gap. Got: $out"
printf '  PASS  edit after verification re-arms criteria\n'

# --- Case 2: fresh verification + cited evidence → no re-arm gap -----------
write_state 3 5
out="$(run_hook 'All done. Task complete. Tests: 14 passed, exit code 0.')"
if echo "$out" | grep -qi 're-arm'; then
  fail "fresh verification (seq 3<=5) wrongly emitted a re-arm gap. Got: $out"
fi
printf '  PASS  fresh verification does not re-arm\n'

# --- Case 3: equal seqs (verification same tick as last edit) → no re-arm --
write_state 4 4
out="$(run_hook 'Work complete. exit code 0, Tests: 8 passed.')"
if echo "$out" | grep -qi 're-arm'; then
  fail "equal seqs (4==4) wrongly emitted a re-arm gap. Got: $out"
fi
printf '  PASS  equal seqs do not re-arm\n'

# --- Case 4: stop_hook_active=true → never block (avoid infinite stop loop) --
write_state 5 3
out="$(run_hook 'All done. Task complete. ✅' true)"
[ -z "$out" ] || fail "stop_hook_active=true must never emit a block. Got: $out"
printf '  PASS  stop_hook_active honored — no re-block\n'

# --- Case 5: a gap is emitted as a decision:block envelope, not plain text ---
write_state 5 3
out="$(run_hook 'All done. Task complete. ✅')"
echo "$out" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' \
  || fail "gap must be a decision:block Stop envelope. Got: $out"
printf '  PASS  gap emitted as decision:block envelope\n'

# --- Case 6: Codex payload uses last_assistant_message ----------------------
write_state 5 3
out="$(run_codex_hook 'All done. Task complete. ✅')"
echo "$out" | grep -qi 'VERIFICATION GAP' \
  || fail "Codex last_assistant_message did not trigger a verification gap. Got: $out"
echo "$out" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' \
  || fail "Codex gap must be a decision:block Stop envelope. Got: $out"
printf '  PASS  Codex last_assistant_message is verified\n'

printf '\nAll verify-completion re-arm checks passed.\n'
