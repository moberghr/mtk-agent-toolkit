#!/usr/bin/env bash
set -euo pipefail

# Test: scripts/verify-commands.sh (F7 — verified-commands stamp mechanics).
# Asserts the JSON contract from
# docs/specs/2026-07-03-v719-setup-improvements.md (F7) and
# docs/plans/2026-07-03-v719-setup-improvements.md (## B1):
#   - `ok\ttrue`            -> status=verified
#   - `bad\tfalse`          -> status=failed, detail contains "exit 1"
#   - `slow\tsleep 3` with --timeout 1 -> status=failed; if a timeout binary
#     is available, detail is the timeout message; if this machine has
#     neither `timeout` nor `gtimeout` (S3.3 graceful degradation), the
#     command instead runs to completion and is `verified` with a
#     "no timeout binary" note — both are accepted outcomes so the test
#     works on a fresh macOS with no coreutils installed
#   - `empty\t` (empty command) -> status=skipped
#   - `piped\tfalse | tee /dev/null` -> status=failed (S-F002 regression: the
#     command runs under `bash -o pipefail -c`, so a failing left-hand
#     command in a pipeline isn't masked by a trailing command — e.g. `tee`
#     — that exits 0)
#
# Exit-1-on-failure style (no subshell pass/fail counters — lesson
# 2026-04-23). Runs entirely in a mktemp scratch dir; the script under test
# is never asked to touch the real repo.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFY="$REPO_ROOT/scripts/verify-commands.sh"

echo "=== verify-commands Test (F7) ==="
[ -f "$VERIFY" ] || { echo "  FAIL  script not found: $VERIFY" >&2; exit 1; }
[ -x "$VERIFY" ] || { echo "  FAIL  script not executable: $VERIFY" >&2; exit 1; }

declare -a FAILS=()

TMPDIR_SCRATCH="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_SCRATCH"; }
trap cleanup EXIT

HAVE_TIMEOUT=0
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  HAVE_TIMEOUT=1
fi

# --- stdin input: ok/bad/slow/empty/piped in one run ------------------------
INPUT_FILE="$TMPDIR_SCRATCH/commands.tsv"
printf 'ok\ttrue\nbad\tfalse\nslow\tsleep 3\nempty\t\npiped\tfalse | tee /dev/null\n' > "$INPUT_FILE"

echo ""; echo "--- run via stdin, --timeout 1 ---"
json_out="$(bash "$VERIFY" --timeout 1 < "$INPUT_FILE")"

if ! printf '%s' "$json_out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  FAILS+=("output did not parse as JSON: $json_out")
fi

status_ok="$(printf '%s' "$json_out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for r in data["results"]:
    if r["name"] == "ok":
        print(r["status"])
        break
')"
if [ "$status_ok" = "verified" ]; then
  echo "  PASS  ok/true -> verified"
else
  FAILS+=("expected ok status=verified, got '$status_ok'. JSON: $json_out")
fi

result_bad="$(printf '%s' "$json_out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for r in data["results"]:
    if r["name"] == "bad":
        print(r["status"])
        print(r["detail"])
        break
')"
status_bad="$(printf '%s\n' "$result_bad" | sed -n 1p)"
detail_bad="$(printf '%s\n' "$result_bad" | sed -n 2p)"
if [ "$status_bad" = "failed" ] && printf '%s' "$detail_bad" | grep -q 'exit 1'; then
  echo "  PASS  bad/false -> failed, detail contains 'exit 1'"
else
  FAILS+=("expected bad status=failed detail containing 'exit 1', got status=$status_bad detail='$detail_bad'. JSON: $json_out")
fi

result_slow="$(printf '%s' "$json_out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for r in data["results"]:
    if r["name"] == "slow":
        print(r["status"])
        print(r["detail"])
        break
')"
status_slow="$(printf '%s\n' "$result_slow" | sed -n 1p)"
detail_slow="$(printf '%s\n' "$result_slow" | sed -n 2p)"
if [ "$HAVE_TIMEOUT" -eq 1 ]; then
  if [ "$status_slow" = "failed" ] && printf '%s' "$detail_slow" | grep -q 'timeout after 1s'; then
    echo "  PASS  slow/sleep-3 with --timeout 1 -> failed, timeout detail"
  else
    FAILS+=("expected slow status=failed detail='timeout after 1s' (timeout binary present), got status=$status_slow detail='$detail_slow'. JSON: $json_out")
  fi
else
  if [ "$status_slow" = "verified" ] && printf '%s' "$detail_slow" | grep -q 'no timeout binary'; then
    echo "  PASS  slow/sleep-3 -> verified with graceful-degradation note (no timeout binary on this machine)"
  else
    FAILS+=("expected slow status=verified with degradation note (no timeout binary), got status=$status_slow detail='$detail_slow'. JSON: $json_out")
  fi
fi

status_empty="$(printf '%s' "$json_out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for r in data["results"]:
    if r["name"] == "empty":
        print(r["status"])
        break
')"
if [ "$status_empty" = "skipped" ]; then
  echo "  PASS  empty command -> skipped"
else
  FAILS+=("expected empty status=skipped, got '$status_empty'. JSON: $json_out")
fi

status_piped="$(printf '%s' "$json_out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for r in data["results"]:
    if r["name"] == "piped":
        print(r["status"])
        break
')"
if [ "$status_piped" = "failed" ]; then
  echo "  PASS  piped false|tee /dev/null -> failed (S-F002 regression: pipefail honored)"
else
  FAILS+=("expected piped status=failed (S-F002 pipefail regression), got '$status_piped'. JSON: $json_out")
fi

# --- --file input produces the same result set ------------------------------
echo ""; echo "--- --file <path> reads the same name<TAB>command format ---"
json_file="$(bash "$VERIFY" --file "$INPUT_FILE" --timeout 1)"
count_file="$(printf '%s' "$json_file" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["results"]))' 2>/dev/null || echo "parse-error")"
if [ "$count_file" = "5" ]; then
  echo "  PASS  --file mode parses all 5 rows"
else
  FAILS+=("expected --file mode to report 5 results, got '$count_file'. JSON: $json_file")
fi

# --- usage errors: exit 2 -----------------------------------------------
echo ""; echo "--- usage errors exit 2 ---"
rc_bad_flag=0
bash "$VERIFY" --nope < /dev/null >/dev/null 2>&1 || rc_bad_flag=$?
if [ "$rc_bad_flag" -eq 2 ]; then
  echo "  PASS  unknown flag exits 2"
else
  FAILS+=("expected exit 2 on unknown flag, got $rc_bad_flag")
fi

rc_missing_file=0
bash "$VERIFY" --file "$TMPDIR_SCRATCH/does-not-exist.tsv" >/dev/null 2>&1 || rc_missing_file=$?
if [ "$rc_missing_file" -eq 2 ]; then
  echo "  PASS  missing --file target exits 2"
else
  FAILS+=("expected exit 2 on missing --file target, got $rc_missing_file")
fi

rc_bad_timeout=0
bash "$VERIFY" --timeout notanumber < /dev/null >/dev/null 2>&1 || rc_bad_timeout=$?
if [ "$rc_bad_timeout" -eq 2 ]; then
  echo "  PASS  non-numeric --timeout exits 2"
else
  FAILS+=("expected exit 2 on non-numeric --timeout, got $rc_bad_timeout")
fi

echo ""
if [ ${#FAILS[@]} -gt 0 ]; then
  printf '  FAIL  %s\n' "${FAILS[@]}" >&2
  exit 1
fi
echo "========================================"
echo "TEST PASSED — all F7 verify-commands assertions green"
