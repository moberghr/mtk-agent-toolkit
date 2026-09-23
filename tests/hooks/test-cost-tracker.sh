#!/usr/bin/env bash
set -euo pipefail

# test-cost-tracker.sh — pins hooks/cost-tracker.sh + scripts/session-cost.sh (SC7, SC8).
#
# Fixtures are generated inline inside a mktemp -d sandbox (no fixture files in the
# repo). Expected numbers are computed BY HAND in the comments below, never by
# re-running the parser: a test that derives its oracle from the code under test
# cannot fail.
#
# Transcripts are an internal Claude Code format, so the failure cases matter as
# much as the arithmetic: a missing/unreadable transcript must record NOTHING
# (never zero-filled rows), and the Stop hook must stay silent and exit 0.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SC="$REPO_ROOT/scripts/session-cost.sh"
HOOK="$REPO_ROOT/hooks/cost-tracker.sh"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available" >&2; exit 0; }

SANDBOX="$(mktemp -d)"
trap 'chmod -R u+rwX "$SANDBOX" 2>/dev/null || true; rm -rf "$SANDBOX"' EXIT
export TMPDIR="$SANDBOX"
unset MTK_COST_TRACKER CLAUDE_PLUGIN_ROOT MTK_HELPER_ROOT 2>/dev/null || true

fails=0
expect() {
  local label="$1" want="$2" got="$3"
  if [ "$got" != "$want" ]; then
    printf 'FAIL: %s — expected [%s], got [%s]\n' "$label" "$want" "$got" >&2
    fails=$((fails + 1))
  else
    printf '  PASS  %s\n' "$label"
  fi
}

# Prints a field of the row for SOURCE (Nth such row, 0-based) in costs.jsonl.
# FIELD is a dotted path; floats are printed rounded to 6 places; null -> "null".
field() { # $1=costs.jsonl $2=source $3=field $4=index (default 0)
  python3 - "$1" "$2" "$3" "${4:-0}" <<'PY'
import json, sys
path, src, fld, idx = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
try:
    rows = [json.loads(l) for l in open(path) if l.strip()]
except OSError:
    print("NO-FILE"); sys.exit(0)
rows = [r for r in rows if r.get("source") == src]
if idx >= len(rows):
    print("NO-ROW"); sys.exit(0)
v = rows[idx]
for part in fld.split("."):
    v = v.get(part) if isinstance(v, dict) else None
print("null" if v is None else ("%.6f" % v if isinstance(v, float) else v))
PY
}

rows() { # $1=costs.jsonl → number of rows (0 when absent)
  if [ -f "$1" ]; then awk 'NF' "$1" | wc -l | tr -d ' '; else echo 0; fi
}

# asst ID MODEL IN OUT CC CR [C5 C1] — one assistant transcript line. With C5/C1 the
# cache_creation split is present; without it the whole CC counts as the 5m tier.
asst() {
  local split=""
  if [ $# -ge 8 ]; then
    split=",\"cache_creation\":{\"ephemeral_5m_input_tokens\":$7,\"ephemeral_1h_input_tokens\":$8}"
  fi
  printf '{"type":"assistant","message":{"id":"%s","model":"%s","role":"assistant","content":[{"type":"text","text":"secret prose"}],"usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s%s}}}\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$split"
}

# --- Fixture: main transcript + one subagent -----------------------------------
PROJ="$SANDBOX/project"
TDIR="$SANDBOX/transcripts"
SID="sess-1"
MAIN="$TDIR/$SID.jsonl"
MD="$SANDBOX/metrics"
mkdir -p "$PROJ" "$TDIR/$SID/subagents"
{
  printf '{"type":"user","message":{"role":"user","content":"hi"}}\n'
  # msg_A (claude-opus-5-5), repeated on 3 lines (one per content block) with the same usage.
  asst msg_A claude-opus-5-5 100 50 1000 2000 600 400
  asst msg_A claude-opus-5-5 100 50 1000 2000 600 400
  printf '{not valid json\n'
  asst msg_A claude-opus-5-5 100 50 1000 2000 600 400
  # msg_B: context-suffixed id, no cache_creation split -> all 300 are 5m writes.
  asst msg_B 'claude-opus-5-5[1m]' 10 20 300 0
  # msg_C: an unknown model.
  asst msg_C claude-test-9 7 3 0 0
  printf '{"type":"system","subtype":"x"}\n'
} > "$MAIN"
# Subagent: date-suffixed haiku id.
asst msg_S claude-haiku-4-5-20251001 1000 200 0 0 > "$TDIR/$SID/subagents/agent-abc.jsonl"

rc=0
bash "$SC" record --transcript "$MAIN" --session "$SID" --metrics-dir "$MD" || rc=$?
expect "record exits 0" 0 "$rc"
C="$MD/costs.jsonl"
expect "one row per source (main + subagent)" 2 "$(rows "$C")"

# Main deduped totals, by hand:
#   input  = 100 (A once) + 10 (B) + 7 (C)  = 117   (no dedupe would give 317)
#   output =  50 + 20 + 3                    =  73
#   cw_5m  = 600 (A split) + 300 (B, no split) = 900
#   cw_1h  = 400 (A split)                   = 400
#   read   = 2000 (A once)                   = 2000 (no dedupe would give 6000)
expect "main input deduped"  117  "$(field "$C" main tokens.input)"
expect "main output deduped" 73   "$(field "$C" main tokens.output)"
expect "main cache_write_5m (split + unsplit fallback)" 900 "$(field "$C" main tokens.cache_write_5m)"
expect "main cache_write_1h" 400  "$(field "$C" main tokens.cache_write_1h)"
expect "main cache_read deduped" 2000 "$(field "$C" main tokens.cache_read)"
# est_usd, opus-5-5 at 4 / 20 / 5 / 8 / 0.20 per MTok:
#   A: 100*4 + 50*20 + 600*5 + 400*8 + 2000*0.2 = 400+1000+3000+3200+400 = 8000 -> 0.008
#   B ([1m] stripped): 10*4 + 20*20 + 300*5 = 40+400+1500 = 1940           -> 0.00194
#   C: unpriced (10 tokens), contributes nothing
expect "main est_usd = priced messages only" 0.009940 "$(field "$C" main est_usd)"
expect "main unpriced_tokens counts claude-test-9" 10 "$(field "$C" main unpriced_tokens)"
expect "main model = last model seen" claude-test-9 "$(field "$C" main model)"
expect "main pricing_as_of" 2026-09-23 "$(field "$C" main pricing_as_of)"
expect "row carries session id" "$SID" "$(field "$C" main session_id)"
# Subagent: haiku-4-5 (date suffix stripped) at 1 / 5: 1000*1 + 200*5 = 2000 -> 0.002
expect "subagent input"  1000 "$(field "$C" subagent:abc tokens.input)"
expect "subagent est_usd (date suffix normalised)" 0.002000 "$(field "$C" subagent:abc est_usd)"
if grep -q "secret prose" "$C" "$MD/sessions/$SID.json"; then
  expect "no transcript content copied into metrics" clean leaked
else
  expect "no transcript content copied into metrics" clean clean
fi

# --- Idempotence and deltas ----------------------------------------------------
bash "$SC" record --transcript "$MAIN" --session "$SID" --metrics-dir "$MD"
expect "second record with no new messages writes 0 rows" 2 "$(rows "$C")"

# Append a re-emitted msg_A line (must not count again) plus a new msg_D.
asst msg_A claude-opus-5-5 100 50 1000 2000 600 400 >> "$MAIN"
asst msg_D claude-opus-5-5 5 5 0 0 >> "$MAIN"
bash "$SC" record --transcript "$MAIN" --session "$SID" --metrics-dir "$MD"
expect "new message -> exactly one new row" 3 "$(rows "$C")"
expect "delta row holds only the new input"  5 "$(field "$C" main tokens.input 1)"
expect "delta row holds only the new output" 5 "$(field "$C" main tokens.output 1)"
expect "delta row: no re-counted cache_read" 0 "$(field "$C" main tokens.cache_read 1)"
# D: 5*4 + 5*20 = 120 -> 0.00012
expect "delta row est_usd" 0.000120 "$(field "$C" main est_usd 1)"

# A rewritten (shrunk) transcript: the cumulative went down, so the new cumulative is the delta.
R="$SANDBOX/rewrite"; mkdir -p "$R"
{ asst r1 claude-opus-5-5 50 0 0 0; asst r2 claude-opus-5-5 50 0 0 0; } > "$R/t.jsonl"
bash "$SC" record --transcript "$R/t.jsonl" --session rw --metrics-dir "$R/m"
asst r3 claude-opus-5-5 30 0 0 0 > "$R/t.jsonl"
bash "$SC" record --transcript "$R/t.jsonl" --session rw --metrics-dir "$R/m"
expect "shrunk transcript -> delta is the new cumulative" 30 "$(field "$R/m/costs.jsonl" main tokens.input 1)"

# --- Pricing edge cases ----------------------------------------------------------
P="$SANDBOX/pricing"; mkdir -p "$P"
asst u1 claude-test-9 11 1 0 0 > "$P/unknown.jsonl"
bash "$SC" record --transcript "$P/unknown.jsonl" --session unknown --metrics-dir "$P/m"
expect "only-unpriced model -> est_usd null" null "$(field "$P/m/costs.jsonl" main est_usd)"
expect "only-unpriced model still records tokens" 11 "$(field "$P/m/costs.jsonl" main tokens.input)"

# fable-5-1: 1M input * 10 + 1M read * 0.25 = 10.25. Borrowing fable-5 (read 1.00) would give 11.
asst f1 claude-fable-5-1 1000000 0 0 1000000 > "$P/fable.jsonl"
bash "$SC" record --transcript "$P/fable.jsonl" --session fable --metrics-dir "$P/f"
expect "claude-fable-5-1 priced on its own row" 10.250000 "$(field "$P/f/costs.jsonl" main est_usd)"

# claude-mythos-5-1 is not in the table: exact lookup, no prefix match onto mythos-5.
asst y1 claude-mythos-5-1 100 0 0 0 > "$P/mythos.jsonl"
bash "$SC" record --transcript "$P/mythos.jsonl" --session mythos --metrics-dir "$P/y"
expect "claude-mythos-5-1 not priced as claude-mythos-5" null "$(field "$P/y/costs.jsonl" main est_usd)"

# --- Failure paths record nothing -----------------------------------------------
rc=0
bash "$SC" record --transcript "$SANDBOX/nope.jsonl" --session gone --metrics-dir "$SANDBOX/m-missing" || rc=$?
expect "missing transcript exits 0" 0 "$rc"
expect "missing transcript writes no rows" 0 "$(rows "$SANDBOX/m-missing/costs.jsonl")"

if [ "$(id -u)" != "0" ]; then
  cp "$MAIN" "$SANDBOX/locked.jsonl"; chmod 000 "$SANDBOX/locked.jsonl"
  rc=0
  bash "$SC" record --transcript "$SANDBOX/locked.jsonl" --session locked --metrics-dir "$SANDBOX/m-locked" 2>/dev/null || rc=$?
  expect "unreadable transcript fails (non-zero)" 1 "$rc"
  expect "unreadable transcript writes no rows" 0 "$(rows "$SANDBOX/m-locked/costs.jsonl")"
fi

# --- window (SC8) ----------------------------------------------------------------
W="$SANDBOX/window"; mkdir -p "$W"
{
  printf '{"ts":"2026-01-01T00:00:00Z","session_id":"s","source":"main","model":"m","tokens":{"input":10,"output":1,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0},"est_usd":0.5,"unpriced_tokens":0,"pricing_as_of":"2026-09-23"}\n'
  printf '{"ts":"2026-01-15T12:00:00Z","session_id":"s","source":"subagent:x","model":"m","tokens":{"input":20,"output":2,"cache_write_5m":3,"cache_write_1h":0,"cache_read":4},"est_usd":null,"unpriced_tokens":29,"pricing_as_of":"2026-09-23"}\n'
  printf 'garbage line\n'
  printf '{"ts":"2026-02-01T00:00:00Z","session_id":"s","source":"main","model":"m","tokens":{"input":1000,"output":1000,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0},"est_usd":9.0,"unpriced_tokens":0,"pricing_as_of":"2026-09-23"}\n'
} > "$W/costs.jsonl"

WJ=$(bash "$SC" window --since 2026-01-01T00:00:00Z --until 2026-01-31T23:59:59Z --json --metrics-dir "$W")
jget() { # $1=dotted path into $WJ
  python3 -c $'import json, sys\nv = json.loads(sys.argv[1])\nfor k in sys.argv[2].split("."):\n    v = v[k]\nprint("null" if v is None else ("%.6f" % v if isinstance(v, float) else v))' "$WJ" "$1"
}
expect "window counts rows inside (boundary inclusive)" 2 "$(jget rows)"
expect "window sums input (10+20, Feb row excluded)" 30 "$(jget tokens.input)"
expect "window sums cache_read" 4 "$(jget tokens.cache_read)"
expect "window est_usd ignores null rows" 0.500000 "$(jget est_usd)"
expect "window unpriced_tokens" 29 "$(jget unpriced_tokens)"

WJ=$(bash "$SC" window --since 2026-01-10T00:00:00Z --until 2026-01-20T00:00:00Z --json --metrics-dir "$W")
expect "window of only-null rows -> est_usd null" null "$(jget est_usd)"

expect "empty window prints not recorded" "not recorded" \
  "$(bash "$SC" window --since 2025-01-01T00:00:00Z --until 2025-01-02T00:00:00Z --metrics-dir "$W")"
expect "empty window --json" '{"status": "not recorded"}' \
  "$(bash "$SC" window --since 2025-01-01T00:00:00Z --until 2025-01-02T00:00:00Z --json --metrics-dir "$W")"
expect "no costs file -> not recorded" "not recorded" \
  "$(bash "$SC" window --since 2025-01-01T00:00:00Z --until 2027-01-01T00:00:00Z --metrics-dir "$SANDBOX/none")"
HUMAN=$(bash "$SC" window --since 2026-01-01T00:00:00Z --until 2026-01-31T23:59:59Z --metrics-dir "$W")
case "$HUMAN" in
  "API-equivalent estimate"*) expect "human output is labelled an estimate" yes yes ;;
  *) expect "human output is labelled an estimate" yes "$HUMAN" ;;
esac

rc=0; bash "$SC" window --since yesterday --until now --metrics-dir "$W" >/dev/null 2>&1 || rc=$?
expect "invalid timestamp is a usage error" 2 "$rc"
rc=0; bash "$SC" --help >/dev/null || rc=$?
expect "--help exits 0" 0 "$rc"

# --- The Stop hook -----------------------------------------------------------------
PAYLOAD=$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"Stop","stop_hook_active":false}' "$SID" "$MAIN" "$PROJ")

rc=0
OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$PROJ" MTK_COST_TRACKER=0 bash "$HOOK" 2>&1) || rc=$?
expect "hook kill-switch exits 0" 0 "$rc"
expect "hook kill-switch prints nothing" "" "$OUT"
[ -e "$PROJ/.mtk" ] && k=wrote || k=nothing
expect "hook kill-switch writes nothing" nothing "$k"

rc=0
OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" 2>&1) || rc=$?
expect "hook exits 0" 0 "$rc"
expect "hook prints nothing" "" "$OUT"
expect "hook records into <project>/.mtk/metrics" 2 "$(rows "$PROJ/.mtk/metrics/costs.jsonl")"
expect "hook row main input (dedupe incl. re-emitted A)" 122 "$(field "$PROJ/.mtk/metrics/costs.jsonl" main tokens.input)"

rc=0
OUT=$(printf '{"session_id":"x","transcript_path":"%s/missing.jsonl"}' "$SANDBOX" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" 2>&1) || rc=$?
expect "hook with missing transcript exits 0 silently" "0:" "$rc:$OUT"

rc=0
OUT=$(printf 'not json at all' | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" 2>&1) || rc=$?
expect "hook with garbage payload exits 0 silently" "0:" "$rc:$OUT"
expect "garbage payloads added no rows" 2 "$(rows "$PROJ/.mtk/metrics/costs.jsonl")"

# --- SF1: a failed record is surfaced, not swallowed ---------------------------------
# The hook stays silent (exit 0, no output) but leaves ONE line in
# <metrics>/.last-error; `window` then warns that rows may be missing.
PROJ2="$SANDBOX/project2"; MD2="$PROJ2/.mtk/metrics"
mkdir -p "$MD2/sessions"
printf '{corrupt snapshot' > "$MD2/sessions/$SID.json"
PAYLOAD2=$(printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop"}' "$SID" "$MAIN")
LE="$MD2/.last-error"
rc=0
OUT=$(CLAUDE_PROJECT_DIR="$PROJ2" bash "$HOOK" 2>&1 <<<"$PAYLOAD2") || rc=$?
expect "corrupt snapshot: hook exits 0" 0 "$rc"
expect "corrupt snapshot: hook prints nothing" "" "$OUT"
[ -f "$LE" ] && le=present || le=absent
expect "corrupt snapshot: .last-error written" present "$le"
if [ -f "$LE" ]; then
  expect ".last-error is exactly one line" 1 "$(wc -l < "$LE" | tr -d ' ')"
  IFS=$'\t' read -r le_ts le_rc le_msg < "$LE" || true
  case "$le_ts" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) k=iso ;;
    *) k="$le_ts" ;;
  esac
  expect ".last-error field 1 is an ISO-UTC timestamp" iso "$k"
  expect ".last-error field 2 is the record exit code" 1 "$le_rc"
  case "$le_msg" in
    *"record failed, nothing recorded"*) k=yes ;;
    *) k="$le_msg" ;;
  esac
  expect ".last-error field 3 carries the stderr message" yes "$k"
  [ "${#le_msg}" -le 200 ] && k=yes || k="${#le_msg}"
  expect ".last-error message capped at 200 chars" yes "$k"
fi
# A second failure overwrites, never appends.
CLAUDE_PROJECT_DIR="$PROJ2" bash "$HOOK" >/dev/null 2>&1 <<<"$PAYLOAD2" || true
[ -f "$LE" ] && expect "second failure overwrites .last-error (still one line)" 1 "$(wc -l < "$LE" | tr -d ' ')"

# window surfaces the failure (text: before the table / alongside "not recorded"; json: last_error).
WOUT=$(bash "$SC" window --since 2000-01-01T00:00:00Z --until 2000-01-02T00:00:00Z --metrics-dir "$MD2")
case "$WOUT" in
  "warning: cost tracking failed at "*"(rc=1): "*" — rows after that point may be missing"*"not recorded") k=yes ;;
  *) k="$WOUT" ;;
esac
expect "window (not recorded) prints the .last-error warning first" yes "$k"
cp "$W/costs.jsonl" "$MD2/costs.jsonl"
WOUT=$(bash "$SC" window --since 2026-01-01T00:00:00Z --until 2026-01-31T23:59:59Z --metrics-dir "$MD2")
case "$WOUT" in
  "warning: cost tracking failed at "*$'\n'"API-equivalent estimate"*) k=yes ;;
  *) k="$WOUT" ;;
esac
expect "window (recorded) prints the warning before the table" yes "$k"
WJ=$(bash "$SC" window --since 2026-01-01T00:00:00Z --until 2026-01-31T23:59:59Z --json --metrics-dir "$MD2")
expect "window --json carries last_error.rc" 1 "$(jget last_error.rc)"
expect "window --json still sums rows" 2 "$(jget rows)"
WJ=$(bash "$SC" window --since 2000-01-01T00:00:00Z --until 2000-01-02T00:00:00Z --json --metrics-dir "$MD2")
expect "window --json not recorded carries last_error.rc" 1 "$(jget last_error.rc)"
expect "window --json not recorded status" "not recorded" "$(jget status)"
rm -f "$MD2/costs.jsonl"

# A later successful record clears the stale error.
printf '{"session_id":"%s","sources":{}}' "$SID" > "$MD2/sessions/$SID.json"
rc=0
OUT=$(CLAUDE_PROJECT_DIR="$PROJ2" bash "$HOOK" 2>&1 <<<"$PAYLOAD2") || rc=$?
expect "repaired snapshot: hook exits 0 silently" "0:" "$rc:$OUT"
[ -f "$LE" ] && le=present || le=absent
expect "successful record clears .last-error" absent "$le"
expect "successful record wrote rows" 2 "$(rows "$MD2/costs.jsonl")"
expect "window without .last-error has no warning" "not recorded" \
  "$(bash "$SC" window --since 2000-01-01T00:00:00Z --until 2000-01-02T00:00:00Z --metrics-dir "$MD2")"

# --- T4: wiring (hooks.json + .claude/settings.json) ---------------------------------
# Parsed as JSON, exact event key + matcher: a typo'd event key must fail this.
wiring() { # $1=file $2=event $3=matcher ("" = none) $4=hook basename $5=require async (0/1)
  python3 - "$@" <<'PY'
import json, sys
path, event, matcher, base, need_async = sys.argv[1:6]
try:
    hooks = json.load(open(path)).get("hooks", {})
except (OSError, ValueError) as exc:
    print("unparseable: %s" % exc); sys.exit(0)
for m in hooks.get(event, []) or []:
    if (m.get("matcher") or "") != matcher:
        continue
    for h in m.get("hooks", []) or []:
        if h.get("command", "").rstrip().endswith("/hooks/" + base):
            if need_async == "1" and h.get("async") is not True:
                print("wired-not-async"); sys.exit(0)
            print("wired"); sys.exit(0)
print("missing")
PY
}
for wf in hooks/hooks.json .claude/settings.json; do
  expect "$wf wires cost-tracker.sh under Stop with async true" wired \
    "$(wiring "$REPO_ROOT/$wf" Stop "" cost-tracker.sh 1)"
done

if [ "$fails" -gt 0 ]; then
  printf '%d cost-tracker case(s) failed\n' "$fails" >&2
else
  printf 'All cost-tracker cases passed\n'
fi
exit "$fails"
