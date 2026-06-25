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
  # Always feed stdin and bound runtime so the test can never hang.
  local msg="$1"
  echo '' | TMPDIR="$TMPDIR_OVERRIDE" MTK_HOOKS_TIER2=1 bash "$HOOK" "$msg" 2>&1 || true
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

printf '\nAll verify-completion re-arm checks passed.\n'
