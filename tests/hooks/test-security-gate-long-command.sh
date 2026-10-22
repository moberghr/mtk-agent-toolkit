#!/usr/bin/env bash
set -euo pipefail

# security-gate.sh must judge a long command well inside its 5s hook timeout.
# A 2026-10-22 field run had 58 timeouts in 24h, every one a 2–15k-char heredoc
# file write. The cause was the "anything left after stripping?" test
# `[ -n "${NORM//[[:space:]]/}" ]`: on macOS bash 3.2 that substitution is
# super-linear (159s on an 8k command in a UTF-8 locale), and a timed-out hook
# never judged the command at all. These cases pin the time bound and that a
# long command still gets judged. A perl alarm watchdog kills the gate at the
# bound + 2s, so a regression fails fast instead of hanging the suite. Linux CI
# runs bash 5, where the substitution was never slow: there this is a
# regression guard for the judging, the timing bite is on macOS bash 3.2.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$REPO_ROOT/hooks/security-gate.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
BOUND="${MTK_TEST_GATE_BOUND:-4}"

# Writes a Bash payload whose command is a ~15k-char heredoc write followed by $1.
make_payload() {
  python3 - "$1" "$TMP/payload.json" <<'PY'
import json, sys
tail, out = sys.argv[1], sys.argv[2]
body = "\n".join("    public void Method%d() { var x = \"value %d\"; Assert.Equal(x, Compute(%d)); }" % (i, i, i) for i in range(180))
cmd = "cd /tmp/x && cat > src/Foo.cs <<'EOF'\n" + body + "\nEOF" + tail
json.dump({"tool_name": "Bash", "tool_input": {"command": cmd}}, open(out, "w"))
PY
}

# Runs the gate on the payload; sets RC and ELAPSED (whole seconds).
run_timed() {
  local start=$SECONDS
  RC=0
  LC_ALL=C.UTF-8 LANG=C.UTF-8 perl -e 'alarm shift; exec @ARGV or die' "$((BOUND + 2))" bash "$GATE" \
    < "$TMP/payload.json" >/dev/null 2>&1 || RC=$?
  ELAPSED=$(( SECONDS - start ))
}

# 1. A long, harmless heredoc write is allowed within the bound.
make_payload ""
run_timed
[ "$RC" -eq 0 ] || { echo "FAIL: long heredoc write — expected exit 0, got $RC" >&2; fails=$((fails + 1)); }
[ "$ELAPSED" -le "$BOUND" ] || { echo "FAIL: long heredoc write took ${ELAPSED}s (bound ${BOUND}s)" >&2; fails=$((fails + 1)); }

# 2. The same long command with a destructive tail is still denied, within the bound.
make_payload " && rm -rf /"
run_timed
[ "$RC" -eq 2 ] || { echo "FAIL: long command + rm -rf / — expected exit 2, got $RC" >&2; fails=$((fails + 1)); }
[ "$ELAPSED" -le "$BOUND" ] || { echo "FAIL: long command + rm -rf / took ${ELAPSED}s (bound ${BOUND}s)" >&2; fails=$((fails + 1)); }

if [ "$fails" -gt 0 ]; then
  echo "test-security-gate-long-command: $fails failure(s)" >&2
  exit 1
fi
echo "test-security-gate-long-command: PASS"
