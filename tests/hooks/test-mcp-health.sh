#!/usr/bin/env bash
set -euo pipefail

# test-mcp-health.sh — exercises hooks/mcp-health.sh (SC6).
# Follows the tests/hooks/test-interactive-guard.sh style: run_hook + expect
# label/want/got, `fails` counter in the parent shell, exit $fails.
#
# TMPDIR is pointed at a mktemp -d for the whole run so hook state never
# leaks between cases or into the real session (per plan conventions).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/mcp-health.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/hooks/lib/hook-io.sh"

export TMPDIR
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

STATE_FILE="${TMPDIR}/mtk-mcp-health-$(mtk_repo_root | cksum | cut -d' ' -f1)"

fails=0

expect() {
  local label="$1" want="$2" got="$3"
  if [ "$got" != "$want" ]; then
    printf 'FAIL: %s — expected %s, got %s\n' "$label" "$want" "$got" >&2
    fails=$((fails + 1))
  else
    printf '  PASS  %s\n' "$label"
  fi
}

expect_contains() {
  local label="$1" needle="$2" haystack="$3"
  if case "$haystack" in *"$needle"*) true ;; *) false ;; esac; then
    printf '  PASS  %s\n' "$label"
  else
    printf 'FAIL: %s — expected output to contain %q\n' "$label" "$needle" >&2
    printf '  --- got ---\n%s\n  --- end ---\n' "$haystack" >&2
    fails=$((fails + 1))
  fi
}

# Runs the hook with PAYLOAD on stdin, honouring extra env assignments passed
# as NAME=value pairs before the payload arg. Captures combined stdout+stderr
# (for advisory/deny text assertions) and the exit code separately, via a
# side-channel file so `set -e` in this test script cannot swallow it.
run_hook() {
  local payload="$1"
  shift
  local out rc
  out="$(env "$@" bash -c 'printf "%s" "$1" | "$2"' _ "$payload" "$HOOK" 2>&1)" && rc=0 || rc=$?
  printf '%s\x1f%s' "$rc" "$out"
}

hook_exit() {
  # $1 = the run_hook() result string
  printf '%s' "${1%%$'\x1f'*}"
}

hook_out() {
  printf '%s' "${1#*$'\x1f'}"
}

payload_failure() {
  # $1 = tool_name  $2 = error text
  printf '{"hook_event_name":"PostToolUseFailure","tool_name":"%s","tool_input":{},"tool_use_id":"tu1","error":"%s"}' "$1" "$2"
}

payload_failure_tool_response() {
  # $1 = tool_name  $2 = tool_response text (error field absent)
  printf '{"hook_event_name":"PostToolUseFailure","tool_name":"%s","tool_input":{},"tool_use_id":"tu1","tool_response":"%s"}' "$1" "$2"
}

payload_pre() {
  printf '{"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{}}' "$1"
}

payload_post_success() {
  printf '{"hook_event_name":"PostToolUse","tool_name":"%s","tool_input":{},"tool_response":"ok"}' "$1"
}

get_field() {
  # $1 = server name  $2 = 1-based field index (1=server 2=failures 3=next_retry 4=code 5=ts)
  [ -f "$STATE_FILE" ] || { printf ''; return 0; }
  awk -F'\t' -v s="$1" -v f="$2" '$1==s{print $f}' "$STATE_FILE"
}

# --- 1. transport failure -> next Pre is advisory, names srv and "retry in" ---

rm -f "$STATE_FILE"
r1="$(run_hook "$(payload_failure "mcp__srv__x" "ECONNREFUSED at 127.0.0.1:9")" MTK_MCP_HEALTH_NOW=1000)"
expect "transport failure PostToolUseFailure exit 0" 0 "$(hook_exit "$r1")"

r2="$(run_hook "$(payload_pre "mcp__srv__y")" MTK_MCP_HEALTH_NOW=1005)"
expect "advisory PreToolUse exit 0" 0 "$(hook_exit "$r2")"
expect_contains "advisory names server" "srv" "$(hook_out "$r2")"
expect_contains "advisory says retry in" "retry in" "$(hook_out "$r2")"

# --- 2. enforce -> exit 2 -----------------------------------------------------

r3="$(run_hook "$(payload_pre "mcp__srv__y")" MTK_MCP_HEALTH_NOW=1005 MTK_MCP_HEALTH_ENFORCE=1)"
expect "enforce denies during backoff" 2 "$(hook_exit "$r3")"

# --- 3. a second failure doubles the backoff (check recorded next_retry) -----

rm -f "$STATE_FILE"
run_hook "$(payload_failure "mcp__srv2__x" "ECONNREFUSED")" MTK_MCP_HEALTH_NOW=1000 \
  MTK_MCP_HEALTH_BACKOFF_BASE_SECS=30 MTK_MCP_HEALTH_BACKOFF_MAX_SECS=600 >/dev/null
next1="$(get_field srv2 3)"
expect "first failure next_retry = now+30" 1030 "$next1"

run_hook "$(payload_failure "mcp__srv2__x" "ECONNREFUSED")" MTK_MCP_HEALTH_NOW=1010 \
  MTK_MCP_HEALTH_BACKOFF_BASE_SECS=30 MTK_MCP_HEALTH_BACKOFF_MAX_SECS=600 >/dev/null
next2="$(get_field srv2 3)"
expect "second failure doubles backoff: next_retry = 1010+60" 1070 "$next2"
failures2="$(get_field srv2 2)"
expect "failures count is 2 after second failure" 2 "$failures2"

# --- 4. success clears the record ---------------------------------------------

r4="$(run_hook "$(payload_post_success "mcp__srv2__x")" MTK_MCP_HEALTH_NOW=1020)"
expect "PostToolUse success exit 0" 0 "$(hook_exit "$r4")"
cleared="$(get_field srv2 1)"
expect "record cleared after success" "" "$cleared"

# --- 5. a validation error records nothing ------------------------------------

rm -f "$STATE_FILE"
r5="$(run_hook "$(payload_failure "mcp__srv3__x" "400 Bad Request: invalid argument foo")" MTK_MCP_HEALTH_NOW=2000)"
expect "validation error exit 0" 0 "$(hook_exit "$r5")"
if [ -f "$STATE_FILE" ]; then
  rec3="$(get_field srv3 1)"
  expect "validation error records nothing" "" "$rec3"
else
  printf '  PASS  validation error records nothing (no state file written)\n'
fi

# --- 6. expiry allows the call -------------------------------------------------

rm -f "$STATE_FILE"
run_hook "$(payload_failure "mcp__srv4__x" "ECONNREFUSED")" MTK_MCP_HEALTH_NOW=3000 \
  MTK_MCP_HEALTH_BACKOFF_BASE_SECS=30 MTK_MCP_HEALTH_BACKOFF_MAX_SECS=600 >/dev/null
r6="$(run_hook "$(payload_pre "mcp__srv4__y")" MTK_MCP_HEALTH_NOW=3100)"
expect "after backoff expiry, PreToolUse allowed" 0 "$(hook_exit "$r6")"
expect "after backoff expiry, no advisory text emitted" "" "$(hook_out "$r6")"

# --- 7. a non-MCP tool name is ignored -----------------------------------------

rm -f "$STATE_FILE"
r7="$(run_hook '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{},"error":"ECONNREFUSED"}' MTK_MCP_HEALTH_NOW=4000)"
expect "non-MCP tool name ignored" 0 "$(hook_exit "$r7")"
if [ -f "$STATE_FILE" ]; then
  printf 'FAIL: non-MCP tool name wrote state\n' >&2
  fails=$((fails + 1))
else
  printf '  PASS  non-MCP tool name writes no state\n'
fi

# --- 8. a malformed server name is ignored -------------------------------------

rm -f "$STATE_FILE"
r8="$(run_hook '{"hook_event_name":"PostToolUseFailure","tool_name":"mcp__bad server!__x","tool_input":{},"error":"ECONNREFUSED"}' MTK_MCP_HEALTH_NOW=4000)"
expect "malformed server name ignored" 0 "$(hook_exit "$r8")"
if [ -f "$STATE_FILE" ]; then
  printf 'FAIL: malformed server name wrote state\n' >&2
  fails=$((fails + 1))
else
  printf '  PASS  malformed server name writes no state\n'
fi

# --- 9. MTK_MCP_HEALTH=0 is silent ---------------------------------------------

rm -f "$STATE_FILE"
r9="$(run_hook "$(payload_failure "mcp__srv5__x" "ECONNREFUSED")" MTK_MCP_HEALTH_NOW=5000 MTK_MCP_HEALTH=0)"
expect "MTK_MCP_HEALTH=0 exit 0" 0 "$(hook_exit "$r9")"
if [ -f "$STATE_FILE" ]; then
  printf 'FAIL: MTK_MCP_HEALTH=0 still wrote state\n' >&2
  fails=$((fails + 1))
else
  printf '  PASS  MTK_MCP_HEALTH=0 writes no state\n'
fi

# --- 10. a payload without hook_event_name exits 0 -----------------------------

r10="$(run_hook '{"tool_name":"mcp__srv__x","tool_input":{},"error":"ECONNREFUSED"}' MTK_MCP_HEALTH_NOW=6000)"
expect "payload without hook_event_name exits 0" 0 "$(hook_exit "$r10")"

# --- 11. empty / unparseable payload fails open --------------------------------

r11="$(run_hook '' MTK_MCP_HEALTH_NOW=6000)"
expect "empty payload fails open" 0 "$(hook_exit "$r11")"

r11b="$(run_hook 'not json at all' MTK_MCP_HEALTH_NOW=6000)"
expect "unparseable payload fails open" 0 "$(hook_exit "$r11b")"

# --- 12. other error classes: auth/403/429/503, and fallback to tool_response --

rm -f "$STATE_FILE"
run_hook "$(payload_failure "mcp__srva__x" "401 Unauthorized: token expired")" MTK_MCP_HEALTH_NOW=7000 >/dev/null
expect "auth (401) recorded" auth "$(get_field srva 4)"

rm -f "$STATE_FILE"
run_hook "$(payload_failure "mcp__srvb__x" "HTTP 403 Forbidden")" MTK_MCP_HEALTH_NOW=7000 >/dev/null
expect "forbidden (403) recorded" forbidden "$(get_field srvb 4)"

rm -f "$STATE_FILE"
run_hook "$(payload_failure "mcp__srvc__x" "429 Too Many Requests")" MTK_MCP_HEALTH_NOW=7000 >/dev/null
expect "rate-limit (429) recorded" rate-limit "$(get_field srvc 4)"

rm -f "$STATE_FILE"
run_hook "$(payload_failure "mcp__srvd__x" "503 Service Unavailable")" MTK_MCP_HEALTH_NOW=7000 >/dev/null
expect "unavailable (503) recorded" unavailable "$(get_field srvd 4)"

rm -f "$STATE_FILE"
run_hook "$(payload_failure_tool_response "mcp__srve__x" "connection closed unexpectedly")" MTK_MCP_HEALTH_NOW=7000 >/dev/null
expect "fallback to tool_response classifies transport" transport "$(get_field srve 4)"

# --- 13. backoff caps at MTK_MCP_HEALTH_BACKOFF_MAX_SECS -----------------------

rm -f "$STATE_FILE"
n=1
while [ "$n" -le 6 ]; do
  run_hook "$(payload_failure "mcp__srvf__x" "ECONNREFUSED")" MTK_MCP_HEALTH_NOW=8000 \
    MTK_MCP_HEALTH_BACKOFF_BASE_SECS=30 MTK_MCP_HEALTH_BACKOFF_MAX_SECS=600 >/dev/null
  n=$((n + 1))
done
# failures=6 -> 30*2^5=960, capped at 600 -> next_retry = 8000+600 = 8600
expect "backoff caps at MTK_MCP_HEALTH_BACKOFF_MAX_SECS" 8600 "$(get_field srvf 3)"

# --- 14. 70+ failures: no int64 overflow, still capped + advisory (F002) -------

rm -f "$STATE_FILE"
n=1
while [ "$n" -le 72 ]; do
  run_hook "$(payload_failure "mcp__srvg__x" "ECONNREFUSED")" MTK_MCP_HEALTH_NOW=9000 >/dev/null
  n=$((n + 1))
done
expect "72 failures: next_retry = now+MAX (no overflow)" 9600 "$(get_field srvg 3)"
expect "72 failures: counter recorded" 72 "$(get_field srvg 2)"
r14="$(run_hook "$(payload_pre "mcp__srvg__y")" MTK_MCP_HEALTH_NOW=9005)"
expect "72 failures: PreToolUse exit 0" 0 "$(hook_exit "$r14")"
expect_contains "72 failures: advisory still emitted" "retry in 595s" "$(hook_out "$r14")"

# Stored failure counter is capped at 1000.
printf 'srvh\t5000\t0\ttransport\t0\n' > "$STATE_FILE"
run_hook "$(payload_failure "mcp__srvh__x" "ECONNREFUSED")" MTK_MCP_HEALTH_NOW=9000 >/dev/null
expect "failure counter capped at 1000" 1000 "$(get_field srvh 2)"
expect "capped counter: next_retry = now+MAX" 9600 "$(get_field srvh 3)"

# Leading zero is read as decimal (10#), never octal: BASE=08 -> 8s, no crash.
rm -f "$STATE_FILE"
rb="$(run_hook "$(payload_failure "mcp__srvi__x" "ECONNREFUSED")" MTK_MCP_HEALTH_NOW=9000 \
  MTK_MCP_HEALTH_BACKOFF_BASE_SECS=08)"
expect "BASE='08' failure exit 0" 0 "$(hook_exit "$rb")"
expect "BASE='08' read as decimal 8" 9008 "$(get_field srvi 3)"
rp="$(run_hook "$(payload_pre "mcp__srvi__y")" MTK_MCP_HEALTH_NOW=9005)"
expect_contains "BASE='08' advisory still correct" "retry in 3s" "$(hook_out "$rp")"

# Non-numeric / overlong / empty env values fall back to the defaults (30/600).
for bad in abc 99999999999999999999 '' -5 '1e3'; do
  rm -f "$STATE_FILE"
  rb="$(run_hook "$(payload_failure "mcp__srvi__x" "ECONNREFUSED")" MTK_MCP_HEALTH_NOW=9000 \
    MTK_MCP_HEALTH_BACKOFF_BASE_SECS="$bad")"
  expect "BASE='$bad' failure exit 0" 0 "$(hook_exit "$rb")"
  expect "BASE='$bad' falls back to base 30" 9030 "$(get_field srvi 3)"
  rp="$(run_hook "$(payload_pre "mcp__srvi__y")" MTK_MCP_HEALTH_NOW=9010)"
  expect_contains "BASE='$bad' advisory still correct" "retry in 20s" "$(hook_out "$rp")"
done
rm -f "$STATE_FILE"
rb="$(run_hook "$(payload_failure "mcp__srvj__x" "ECONNREFUSED")" MTK_MCP_HEALTH_NOW=9000 \
  MTK_MCP_HEALTH_BACKOFF_BASE_SECS=10 MTK_MCP_HEALTH_BACKOFF_MAX_SECS=09)"
expect "MAX='09' failure exit 0" 0 "$(hook_exit "$rb")"
expect "MAX='09' read as decimal 9 (caps base 10)" 9009 "$(get_field srvj 3)"
rm -f "$STATE_FILE"
rb="$(run_hook "$(payload_failure "mcp__srvj__x" "ECONNREFUSED")" MTK_MCP_HEALTH_NOW=9000 \
  MTK_MCP_HEALTH_BACKOFF_BASE_SECS=1000 MTK_MCP_HEALTH_BACKOFF_MAX_SECS=abc)"
expect "MAX='abc' failure exit 0" 0 "$(hook_exit "$rb")"
expect "MAX='abc' falls back to max 600" 9600 "$(get_field srvj 3)"

# --- 15. status codes match whole numbers only; no bare "timeout" (F003) ------

for txt in "Invalid input: field id must be <= 4000, got 4031" \
           "timeout must be a positive integer" \
           "offset 14290 out of range" "limit 5031 exceeds 5000" "page 24015 not found"; do
  rm -f "$STATE_FILE"
  rv="$(run_hook "$(payload_failure "mcp__srvk__x" "$txt")" MTK_MCP_HEALTH_NOW=9000)"
  expect "validation text records nothing: $txt (exit)" 0 "$(hook_exit "$rv")"
  expect "validation text records nothing: $txt" "" "$(get_field srvk 1)"
done

rm -f "$STATE_FILE"
run_hook "$(payload_failure "mcp__srvl__x" "request timed out")" MTK_MCP_HEALTH_NOW=9000 >/dev/null
expect "request timed out -> transport" transport "$(get_field srvl 4)"
rm -f "$STATE_FILE"
run_hook "$(payload_failure "mcp__srvl__x" "connect ETIMEDOUT 10.0.0.1:443")" MTK_MCP_HEALTH_NOW=9000 >/dev/null
expect "ETIMEDOUT -> transport" transport "$(get_field srvl 4)"
rm -f "$STATE_FILE"
run_hook "$(payload_failure "mcp__srvl__x" "status=429")" MTK_MCP_HEALTH_NOW=9000 >/dev/null
expect "status=429 (non-digit neighbours) -> rate-limit" rate-limit "$(get_field srvl 4)"

# --- 16. T2: success-clear removes ONLY that server's record ---------------------

rm -f "$STATE_FILE"
run_hook "$(payload_failure "mcp__keep__x" "ECONNREFUSED")" MTK_MCP_HEALTH_NOW=10000 >/dev/null
run_hook "$(payload_failure "mcp__drop__x" "503 Service Unavailable")" MTK_MCP_HEALTH_NOW=10000 >/dev/null
keep_before="$(awk -F'\t' '$1=="keep"' "$STATE_FILE")"
expect "two servers seeded in backoff" "keep drop" "$(get_field keep 1) $(get_field drop 1)"
r16="$(run_hook "$(payload_post_success "mcp__drop__x")" MTK_MCP_HEALTH_NOW=10005)"
expect "success-clear exit 0" 0 "$(hook_exit "$r16")"
expect "success-clear removed the succeeding server" "" "$(get_field drop 1)"
expect "success-clear left the other server's record byte-identical" "$keep_before" \
  "$(awk -F'\t' '$1=="keep"' "$STATE_FILE")"
expect "other server still has 1 failure" 1 "$(get_field keep 2)"

# --- 17. SF3: concurrent failures for distinct servers are all kept --------------

rm -f "$STATE_FILE" "$STATE_FILE.lock"
rmdir "$STATE_FILE.lock" 2>/dev/null || true
i=1
while [ "$i" -le 20 ]; do
  env MTK_MCP_HEALTH_NOW=11000 "$HOOK" >/dev/null 2>&1 \
    <<<"$(payload_failure "mcp__par${i}__x" "ECONNREFUSED")" &
  i=$((i + 1))
done
wait
n_rec=0
[ -f "$STATE_FILE" ] && n_rec="$(awk -F'\t' '$1 ~ /^par[0-9]+$/' "$STATE_FILE" | wc -l | tr -d ' ')"
expect "20 concurrent failures for 20 servers -> 20 records" 20 "$n_rec"
[ -d "$STATE_FILE.lock" ] && lk=left || lk=released
expect "state lock released after concurrent writers" released "$lk"

# --- 18. T4: wiring (hooks.json + .claude/settings.json) --------------------------
# Parsed as JSON, exact event key + matcher: a typo'd event key must fail this.
if command -v python3 >/dev/null 2>&1; then
  wiring() { # $1=file $2=event $3=matcher $4=hook basename
    python3 - "$@" <<'PY'
import json, sys
path, event, matcher, base = sys.argv[1:5]
try:
    hooks = json.load(open(path)).get("hooks", {})
except (OSError, ValueError) as exc:
    print("unparseable: %s" % exc); sys.exit(0)
for m in hooks.get(event, []) or []:
    if (m.get("matcher") or "") == matcher and any(
            h.get("command", "").rstrip().endswith("/hooks/" + base) for h in m.get("hooks", []) or []):
        print("wired"); sys.exit(0)
print("missing")
PY
  }
  for wf in hooks/hooks.json .claude/settings.json; do
    for ev in PreToolUse PostToolUse PostToolUseFailure; do
      expect "$wf wires mcp-health.sh under $ev \"mcp__.*\"" wired \
        "$(wiring "$REPO_ROOT/$wf" "$ev" 'mcp__.*' mcp-health.sh)"
    done
  done
else
  printf '  SKIP  wiring assertions (python3 not available)\n'
fi

if [ "$fails" -ne 0 ]; then
  printf '\n%s assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf '\nmcp-health: all assertions passed\n'
