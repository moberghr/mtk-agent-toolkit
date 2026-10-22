#!/usr/bin/env bash
set -euo pipefail

# hooks/subagent-context.sh (SubagentStart) adds the context-pack path and the
# critical-rule ids for `mtk:` agents and while a workflow is live (R1), emits
# nothing and spawns no python otherwise (R2), and caps the block at 4,000 bytes
# at a rule boundary with an omitted-rule count (R3).
#
# Every case runs in a temp git repo under a mktemp -d sandbox, never the real
# repo. python3 calls made BY THE HOOK are counted through a PATH shim that logs
# each call and then execs the real interpreter; the test's own python3 calls
# (JSON decoding, dates) use the unshimmed PATH.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/subagent-context.sh"
FIXTURE="$SCRIPT_DIR/fixtures/subagent-start.payload.json"

command -v python3 >/dev/null 2>&1 || { echo "test-subagent-context: python3 required" >&2; exit 2; }
REAL_PY="$(command -v python3)"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/tmp" "$SANDBOX/shim"
export TMPDIR="$SANDBOX/tmp"
unset CLAUDE_PLUGIN_ROOT MTK_SUBAGENT_CONTEXT

PYLOG="$SANDBOX/python-calls.log"
cat > "$SANDBOX/shim/python3" <<SH
#!/bin/sh
echo "python3 \$*" >> "$PYLOG"
exec "$REAL_PY" "\$@"
SH
chmod +x "$SANDBOX/shim/python3"

fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

# --- fixtures -----------------------------------------------------------------
PACK_SENTENCE="— read it instead of AGENTS.md, the stack skill and the guideline files."

utc_ago() { # $1 = days ago -> ISO-8601 UTC
  "$REAL_PY" -c 'import datetime,sys; t=datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=float(sys.argv[1])); print(t.strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"
}

new_repo() { # 3-rule AGENTS.md constitution
  local d; d="$(mktemp -d "$SANDBOX/repo-XXXXXX")"
  git -C "$d" init -q
  cat > "$d/AGENTS.md" <<'MD'
# Project

## Critical Rules

- **C0.1** Manifest versions must match. Bump all three when releasing.
- **C0.2** Every repo file must have a manifest entry.
- **C0.3** Never hardcode secrets.
MD
  printf '%s' "$d"
}

write_wf() { # $1 repo  $2 id  $3 status  $4 updated_at  $5 context_pack ("" = none)  [$6 owner_session, default s-1]
  local repo="$1" id="$2" status="$3" updated="$4" pack="$5" owner="${6:-s-1}" results='{}'
  mkdir -p "$repo/.mtk/workflows"
  [ -n "$pack" ] && results="{\"context_pack\": \"$pack\"}"
  printf '{"workflow_id": "%s", "status": "%s", "updated_at": "%s", "owner_session": "%s", "results": %s}\n' \
    "$id" "$status" "$updated" "$owner" "$results" > "$repo/.mtk/workflows/$id.json"
}

write_pack() { # $1 repo  $2 id -> creates .mtk/workflows/<id>/context-pack.md
  mkdir -p "$1/.mtk/workflows/$2"
  printf '# Context pack\n' > "$1/.mtk/workflows/$2/context-pack.md"
}

payload() { # $1 agent_type
  printf '{"hook_event_name":"SubagentStart","session_id":"s-1","transcript_path":"/x/t.jsonl","cwd":"/x","agent_id":"a-1","agent_type":"%s"}' "$1"
}

mtime_ago() { # $1 = days ago -> local [[CC]YY]MMDDhhmm for touch -t
  "$REAL_PY" -c 'import datetime,sys; t=datetime.datetime.now()-datetime.timedelta(days=float(sys.argv[1])); print(t.strftime("%Y%m%d%H%M"))' "$1"
}

# Runs the hook in repo $1 with payload $2; extra args are env assignments.
# Sets OUT (stdout), ERR (stderr), RC, PYCALLS (python3 calls the hook made).
# Here-string, not a pipe: the hook may exit before reading stdin.
ERRF="$SANDBOX/hook-stderr.txt"
run_hook() {
  local repo="$1" pl="$2"; shift 2
  rm -f "$PYLOG" "$ERRF"
  RC=0
  OUT="$(cd "$repo" && env CLAUDE_PROJECT_DIR="$repo" PATH="$SANDBOX/shim:$PATH" "$@" "${HOOK_BIN:-$HOOK}" <<<"$pl" 2>"$ERRF")" || RC=$?
  ERR=""
  [ -f "$ERRF" ] && ERR="$(cat "$ERRF")"
  PYCALLS=0
  [ -f "$PYLOG" ] && PYCALLS="$(awk 'END { print NR }' "$PYLOG")"
  return 0
}

# Decoded additionalContext of OUT ("" when OUT is empty or not the envelope).
ctx() {
  [ -n "$OUT" ] || { printf ''; return 0; }
  "$REAL_PY" -c '
import json, sys
d = json.loads(sys.stdin.read())
h = d["hookSpecificOutput"]
assert h["hookEventName"] == "SubagentStart", h
sys.stdout.write(h["additionalContext"])
' <<<"$OUT" 2>/dev/null || printf '__BAD_ENVELOPE__'
}

has()  { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# ============================ R1: who gets the block ===========================

# 1. mtk: agent, no workflow -> rules only.
R="$(new_repo)"
run_hook "$R" "$(payload mtk:compliance-reviewer)"
C="$(ctx)"
if [ "$RC" -eq 0 ] && has "Critical rules" "$C" && has $'\nC0.1 Manifest versions must match.\n' "$C" \
   && ! has "Context pack:" "$C" && has "reference only" "$C"; then
  pass "mtk: agent + no workflow -> rules only"
else
  fail "mtk: agent + no workflow -> rules only (rc=$RC, ctx=$C)"
fi
if ! has "Bump all three" "$C"; then
  pass "rule lines carry only the first sentence"
else
  fail "rule line kept text past the first sentence: $C"
fi
[ "$PYCALLS" -eq 0 ] && pass "mtk: agent + no workflow spawns no python" \
  || fail "mtk: agent + no workflow spawned python $PYCALLS time(s)"

# 2. general-purpose agent, active workflow with an existing pack -> pack + rules.
R="$(new_repo)"
write_pack "$R" wf-a
write_wf "$R" wf-a active "$(utc_ago 0.01)" ".mtk/workflows/wf-a/context-pack.md"
run_hook "$R" "$(payload general-purpose)"
C="$(ctx)"
if has "Context pack: .mtk/workflows/wf-a/context-pack.md ${PACK_SENTENCE}" "$C" && has "C0.2 " "$C"; then
  pass "general-purpose + active workflow with pack -> pack + rules"
else
  fail "general-purpose + active workflow with pack -> pack + rules (rc=$RC, out=$OUT)"
fi
# Positive control for the python shim: the pack lookup must go through it.
[ "$PYCALLS" -ge 1 ] && pass "python shim sees the hook's python call (control)" \
  || fail "python shim recorded no call on the pack path — the R2 proof below would be vacuous"

# 2b. Pack named by absolute path -> printed repo-relative.
R="$(new_repo)"
write_pack "$R" wf-abs
write_wf "$R" wf-abs active "$(utc_ago 0.01)" "$R/.mtk/workflows/wf-abs/context-pack.md"
run_hook "$R" "$(payload general-purpose)"
C="$(ctx)"
has "Context pack: .mtk/workflows/wf-abs/context-pack.md " "$C" \
  && pass "absolute context_pack is shown repo-relative" \
  || fail "absolute context_pack not shown repo-relative: $C"

# 2c. Newest active workflow wins; a newer non-active one is ignored.
R="$(new_repo)"
write_pack "$R" wf-old; write_pack "$R" wf-new; write_pack "$R" wf-done
write_wf "$R" wf-old active "$(utc_ago 2)" ".mtk/workflows/wf-old/context-pack.md"
write_wf "$R" wf-new active "$(utc_ago 1)" ".mtk/workflows/wf-new/context-pack.md"
write_wf "$R" wf-done complete "$(utc_ago 0.01)" ".mtk/workflows/wf-done/context-pack.md"
run_hook "$R" "$(payload general-purpose)"
C="$(ctx)"
has "wf-new/context-pack.md" "$C" && ! has "wf-old" "$C" && ! has "wf-done" "$C" \
  && pass "newest active workflow's pack is the one shown" \
  || fail "wrong workflow selected: $C"

# 2d. Another session's workflow is not this session's work: a newer one owned by
#     another session is skipped, and with only that one a general-purpose agent
#     gets nothing.
R="$(new_repo)"
write_pack "$R" wf-mine; write_pack "$R" wf-theirs
write_wf "$R" wf-mine active "$(utc_ago 2)" ".mtk/workflows/wf-mine/context-pack.md"
write_wf "$R" wf-theirs active "$(utc_ago 0.01)" ".mtk/workflows/wf-theirs/context-pack.md" s-other
run_hook "$R" "$(payload general-purpose)"
C="$(ctx)"
has "wf-mine/context-pack.md" "$C" && ! has "wf-theirs" "$C" \
  && pass "another session's newer workflow is skipped; this session's pack is shown" \
  || fail "another session's workflow leaked into the subagent block: $C"
rm -f "$R/.mtk/workflows/wf-mine.json"
run_hook "$R" "$(payload general-purpose)"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && pass "only another session's workflow -> general-purpose agent gets nothing" \
  || fail "only another session's workflow: expected silence (rc=$RC, out=$OUT)"

# ============================ R2: silence, no python ===========================

# 3. general-purpose, no workflow dir -> silent, no python.
R="$(new_repo)"
run_hook "$R" "$(payload general-purpose)"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && pass "general-purpose + no workflow -> silent" \
  || fail "general-purpose + no workflow -> silent (rc=$RC, out=$OUT)"
[ "$PYCALLS" -eq 0 ] && pass "general-purpose + no workflow spawns no python" \
  || fail "general-purpose + no workflow spawned python $PYCALLS time(s)"

# 3b. Workflow JSON present but last modified > 7 days ago -> gate closed, no python.
R="$(new_repo)"
write_wf "$R" wf-stale active "$(utc_ago 0.01)" ""
touch -t 202001010000 "$R/.mtk/workflows/wf-stale.json"
run_hook "$R" "$(payload Explore)"
[ -z "$OUT" ] && [ "$PYCALLS" -eq 0 ] && pass "workflow JSON older than 7 days (mtime) -> silent, no python" \
  || fail "stale-mtime workflow opened the gate (out=$OUT, python=$PYCALLS)"

# 3c. Stock-macOS shape: no timeout/gtimeout on PATH, so the payload is read with
#     the bash builtin. A restricted PATH holds only the tools the hook and the
#     digest use, plus the python shim.
RBIN="$SANDBOX/rbin"
mkdir -p "$RBIN"
for tool in bash env git find awk sed grep cat dirname basename mkdir rm date tr wc sort ls readlink pwd; do
  p="$(command -v "$tool" 2>/dev/null || true)"
  case "$p" in /*) ln -sf "$p" "$RBIN/$tool" ;; esac
done
ln -sf "$SANDBOX/shim/python3" "$RBIN/python3"
if [ -e "$RBIN/timeout" ] || [ -e "$RBIN/gtimeout" ]; then
  fail "restricted PATH unexpectedly contains a timeout binary"
fi
R="$(new_repo)"
run_hook "$R" "$(payload general-purpose)" PATH="$RBIN"
[ -z "$OUT" ] && [ "$PYCALLS" -eq 0 ] && pass "no timeout binary: general-purpose + no workflow -> silent, no python" \
  || fail "no timeout binary: general-purpose + no workflow (out=$OUT, python=$PYCALLS)"
run_hook "$R" "$(payload mtk:test-reviewer)" PATH="$RBIN"
C="$(ctx)"
has "C0.3 Never hardcode secrets." "$C" && [ "$PYCALLS" -eq 0 ] \
  && pass "no timeout binary: payload still read (mtk: agent -> rules), no python" \
  || fail "no timeout binary: mtk: agent got no rules or spawned python (python=$PYCALLS, out=$OUT)"

# 3d. Look-alike agent types are not `mtk:` agents: no workflow -> silent, no
#     python. (Case 1 is the positive control: a real `mtk:` agent in the same
#     kind of repo gets the rules block.)
R="$(new_repo)"
for at in mtk mtkx:foo my-mtk:foo MTK:foo; do
  run_hook "$R" "$(payload "$at")"
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$PYCALLS" -eq 0 ] \
    && pass "look-alike agent_type '$at' + no workflow -> silent, no python" \
    || fail "look-alike agent_type '$at' (rc=$RC, python=$PYCALLS, out=$OUT)"
done

# ============================ pack-line conditions =============================

# 4. Active workflow whose updated_at is 8 days old (file mtime fresh): the gate
#    opens and python runs, but the selection finds no active workflow, so a
#    non-mtk agent gets nothing at all.
R="$(new_repo)"
write_pack "$R" wf-8d
write_wf "$R" wf-8d active "$(utc_ago 8)" ".mtk/workflows/wf-8d/context-pack.md"
run_hook "$R" "$(payload general-purpose)"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$PYCALLS" -ge 1 ] \
  && pass "general-purpose + 8-day-old workflow -> silent (selector ran: python=$PYCALLS)" \
  || fail "general-purpose + 8-day-old workflow -> silent (rc=$RC, python=$PYCALLS, out=$OUT)"
# Same repo, mtk: agent -> rules still shown, no pack line.
run_hook "$R" "$(payload mtk:compliance-reviewer)"
C="$(ctx)"
! has "Context pack:" "$C" && has "C0.1 " "$C" \
  && pass "mtk: agent + 8-day-old workflow -> rules only, no pack line" \
  || fail "mtk: agent + 8-day-old workflow -> rules only (ctx=$C)"

# 4b. Recent workflow file whose status is not active -> non-mtk agent silent,
#     after the selector ran (python shim proves the gate opened).
R="$(new_repo)"
write_pack "$R" wf-fin
write_wf "$R" wf-fin complete "$(utc_ago 0.01)" ".mtk/workflows/wf-fin/context-pack.md"
run_hook "$R" "$(payload general-purpose)"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$PYCALLS" -ge 1 ] \
  && pass "general-purpose + recent non-active workflow -> silent (selector ran)" \
  || fail "general-purpose + recent non-active workflow -> silent (rc=$RC, python=$PYCALLS, out=$OUT)"
run_hook "$R" "$(payload mtk:test-reviewer)"
C="$(ctx)"
has "C0.2 " "$C" && ! has "Context pack:" "$C" \
  && pass "mtk: agent + recent non-active workflow -> rules, no pack line" \
  || fail "mtk: agent + recent non-active workflow (ctx=$C)"

# ============================ MTK_WORKFLOW_REINJECT_DAYS =======================

# 4c. Selector honours the knob: updated_at 8 days old, window widened to 10.
R="$(new_repo)"
write_pack "$R" wf-k10
write_wf "$R" wf-k10 active "$(utc_ago 8)" ".mtk/workflows/wf-k10/context-pack.md"
run_hook "$R" "$(payload general-purpose)" MTK_WORKFLOW_REINJECT_DAYS=10
C="$(ctx)"
has "Context pack: .mtk/workflows/wf-k10/context-pack.md " "$C" \
  && pass "MTK_WORKFLOW_REINJECT_DAYS=10 -> 8-day-old workflow selected" \
  || fail "MTK_WORKFLOW_REINJECT_DAYS=10 did not widen the selector (out=$OUT)"

# 4d. Selector honours the knob: updated_at 2 days old, window narrowed to 1.
R="$(new_repo)"
write_pack "$R" wf-k1
write_wf "$R" wf-k1 active "$(utc_ago 2)" ".mtk/workflows/wf-k1/context-pack.md"
run_hook "$R" "$(payload general-purpose)" MTK_WORKFLOW_REINJECT_DAYS=1
[ -z "$OUT" ] && [ "$PYCALLS" -ge 1 ] \
  && pass "MTK_WORKFLOW_REINJECT_DAYS=1 -> 2-day-old workflow not selected (silent)" \
  || fail "MTK_WORKFLOW_REINJECT_DAYS=1 did not narrow the selector (python=$PYCALLS, out=$OUT)"

# 4e. find prefilter honours the knob: file mtime 3 days old, updated_at fresh.
R="$(new_repo)"
write_pack "$R" wf-mt
write_wf "$R" wf-mt active "$(utc_ago 0.01)" ".mtk/workflows/wf-mt/context-pack.md"
touch -t "$(mtime_ago 3)" "$R/.mtk/workflows/wf-mt.json"
run_hook "$R" "$(payload general-purpose)" MTK_WORKFLOW_REINJECT_DAYS=2
[ -z "$OUT" ] && [ "$PYCALLS" -eq 0 ] \
  && pass "MTK_WORKFLOW_REINJECT_DAYS=2 + 3-day-old mtime -> prefilter closed, no python" \
  || fail "MTK_WORKFLOW_REINJECT_DAYS=2 prefilter (python=$PYCALLS, out=$OUT)"
run_hook "$R" "$(payload general-purpose)" MTK_WORKFLOW_REINJECT_DAYS=5
C="$(ctx)"
has "Context pack: .mtk/workflows/wf-mt/context-pack.md " "$C" && [ "$PYCALLS" -ge 1 ] \
  && pass "MTK_WORKFLOW_REINJECT_DAYS=5 + 3-day-old mtime -> prefilter open, pack shown (control)" \
  || fail "MTK_WORKFLOW_REINJECT_DAYS=5 prefilter (python=$PYCALLS, out=$OUT)"

# 4f. Non-numeric knob -> session-start parity: the raw value reaches float(),
#     which rejects it, so NO workflow is selected (no fallback to 7). The 7-day
#     prefilter still opens on the 3-day mtime, so the selector runs. No warning.
run_hook "$R" "$(payload general-purpose)" MTK_WORKFLOW_REINJECT_DAYS=abc
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$PYCALLS" -ge 1 ] && ! has "MTK_WORKFLOW_REINJECT_DAYS" "$ERR" \
  && pass "non-numeric MTK_WORKFLOW_REINJECT_DAYS -> no workflow selected, silent, no warning (selector ran)" \
  || fail "non-numeric MTK_WORKFLOW_REINJECT_DAYS (rc=$RC, python=$PYCALLS, err=$ERR, out=$OUT)"
run_hook "$R" "$(payload mtk:compliance-reviewer)" MTK_WORKFLOW_REINJECT_DAYS=abc
C="$(ctx)"
has "C0.1 " "$C" && ! has "Context pack:" "$C" \
  && pass "non-numeric MTK_WORKFLOW_REINJECT_DAYS + mtk: agent -> rules, no pack line" \
  || fail "non-numeric MTK_WORKFLOW_REINJECT_DAYS + mtk: agent (ctx=$C)"
# Control: the same repo with the default window shows the pack.
run_hook "$R" "$(payload general-purpose)"
C="$(ctx)"
has "Context pack: .mtk/workflows/wf-mt/context-pack.md " "$C" \
  && pass "same repo, default window -> pack shown (control for 4f)" \
  || fail "same repo, default window did not show the pack (out=$OUT)"

# 4g. Fractional knob is honoured by the selector: 0.5 days.
R="$(new_repo)"
write_pack "$R" wf-h1
write_wf "$R" wf-h1 active "$(utc_ago 0.25)" ".mtk/workflows/wf-h1/context-pack.md"
run_hook "$R" "$(payload general-purpose)" MTK_WORKFLOW_REINJECT_DAYS=0.5
C="$(ctx)"
has "Context pack: .mtk/workflows/wf-h1/context-pack.md " "$C" \
  && pass "MTK_WORKFLOW_REINJECT_DAYS=0.5 -> 6-hour-old workflow selected" \
  || fail "MTK_WORKFLOW_REINJECT_DAYS=0.5, 6h-old workflow (err=$ERR, out=$OUT)"
R="$(new_repo)"
write_pack "$R" wf-h2
write_wf "$R" wf-h2 active "$(utc_ago 0.75)" ".mtk/workflows/wf-h2/context-pack.md"
run_hook "$R" "$(payload general-purpose)" MTK_WORKFLOW_REINJECT_DAYS=0.5
[ -z "$OUT" ] && [ "$PYCALLS" -ge 1 ] \
  && pass "MTK_WORKFLOW_REINJECT_DAYS=0.5 -> 18-hour-old workflow not selected (selector ran)" \
  || fail "MTK_WORKFLOW_REINJECT_DAYS=0.5, 18h-old workflow (python=$PYCALLS, out=$OUT)"

# 4h. Fractional prefilter is ceil(days): 1.5 -> 2 days of mtime.
R="$(new_repo)"
write_pack "$R" wf-c
write_wf "$R" wf-c active "$(utc_ago 0.01)" ".mtk/workflows/wf-c/context-pack.md"
touch -t "$(mtime_ago 1.8)" "$R/.mtk/workflows/wf-c.json"
run_hook "$R" "$(payload general-purpose)" MTK_WORKFLOW_REINJECT_DAYS=1.5
C="$(ctx)"
has "Context pack: .mtk/workflows/wf-c/context-pack.md " "$C" \
  && pass "MTK_WORKFLOW_REINJECT_DAYS=1.5 + 1.8-day-old mtime -> prefilter (ceil 2) open" \
  || fail "MTK_WORKFLOW_REINJECT_DAYS=1.5 prefilter ceil (python=$PYCALLS, out=$OUT)"
touch -t "$(mtime_ago 2.5)" "$R/.mtk/workflows/wf-c.json"
run_hook "$R" "$(payload general-purpose)" MTK_WORKFLOW_REINJECT_DAYS=1.5
[ -z "$OUT" ] && [ "$PYCALLS" -eq 0 ] \
  && pass "MTK_WORKFLOW_REINJECT_DAYS=1.5 + 2.5-day-old mtime -> prefilter closed, no python" \
  || fail "MTK_WORKFLOW_REINJECT_DAYS=1.5 prefilter upper bound (python=$PYCALLS, out=$OUT)"

# 4i. Leading zeros are decimal, never octal, in both the prefilter and the
#     selector. `08` (invalid octal): 7.5-day-old mtime and updated_at selected.
R="$(new_repo)"
write_pack "$R" wf-08
write_wf "$R" wf-08 active "$(utc_ago 7.5)" ".mtk/workflows/wf-08/context-pack.md"
touch -t "$(mtime_ago 7.5)" "$R/.mtk/workflows/wf-08.json"
run_hook "$R" "$(payload general-purpose)" MTK_WORKFLOW_REINJECT_DAYS=08
C="$(ctx)"
[ "$RC" -eq 0 ] && has "Context pack: .mtk/workflows/wf-08/context-pack.md " "$C" \
  && pass "MTK_WORKFLOW_REINJECT_DAYS=08 -> 8-day window (7.5-day-old workflow selected)" \
  || fail "MTK_WORKFLOW_REINJECT_DAYS=08 (rc=$RC, err=$ERR, out=$OUT)"
run_hook "$R" "$(payload general-purpose)"
[ -z "$OUT" ] && pass "same repo, default 7-day window -> 7.5-day-old workflow not shown (control)" \
  || fail "default window showed the 7.5-day-old workflow (out=$OUT)"
# `010` is 10, not octal 8: a 9-day-old mtime and updated_at are inside it.
R="$(new_repo)"
write_pack "$R" wf-010
write_wf "$R" wf-010 active "$(utc_ago 9)" ".mtk/workflows/wf-010/context-pack.md"
touch -t "$(mtime_ago 9)" "$R/.mtk/workflows/wf-010.json"
run_hook "$R" "$(payload general-purpose)" MTK_WORKFLOW_REINJECT_DAYS=010
C="$(ctx)"
[ "$RC" -eq 0 ] && has "Context pack: .mtk/workflows/wf-010/context-pack.md " "$C" \
  && pass "MTK_WORKFLOW_REINJECT_DAYS=010 -> 10-day window, not octal 8 (9-day-old workflow selected)" \
  || fail "MTK_WORKFLOW_REINJECT_DAYS=010 (rc=$RC, err=$ERR, out=$OUT)"

# 5. Active workflow whose context_pack names a missing file -> no pack line.
R="$(new_repo)"
write_wf "$R" wf-miss active "$(utc_ago 0.01)" ".mtk/workflows/wf-miss/context-pack.md"
run_hook "$R" "$(payload general-purpose)"
C="$(ctx)"
! has "Context pack:" "$C" && pass "pack path missing -> no pack line" \
  || fail "pack path missing -> no pack line (ctx=$C)"

# 5b. Active workflow without results.context_pack -> no pack line.
R="$(new_repo)"
write_wf "$R" wf-nopack active "$(utc_ago 0.01)" ""
run_hook "$R" "$(payload general-purpose)"
C="$(ctx)"
! has "Context pack:" "$C" && pass "no results.context_pack -> no pack line" \
  || fail "no results.context_pack -> no pack line (ctx=$C)"

# ============================ R3: size cap =====================================

# 6. 60-rule constitution -> <= 4,000 bytes, ends with the omitted-rule marker.
#    Rule lines are a fixed 73 bytes (zero-padded ids), so a cap that cuts at the
#    last rule that fits leaves the block above 3,900 bytes; a cap that drops
#    rules early (over-reserving) falls below it.
R="$(new_repo)"
{
  printf '# Project\n\n## Critical Rules\n\n'
  for i in $(seq 1 60); do
    printf -- '- **R%02d.1** Rule %02d needs a written justification, a named owner and a review.\n' "$i" "$i"
  done
} > "$R/AGENTS.md"
run_hook "$R" "$(payload mtk:implementer)"
C="$(ctx)"
BYTES="$(LC_ALL=C; printf '%s' "${#C}")"
MARK="$(awk 'END { print }' <<<"$C")"
KEPT="$(grep -cE '^R[0-9]+\.1 ' <<<"$C" || true)"
OMITTED="$(sed -nE 's/^\[\+([0-9]+) more rules in the constitution\]$/\1/p' <<<"$MARK")"
if [ "$BYTES" -gt 3900 ] && [ "$BYTES" -le 4000 ] && [ -n "$OMITTED" ] && [ "$OMITTED" -gt 0 ] && [ $((KEPT + OMITTED)) -eq 60 ]; then
  pass "60-rule constitution -> ${BYTES} bytes, ${KEPT} kept, ends with [+${OMITTED} more rules in the constitution]"
else
  fail "60-rule constitution: bytes=$BYTES kept=$KEPT last-line='$MARK'"
fi
# Every kept rule line is whole (cut at a rule boundary, not mid-line).
PARTIAL="$(grep -E '^R[0-9]+\.1 ' <<<"$C" | grep -cvE 'needs a written justification, a named owner and a review\.$' || true)"
[ "$PARTIAL" -eq 0 ] && pass "truncation lands on a rule boundary" \
  || fail "truncation cut $PARTIAL rule line(s) mid-line"

# 6b. Exact-boundary fixtures. The constitution is FILL_N fixed rules plus one
#     last pad rule `Z9.1 <pad>.`; a probe run measures the block, then the pad
#     is resized so the FULL block is exactly 4,000 bytes (kept whole) or 4,001
#     bytes (truncated). The hook runs under a UTF-8 locale so that a char count
#     and a byte count differ for multi-byte text.
UTF8_LOC=""
for loc in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8; do
  if [ "$(LC_ALL="$loc" bash -c 'x="ć"; printf "%s" "${#x}"' 2>/dev/null)" = "1" ]; then
    UTF8_LOC="$loc"
    break
  fi
done
[ -n "$UTF8_LOC" ] || fail "no UTF-8 locale found; the multi-byte cap cases below would be vacuous"
FILL_N=37
bytes_of() { local LC_ALL=C; printf '%s' "${#1}"; }
pad_of() { # $1 = length -> that many 'a'
  local s=""
  while [ "${#s}" -lt "$1" ]; do s="${s}a"; done
  printf '%s' "$s"
}
cap_repo() { # $1 = pad text -> repo path
  local d i; d="$(new_repo)"
  {
    printf '# Project\n\n## Critical Rules\n\n'
    for i in $(seq 1 "$FILL_N"); do
      printf -- '- **F%d.1** Fill rule %d keeps this constitution long enough to sit just under the subagent block cap.\n' "$i" "$i"
    done
    printf -- '- **Z9.1** %s.\n' "$1"
  } > "$d/AGENTS.md"
  printf '%s' "$d"
}
PAD0=60
R="$(cap_repo "$(pad_of "$PAD0")")"
run_hook "$R" "$(payload mtk:implementer)" LC_ALL="$UTF8_LOC"
C="$(ctx)"
B0="$(bytes_of "$C")"
PAD4000=$((PAD0 + 4000 - B0))
if [ "$PAD4000" -lt 2 ] || [ "$PAD4000" -gt 180 ] || has "more rules in the constitution]" "$C"; then
  fail "cap calibration out of range (probe bytes=$B0, pad=$PAD4000) — adjust FILL_N"
  PAD4000=60
fi

# exactly 4,000 bytes -> whole, no marker
R="$(cap_repo "$(pad_of "$PAD4000")")"
run_hook "$R" "$(payload mtk:implementer)" LC_ALL="$UTF8_LOC"
C="$(ctx)"
BYTES="$(bytes_of "$C")"
[ "$BYTES" -eq 4000 ] && has $'\nZ9.1 a' "$C" && ! has "more rules in the constitution]" "$C" \
  && pass "full block of exactly 4,000 bytes -> kept whole, no marker" \
  || fail "4,000-byte block: bytes=$BYTES last-line='$(awk 'END { print }' <<<"$C")'"

# exactly 4,001 bytes -> truncated, the pad rule dropped, [+1 more ...]
R="$(cap_repo "$(pad_of $((PAD4000 + 1)))")"
run_hook "$R" "$(payload mtk:implementer)" LC_ALL="$UTF8_LOC"
C="$(ctx)"
BYTES="$(bytes_of "$C")"
MARK="$(awk 'END { print }' <<<"$C")"
[ "$BYTES" -le 4000 ] && [ "$MARK" = "[+1 more rules in the constitution]" ] && ! has "Z9.1" "$C" \
  && pass "full block of 4,001 bytes -> truncated (${BYTES} bytes, ends with $MARK)" \
  || fail "4,001-byte block: bytes=$BYTES last-line='$MARK'"

# 6c. Multi-byte: one 'a' of the 4,000-byte pad becomes 'ć' (2 bytes) -> the
#     block is 4,000 chars but 4,001 bytes, so a byte-conservative cap truncates.
R="$(cap_repo "ć$(pad_of $((PAD4000 - 1)))")"
run_hook "$R" "$(payload mtk:implementer)" LC_ALL="$UTF8_LOC"
C="$(ctx)"
BYTES="$(bytes_of "$C")"
MARK="$(awk 'END { print }' <<<"$C")"
[ "$MARK" = "[+1 more rules in the constitution]" ] && ! has "Z9.1" "$C" && [ "$BYTES" -le 4000 ] \
  && pass "multi-byte rule: 4,000 chars / 4,001 bytes -> truncated (bytes counted, not chars)" \
  || fail "multi-byte rule near the cap: bytes=$BYTES last-line='$MARK'"
# Control: the same 'ć' in a 3,999-char pad -> exactly 4,000 bytes -> kept whole.
R="$(cap_repo "ć$(pad_of $((PAD4000 - 2)))")"
run_hook "$R" "$(payload mtk:implementer)" LC_ALL="$UTF8_LOC"
C="$(ctx)"
BYTES="$(bytes_of "$C")"
[ "$BYTES" -eq 4000 ] && has $'\nZ9.1 ć' "$C" && ! has "more rules in the constitution]" "$C" \
  && pass "multi-byte rule at exactly 4,000 bytes -> kept whole (control)" \
  || fail "multi-byte 4,000-byte control: bytes=$BYTES"

# ============================ fail-open paths ==================================

# 7. Digest script absent -> pack line only. The hook runs from a copy of
#    hooks/ with no sibling scripts/ and no CLAUDE_PLUGIN_ROOT.
PLUG="$SANDBOX/plugin-no-scripts"
mkdir -p "$PLUG/hooks"
cp -R "$REPO_ROOT/hooks/lib" "$PLUG/hooks/lib"
cp "$HOOK" "$PLUG/hooks/subagent-context.sh"
R="$(new_repo)"
write_pack "$R" wf-p
write_wf "$R" wf-p active "$(utc_ago 0.01)" ".mtk/workflows/wf-p/context-pack.md"
HOOK_BIN="$PLUG/hooks/subagent-context.sh" run_hook "$R" "$(payload general-purpose)"
C="$(ctx)"
[ "$RC" -eq 0 ] && has "Context pack: .mtk/workflows/wf-p/context-pack.md" "$C" && ! has "Critical rules" "$C" \
  && pass "digest script absent -> pack line only" \
  || fail "digest script absent -> pack line only (rc=$RC, ctx=$C)"

# 7b. Digest absent and no pack -> nothing to say -> silent.
R="$(new_repo)"
HOOK_BIN="$PLUG/hooks/subagent-context.sh" run_hook "$R" "$(payload mtk:compliance-reviewer)"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && pass "digest absent + no pack -> silent" \
  || fail "digest absent + no pack -> silent (rc=$RC, out=$OUT)"

# 7c. Digest resolved through CLAUDE_PLUGIN_ROOT when no sibling scripts/.
R="$(new_repo)"
HOOK_BIN="$PLUG/hooks/subagent-context.sh" run_hook "$R" "$(payload mtk:compliance-reviewer)" CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
C="$(ctx)"
has "C0.1 " "$C" && pass "digest resolved via CLAUDE_PLUGIN_ROOT fallback" \
  || fail "digest not resolved via CLAUDE_PLUGIN_ROOT (out=$OUT)"

# 8. Kill-switch.
R="$(new_repo)"
write_pack "$R" wf-k
write_wf "$R" wf-k active "$(utc_ago 0.01)" ".mtk/workflows/wf-k/context-pack.md"
run_hook "$R" "$(payload mtk:compliance-reviewer)" MTK_SUBAGENT_CONTEXT=0
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$PYCALLS" -eq 0 ] && pass "MTK_SUBAGENT_CONTEXT=0 -> silent" \
  || fail "MTK_SUBAGENT_CONTEXT=0 -> silent (rc=$RC, out=$OUT)"

# 9. Garbage and empty payloads -> exit 0, no output.
R="$(new_repo)"
run_hook "$R" 'not json {{{ "agent_type": '
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && pass "garbage payload -> exit 0, silent" \
  || fail "garbage payload (rc=$RC, out=$OUT)"
run_hook "$R" ''
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && pass "empty payload -> exit 0, silent" \
  || fail "empty payload (rc=$RC, out=$OUT)"

# 9b. Corrupt workflow JSON with a fresh mtime -> gate opens, python skips it,
#     no active workflow -> a non-mtk agent gets nothing; exit 0.
R="$(new_repo)"
mkdir -p "$R/.mtk/workflows"
printf '{ broken' > "$R/.mtk/workflows/wf-bad.json"
run_hook "$R" "$(payload general-purpose)"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$PYCALLS" -ge 1 ] \
  && pass "corrupt workflow JSON -> exit 0, silent for a non-mtk agent" \
  || fail "corrupt workflow JSON (rc=$RC, python=$PYCALLS, out=$OUT)"
run_hook "$R" "$(payload mtk:compliance-reviewer)"
C="$(ctx)"
[ "$RC" -eq 0 ] && has "C0.1 " "$C" && ! has "Context pack:" "$C" \
  && pass "corrupt workflow JSON -> mtk: agent still gets rules, no pack line" \
  || fail "corrupt workflow JSON, mtk: agent (rc=$RC, out=$OUT)"

# ============================ payload fixture ==================================

# 10. The fixture carries every field the hook reads, and drives the hook.
if "$REAL_PY" - "$FIXTURE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
need = ["hook_event_name", "agent_id", "agent_type", "session_id", "transcript_path", "cwd"]
missing = [k for k in need if k not in d]
assert not missing, missing
assert d["hook_event_name"] == "SubagentStart", d["hook_event_name"]
assert d["agent_type"].startswith("mtk:"), d["agent_type"]
PY
then
  pass "fixture has the documented SubagentStart fields (agent_type read by the hook)"
else
  fail "fixture is missing SubagentStart fields"
fi
R="$(new_repo)"
run_hook "$R" "$(cat "$FIXTURE")"
C="$(ctx)"
has "C0.1 " "$C" && pass "fixture payload -> rules block" \
  || fail "fixture payload produced no rules block (out=$OUT)"

if [ "$fails" -ne 0 ]; then
  printf '\n%s assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf '\nsubagent-context: all assertions passed\n'
