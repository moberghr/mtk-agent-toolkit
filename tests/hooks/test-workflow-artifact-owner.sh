#!/usr/bin/env bash
set -euo pipefail

# workflow-artifact.sh stamps owner_session — the Claude Code session that last
# changed a workflow (CLAUDE_CODE_SESSION_ID) — so the per-session hooks
# (context-guard, subagent-context, session-start's compact re-inject,
# compact-archive) act only on their own session's workflow. A 2026-10-22 field
# run had a disk-scan session told to "checkpoint wf-X" because another session
# in the same worktree had wf-X active. Mutating subcommands claim; read-only
# ones (read, list, resume, trap list) never do, so an offer never claims.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WFA="$REPO_ROOT/scripts/workflow-artifact.sh"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available" >&2; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$WORK/gitconfig"
: > "$GIT_CONFIG_GLOBAL"
P="$WORK/proj"; mkdir -p "$P"; git -C "$P" init -q; printf '.mtk/\n' > "$P/.gitignore"

fails=0
check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — expected [$2] got [$3]"; fails=$((fails + 1)); fi
}
# wfa <session or -> <args...> — run the CLI in the project as that session ("-" = no session).
wfa() {
  local sid="$1"; shift
  if [ "$sid" = "-" ]; then
    (cd "$P" && env -u CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR="$P" bash "$WFA" "$@")
  else
    (cd "$P" && env CLAUDE_CODE_SESSION_ID="$sid" CLAUDE_PROJECT_DIR="$P" bash "$WFA" "$@")
  fi
}
owner() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("owner_session", "<none>"))' "$P/.mtk/workflows/$1.json"; }

U="$(wfa sess-A init TASK --goal "owner test")"
check "init stamps the calling session" "sess-A" "$(owner "$U")"

wfa sess-B event "$U" note --data '{}' >/dev/null
check "event claims for the calling session" "sess-B" "$(owner "$U")"

wfa sess-C read "$U" >/dev/null
wfa sess-C list >/dev/null
wfa sess-C resume "$U" --offline >/dev/null 2>&1 || true
wfa sess-C trap list "$U" >/dev/null 2>&1 || true
check "read / list / resume / trap list never claim" "sess-B" "$(owner "$U")"

wfa sess-D set "$U" note=x >/dev/null
check "set claims" "sess-D" "$(owner "$U")"
wfa sess-E batch "$U" event x -- set k=v >/dev/null
check "batch claims" "sess-E" "$(owner "$U")"
wfa sess-F trap add "$U" --title "t1" >/dev/null
check "trap add claims" "sess-F" "$(owner "$U")"
wfa sess-G checkpoint "$U" --next "go" --offline --no-snapshot >/dev/null
check "checkpoint claims" "sess-G" "$(owner "$U")"

# Each remaining progress subcommand claims on its own (batch re-enters main per op,
# so these are checked as top-level calls).
wfa sess-K gate "$U" plan_trust_gate pass >/dev/null
check "gate claims" "sess-K" "$(owner "$U")"
wfa sess-L criteria "$U" SC1=verified >/dev/null
check "criteria claims" "sess-L" "$(owner "$U")"
wfa sess-M remediation "$U" lint --score 1 >/dev/null
check "remediation claims" "sess-M" "$(owner "$U")"
wfa sess-N review-input "$U" --record >/dev/null 2>&1 || true
check "review-input claims" "sess-N" "$(owner "$U")"

wfa sess-H checkpoint "$U" --no-such-flag >/dev/null 2>&1 || true
check "a rejected progress call still claims (that session is acting on it)" "sess-H" "$(owner "$U")"

wfa - set "$U" note=y >/dev/null
check "no session id: owner kept" "sess-H" "$(owner "$U")"
wfa 'bad id"x' set "$U" note=z >/dev/null
check "unsafe session id: owner kept" "sess-H" "$(owner "$U")"

U3="$(wfa sess-I init TASK)"
wfa sess-J abandon "$U3" --reason done >/dev/null
check "abandon ends a workflow without claiming it" "sess-I" "$(owner "$U3")"

# End to end: the stamp is exactly what the hooks' selector matches on.
SEL="$REPO_ROOT/hooks/lib/active_workflow.py"
U4="$(wfa sess-E2E init TASK)"
check "selector finds the stamping session's workflow" "$P/.mtk/workflows/$U4.json" \
  "$(python3 "$SEL" --session sess-E2E "$P/.mtk/workflows" 7 path 2>/dev/null)"
check "selector hides it from another session" "" \
  "$(python3 "$SEL" --session sess-other "$P/.mtk/workflows" 7 path 2>/dev/null)"

# A corrupt artifact: the claim reports one line first (the subcommand that follows
# then fails on the same file in its own way).
U5="$(wfa sess-X init TASK)"
printf 'not json{' > "$P/.mtk/workflows/$U5.json"
err="$(wfa sess-Y set "$U5" k=v 2>&1 >/dev/null || true)"
case "${err%%$'\n'*}" in "workflow-artifact: could not record owner_session on $U5: "*) : ;;
  *) echo "FAIL: corrupt artifact: the claim must report one line first. Got: $err"; fails=$((fails + 1)) ;; esac

U2="$(wfa - init TASK)"
check "init outside Claude Code: no owner" "<none>" "$(owner "$U2")"

if [ "$fails" -ne 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "All workflow-artifact owner checks passed"
