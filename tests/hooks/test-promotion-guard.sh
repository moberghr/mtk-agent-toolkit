#!/usr/bin/env bash
set -euo pipefail

# mtk_is_redundant_plugin_invocation (hooks/lib/hook-io.sh): a plugin-install
# copy of a hook (living outside the current project) must skip when the project
# itself wires a hook of the same basename in .claude/settings.json — otherwise
# the hook fires twice. A project-local copy, or a project that does not wire the
# basename, must always run.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK_IO="$REPO_ROOT/hooks/lib/hook-io.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

PROJECT="$(mktemp -d)"
PLUGIN="$(mktemp -d)"
cleanup() { rm -rf "$PROJECT" "$PLUGIN"; }
trap cleanup EXIT

git -C "$PROJECT" init -q
mkdir -p "$PROJECT/.claude" "$PROJECT/hooks" "$PLUGIN/hooks"
cat > "$PROJECT/.claude/settings.json" <<'JSON'
{ "hooks": { "PostToolUse": [ { "hooks": [
  { "type": "command", "command": "$CLAUDE_PROJECT_DIR/hooks/context-budget.sh" }
] } ] } }
JSON
: > "$PROJECT/hooks/context-budget.sh"
: > "$PLUGIN/hooks/context-budget.sh"

# Helper: run the guard from inside PROJECT for a given hook path; echo skip/run.
verdict() {
  ( cd "$PROJECT" && bash -c '
    source "'"$HOOK_IO"'"
    if mtk_is_redundant_plugin_invocation "'"$1"'"; then echo skip; else echo run; fi
  ' )
}

# --- Case 1: plugin copy + project wires same basename → skip ---------------
[ "$(verdict "$PLUGIN/hooks/context-budget.sh")" = "skip" ] \
  || fail "plugin copy of a project-wired hook should skip"
printf '  PASS  plugin copy skips when project wires the same basename\n'

# --- Case 2: project-local copy → run (never skip its own hook) -------------
[ "$(verdict "$PROJECT/hooks/context-budget.sh")" = "run" ] \
  || fail "project-local copy must always run"
printf '  PASS  project-local copy runs\n'

# --- Case 3: plugin copy but project does NOT wire the basename → run --------
: > "$PLUGIN/hooks/other-hook.sh"
[ "$(verdict "$PLUGIN/hooks/other-hook.sh")" = "run" ] \
  || fail "plugin copy of an unwired basename must run"
printf '  PASS  plugin copy of an unwired basename runs\n'

# --- Case 4: settings wires the basename but the file dangles → run ----------
# A legacy/hand-edited settings.json can reference hooks/ that a plugin install
# never received; the plugin copy must still run or the hook fires nowhere.
rm -f "$PROJECT/hooks/context-budget.sh"
[ "$(verdict "$PLUGIN/hooks/context-budget.sh")" = "run" ] \
  || fail "plugin copy must run when the project-wired path dangles"
printf '  PASS  dangling project wiring → plugin copy runs\n'
: > "$PROJECT/hooks/context-budget.sh"

# --- Case 5: no project settings.json → run ---------------------------------
rm -f "$PROJECT/.claude/settings.json"
[ "$(verdict "$PLUGIN/hooks/context-budget.sh")" = "run" ] \
  || fail "with no project settings.json the plugin copy must run"
printf '  PASS  no settings.json → plugin copy runs\n'

printf '\nAll promotion-guard checks passed.\n'
