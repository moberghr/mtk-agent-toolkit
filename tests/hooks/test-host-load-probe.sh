#!/usr/bin/env bash
set -euo pipefail

# host-load-probe.sh: one place that answers "is this host too loaded to
# dispatch an implementer subagent?" so skills do not hand-roll uptime parsing.
#
# WHY. A 2026-09 field run (beacon) dispatched Opus implementers onto a Mac with
# a load average near 100; 20-second dotnet builds took 5–15 minutes and two
# implementers were killed by the harness's 10-minute no-output watchdog. The
# killed-mid-batch recovery respawned into the same conditions and died the same
# way. A probe before dispatch would have routed the run to inline-MAX at once.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/host-load-probe.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; }

[ -x "$SCRIPT" ] || fail "script missing or not executable: $SCRIPT"

# 1. Real host: runs, prints the one-line record, exits 0 or 3 only.
set +e; out="$(bash "$SCRIPT")"; rc=$?; set -e
case "$rc" in 0|3) : ;; *) fail "real probe exited $rc (want 0 ok / 3 overloaded): $out" ;; esac
grep -qE '^host-load: load1=[0-9.]+ cores=[0-9]+ per-core=[0-9.]+ verdict=(ok|overloaded|unknown)' <<<"$out" || fail "record shape wrong: $out"
ok "real host probe runs and reports a well-formed record (rc=$rc)"

# 2. Overloaded: injected load 96 on 12 cores, default max 2.0/core → verdict=overloaded, exit 3.
set +e; out="$(bash "$SCRIPT" --load 96 --cores 12)"; rc=$?; set -e
[ "$rc" -eq 3 ] || fail "overloaded case exited $rc, want 3: $out"
grep -q 'verdict=overloaded' <<<"$out" || fail "overloaded case verdict wrong: $out"
grep -q 'per-core=8.0' <<<"$out" || fail "per-core arithmetic wrong: $out"
ok "load 96 / 12 cores → overloaded, exit 3"

# 3. Fine: load 3 on 12 cores → ok, exit 0.
set +e; out="$(bash "$SCRIPT" --load 3 --cores 12)"; rc=$?; set -e
[ "$rc" -eq 0 ] || fail "ok case exited $rc: $out"
grep -q 'verdict=ok' <<<"$out" || fail "ok case verdict wrong: $out"
ok "load 3 / 12 cores → ok, exit 0"

# 4. Threshold knob: MTK_HOST_LOAD_MAX=10 makes 8.0/core acceptable.
set +e; out="$(MTK_HOST_LOAD_MAX=10 bash "$SCRIPT" --load 96 --cores 12)"; rc=$?; set -e
[ "$rc" -eq 0 ] || fail "MTK_HOST_LOAD_MAX=10 not honoured (rc=$rc): $out"
grep -q 'max=10' <<<"$out" || fail "record does not echo the threshold in use: $out"
ok "MTK_HOST_LOAD_MAX raises the ceiling"

# 5. Boundary: exactly at max is ok (strictly greater trips).
set +e; out="$(bash "$SCRIPT" --load 24 --cores 12)"; rc=$?; set -e
[ "$rc" -eq 0 ] || fail "boundary (2.0 == max) should be ok, got rc=$rc: $out"
ok "per-core equal to max is ok"

# 6. Disabled: MTK_HOST_LOAD_PROBE=0 → verdict=skipped, exit 0, never blocks.
set +e; out="$(MTK_HOST_LOAD_PROBE=0 bash "$SCRIPT" --load 96 --cores 12)"; rc=$?; set -e
[ "$rc" -eq 0 ] || fail "disabled probe must exit 0, got $rc"
grep -q 'verdict=skipped' <<<"$out" || fail "disabled probe verdict wrong: $out"
ok "MTK_HOST_LOAD_PROBE=0 skips without blocking"

# 7. --json emits a parseable object with the same fields.
out="$(bash "$SCRIPT" --json --load 96 --cores 12 || true)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["verdict"]=="overloaded" and d["cores"]==12 and abs(d["per_core"]-8.0)<0.01, d' "$out" \
  || fail "--json output not parseable or wrong: $out"
ok "--json output parses with verdict/cores/per_core"

echo "test-host-load-probe: all checks passed"
