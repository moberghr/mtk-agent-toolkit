#!/usr/bin/env bash
set -euo pipefail

# hooks/lib/active_workflow.py is the one active-workflow selector behind
# session-start and subagent-context: newest `active` workflow JSON inside the
# updated_at window wins; unreadable / non-dict / bad-timestamp files are skipped.
# Every case runs against a mktemp -d sandbox.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SEL="$REPO_ROOT/hooks/lib/active_workflow.py"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
fails=0
n=0
D=""

TAB="$(printf '\t')"

ts() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=float(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }

fresh_dir() { n=$((n + 1)); D="$SANDBOX/c$n"; mkdir -p "$D"; }
wf() { # $1 name  $2 status  $3 age-days  [$4 extra json members, leading comma]
  printf '{"status":"%s","updated_at":"%s","workflow_type":"implement","phase_cursor":"P2"%s}\n' \
    "$2" "$(ts "$3")" "${4:-}" >"$D/$1.json"
}

check() { # $1 label  $2 expected  $3 actual
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 — expected [$2] got [$3]"
    fails=$((fails + 1))
  fi
}

run() { python3 "$SEL" "$D" "$@" 2>/dev/null; }

# status filter
fresh_dir
wf a complete 0; wf b failed 0; wf c abandoned 0
check "non-active statuses ignored" "" "$(run 7 path)"
wf d ACTIVE 0
check "ACTIVE accepted case-insensitively" "$D/d.json" "$(run 7 path)"

# window
fresh_dir
wf old active 10
check "updated_at outside window ignored" "" "$(run 7 path)"
check "wider window selects it" "$D/old.json" "$(run 30 path)"
check "fractional window honoured" "" "$(run 0.5 path)"

# newest wins
fresh_dir
wf older active 3; wf newer active 1; wf oldest active 5
check "newest active wins" "$D/newer.json" "$(run 7 path)"

# skipped files
fresh_dir
printf 'not json{' >"$D/bad.json"
printf '["a","list"]\n' >"$D/list.json"
printf '{"status":"active","updated_at":"yesterday"}\n' >"$D/ts.json"
printf '{"status":"active"}\n' >"$D/nots.json"
check "bad JSON / non-dict / bad timestamp skipped" "" "$(run 7 path)"
wf good active 2
check "valid file selected beside bad ones" "$D/good.json" "$(run 7 path)"

# fields
fresh_dir
wf f active 1
check "path type phase line" "$D/f.json${TAB}implement${TAB}P2" "$(run 7 path type phase)"
printf '{"status":"active","updated_at":"%s"}\n' "$(ts 1)" >"$D/f.json"
check "type and phase default to ?" "?${TAB}?" "$(run 7 type phase)"

# pack
fresh_dir
wf p active 1 ',"results":{"context_pack":"  .mtk/pack.md  "}'
check "pack stripped" "$D/p.json${TAB}.mtk/pack.md" "$(run 7 path pack)"
wf p active 1 ',"results":{"context_pack":"line1\nline2"}'
check "multiline pack empty" "$D/p.json${TAB}" "$(run 7 path pack)"
wf p active 1 ',"results":{"context_pack":"   "}'
check "blank pack empty" "$D/p.json${TAB}" "$(run 7 path pack)"
wf p active 1 ',"results":{"context_pack":7}'
check "non-string pack empty" "$D/p.json${TAB}" "$(run 7 path pack)"
wf p active 1
check "absent pack empty" "$D/p.json${TAB}" "$(run 7 path pack)"

# no match / bad args
fresh_dir
rc=0; out="$(python3 "$SEL" "$D" 7 path 2>/dev/null)" || rc=$?
check "no match prints nothing" "" "$out"
check "no match exits 0" "0" "$rc"
rc=0; out="$(python3 "$SEL" "$D" 7 bogus 2>/dev/null)" || rc=$?
check "unknown field prints nothing" "" "$out"
check "unknown field exits 2" "2" "$rc"
rc=0; err="$(python3 "$SEL" "$D" 7 bogus 2>&1 >/dev/null)" || rc=$?
check "unknown field one stderr line" "1" "$(printf '%s\n' "$err" | wc -l | tr -d ' ')"
rc=0; out="$(python3 "$SEL" "$D" abc path 2>/dev/null)" || rc=$?
check "bad days exits 2" "2" "$rc"

if [ "$fails" -ne 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "All active-workflow checks passed"
