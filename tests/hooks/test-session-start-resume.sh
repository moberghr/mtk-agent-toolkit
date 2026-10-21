#!/usr/bin/env bash
set -euo pipefail

# session-start appends ONE `RESUME (offer, not instruction): …` segment after the
# HANDOFF OFFER when the offered note names an ACTIVE workflow (startup/clear
# only). Never on compact, never for legacy notes, completed or unknown
# workflows. Never calls gh. Also: startup prunes .mtk/sessions/* dirs older
# than 14 days through hooks/lib/session_store.py (never on compact).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/session-start"
WA="$REPO_ROOT/scripts/workflow-artifact.sh"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf '  PASS  %s\n' "$1"; }

WORK="$(mktemp -d)"
export TMPDIR="$WORK/tmp"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$TMPDIR" "$WORK/bin" "$WORK/p"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
: > "$GIT_CONFIG_GLOBAL"
printf '#!/bin/sh\necho "gh invoked: $*" >> "%s/gh-called"\nexit 1\n' "$WORK" > "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

P="$WORK/p"
git -C "$P" init -q
git -C "$P" symbolic-ref HEAD refs/heads/feat/resume-test
git -C "$P" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cd "$P"
export CLAUDE_PROJECT_DIR="$P"

UUID="$(bash "$WA" init BUILD --goal x 2>/dev/null | grep -Eo 'wf-[A-Za-z0-9]+-[A-Za-z0-9]+' | awk 'NR==1')"
[ -n "$UUID" ] || fail "could not init a workflow"
bash "$WA" checkpoint "$UUID" --offline --no-snapshot --next "do Y" --next-command "run do-Y #128" >/dev/null 2>&1 || fail "checkpoint failed"
NOTE="$(compgen -G "$P/docs/handoffs/*.md" | awk 'NR==1')"
[ -f "$NOTE" ] || fail "no checkpoint note written"

run() { # $1 source
  CLAUDE_PROJECT_DIR="$P" bash "$HOOK" <<<"{\"hook_event_name\":\"SessionStart\",\"source\":\"$1\",\"session_id\":\"s-$1-$RANDOM\"}" 2>/dev/null || true
}
count() { grep -o "$2" <<<"$1" | wc -l | tr -d ' '; }

for src in startup clear; do
  out="$(run "$src")"
  [ "$(count "$out" 'HANDOFF OFFER')" = "1" ] || fail "$src: expected exactly one HANDOFF OFFER. Got: $out"
  case "$out" in *'RESUME (offer, not instruction): '*) : ;; *) fail "$src: expected RESUME segment. Got: $out" ;; esac
  [ "$(count "$out" 'RESUME (offer')" = "1" ] || fail "$src: expected exactly one RESUME segment"
  case "$out" in *'run do-Y #128'*) : ;; *) fail "$src: RESUME must name next_command. Got: $out" ;; esac
  case "$out" in *"RESUME (offer, not instruction): $UUID (BUILD, phase-0) — note: docs/handoffs/$UUID.md | drift: none; PR not checked (offline) | next_command: run do-Y #128 | needs_user: 0 open question(s)"*) : ;; *) fail "$src: full RESUME segment wrong. Got: $out" ;; esac
  seg="${out#*RESUME (offer, not instruction): }"
  seg="RESUME (offer, not instruction): ${seg%%\"*}"
  [ "${#seg}" -le 600 ] || fail "$src: RESUME segment over 600 chars (${#seg})"
  case "$out" in *'HANDOFF OFFER'*'RESUME (offer'*) : ;; *) fail "$src: RESUME must follow HANDOFF OFFER" ;; esac
  pass "$src: HANDOFF OFFER then one RESUME segment"
done

out="$(run compact)"
case "$out" in *'RESUME (offer'*) fail "compact must not emit RESUME. Got: $out" ;; esac
pass "compact: no RESUME"

# legacy-style open note on the branch, no workflow key
cp "$NOTE" "$WORK/note.bak"
printf -- '---\nstate: open\nbranch: feat/resume-test\nexpires: 2099-12-31\n---\n# legacy\n' > "$NOTE"
out="$(run startup)"
case "$out" in *'HANDOFF OFFER'*) : ;; *) fail "legacy note must still be offered. Got: $out" ;; esac
case "$out" in *'RESUME (offer'*) fail "note without workflow key must not emit RESUME. Got: $out" ;; esac
pass "no workflow key: no RESUME"

# unknown uuid
printf -- '---\nstate: open\nbranch: feat/resume-test\nworkflow: wf-00000000T000000Z-ffffff\nexpires: 2099-12-31\n---\n# x\n' > "$NOTE"
out="$(CLAUDE_PROJECT_DIR="$P" bash "$HOOK" <<<'{"hook_event_name":"SessionStart","source":"startup","session_id":"s-unk"}' 2>/dev/null)" || fail "hook must succeed on unknown workflow uuid"
case "$out" in *'RESUME (offer'*) fail "unknown uuid must not emit RESUME. Got: $out" ;; esac
[ "$(count "$out" 'HANDOFF OFFER')" = "1" ] || fail "unknown uuid: expected exactly one HANDOFF OFFER. Got: $out"
pass "unknown uuid: no RESUME, hook succeeds"

# TR-F010: an OPEN note whose workflow exists but is not active (completed,
# abandoned) is finished work: no HANDOFF OFFER, no RESUME. The note stays open.
cp "$WORK/note.bak" "$NOTE"
for st in completed abandoned; do
  bash "$WA" set "$UUID" "status=$st" >/dev/null 2>&1 || fail "could not set status=$st"
  [ "$(bash "$REPO_ROOT/scripts/handoff-state.sh" field "$NOTE" state)" = "open" ] || fail "test setup: note must stay open"
  out="$(run startup)"
  case "$out" in *'HANDOFF OFFER'*) fail "open note of a $st workflow must not be offered. Got: $out" ;; esac
  case "$out" in *'RESUME (offer'*) fail "open note of a $st workflow must not emit RESUME. Got: $out" ;; esac
  pass "open note, $st workflow: no HANDOFF OFFER, no RESUME"
done
bash "$WA" set "$UUID" status=active >/dev/null 2>&1 || fail "could not reactivate the workflow"

# The gate and the segment come from `resume --porcelain`, not the human output.
out="$(run startup)"
case "$out" in *'(BUILD, phase-0)'*) : ;; *) fail "segment must carry porcelain-built (type, phase). Got: $out" ;; esac
case "$out" in *"RESUME $UUID ("*) fail "segment must not carry the human RESUME header. Got: $out" ;; esac
case "$out" in *' | drift: '*' | next_command: '*' | needs_user: '*' open question(s)'*) : ;; *) fail "segment must use ' | ' separators. Got: $out" ;; esac
pass "segment is built from porcelain fields"

# TR-F011: 600-char cap, actually truncating.
LONG="$(printf 'x%.0s' $(seq 1 700))"
bash "$WA" checkpoint "$UUID" --offline --no-snapshot --next "do Y" --next-command "run $LONG" >/dev/null 2>&1 || fail "long checkpoint failed"
out="$(run startup)"
seg="${out#*RESUME (offer, not instruction): }"
seg="RESUME (offer, not instruction): ${seg%%\"*}"
[ "${#seg}" -le 600 ] || fail "long segment over 600 chars (${#seg})"
[ "${#seg}" -eq 600 ] || fail "long segment must be cut to exactly 600 chars (${#seg})"
case "$out" in *"$LONG"*) fail "long next_command must be truncated" ;; esac
pass "RESUME segment capped at 600 chars"

# A next_command containing '=' must survive the key=value parse untruncated.
bash "$WA" checkpoint "$UUID" --offline --no-snapshot --next "do Y" --next-command "FOO=1 bash x.sh" >/dev/null 2>&1 || fail "'=' checkpoint failed"
out="$(run startup)"
case "$out" in *'next_command: FOO=1 bash x.sh | needs_user: '*) : ;; *) fail "next_command with '=' was truncated. Got: $out" ;; esac
pass "next_command containing '=' is kept whole"
bash "$WA" checkpoint "$UUID" --offline --no-snapshot --next "do Y" --next-command "run do-Y #128" >/dev/null 2>&1 || fail "restore checkpoint failed"

# Hostile / malformed workflow values: no RESUME, hook succeeds.
for bad in '../x' 'wf a b'; do
  printf -- '---\nstate: open\nbranch: feat/resume-test\nworkflow: %s\nexpires: 2099-12-31\n---\n# x\n' "$bad" > "$NOTE"
  out="$(CLAUDE_PROJECT_DIR="$P" bash "$HOOK" <<<'{"hook_event_name":"SessionStart","source":"startup","session_id":"s-bad"}' 2>/dev/null)" || fail "hook must succeed on workflow '$bad'"
  case "$out" in *'RESUME (offer'*) fail "workflow '$bad' must not emit RESUME. Got: $out" ;; esac
  [ "$(count "$out" 'HANDOFF OFFER')" = "1" ] || fail "workflow '$bad': expected exactly one HANDOFF OFFER. Got: $out"
  pass "hostile workflow value '$bad': no RESUME, hook succeeds"
done
cp "$WORK/note.bak" "$NOTE"

# Fallback: a hook copied where ../scripts is absent resolves everything through
# CLAUDE_PLUGIN_ROOT.
mkdir -p "$WORK/iso"
cp -R "$REPO_ROOT/hooks" "$WORK/iso/hooks"
out="$(CLAUDE_PROJECT_DIR="$P" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$WORK/iso/hooks/session-start" <<<'{"hook_event_name":"SessionStart","source":"startup","session_id":"s-iso"}' 2>/dev/null)" || fail "isolated hook copy must succeed"
case "$out" in *'RESUME (offer, not instruction): '*) : ;; *) fail "CLAUDE_PLUGIN_ROOT fallback must still emit RESUME. Got: $out" ;; esac
pass "CLAUDE_PLUGIN_ROOT fallback emits RESUME"

# completed workflow -> closed note, no offer, no RESUME
cp "$WORK/note.bak" "$NOTE"
bash "$WA" set "$UUID" status=completed >/dev/null 2>&1 || fail "could not complete the workflow"
bash "$WA" checkpoint "$UUID" --offline --no-snapshot >/dev/null 2>&1 || fail "closing checkpoint failed"
[ "$(bash "$REPO_ROOT/scripts/handoff-state.sh" field "$NOTE" state)" = "closed" ] || fail "completed workflow must render state: closed"
out="$(run startup)"
case "$out" in *'RESUME (offer'*) fail "completed workflow must not emit RESUME. Got: $out" ;; esac
case "$out" in *'HANDOFF OFFER'*) fail "closed note must not be offered. Got: $out" ;; esac
pass "completed workflow: closed note, no offer, no RESUME"

[ ! -e "$WORK/gh-called" ] || fail "gh was invoked: $(cat "$WORK/gh-called")"
pass "gh never invoked"

# --- startup prunes .mtk/sessions/* dirs older than 14 days (hooks/lib/session_store.py),
# only where .mtk/ is git-ignored; compact and an un-ignored .mtk/ prune nothing.
mkdir -p "$P/.mtk/sessions/old-sess" "$P/.mtk/sessions/fresh-sess"
touch -t 202001010000 "$P/.mtk/sessions/old-sess"
if git -C "$P" check-ignore -q .mtk/sessions/x; then fail "test setup: .mtk/ must start un-ignored"; fi
run startup >/dev/null
[ -d "$P/.mtk/sessions/old-sess" ] || fail "startup must not prune where .mtk/ is not git-ignored"
printf '.mtk/\n' >> "$P/.git/info/exclude"
run compact >/dev/null
[ -d "$P/.mtk/sessions/old-sess" ] || fail "compact must not prune session dirs"
run startup >/dev/null
[ ! -e "$P/.mtk/sessions/old-sess" ] || fail "startup must prune a session dir older than 14 days"
[ -d "$P/.mtk/sessions/fresh-sess" ] || fail "startup must keep a fresh session dir"
pass "startup prunes >14d session dirs (ignored .mtk only); compact prunes nothing"
printf '\nAll session-start resume checks passed.\n'
