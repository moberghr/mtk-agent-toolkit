#!/usr/bin/env bash
set -euo pipefail

# mtk-doctor fails when the toolkit's hooks/hooks.json registers a hook on the
# hot path: UserPromptSubmit (every prompt) or a tool matcher that fires on
# Read/Grep/Glob or on MCP calls (any matcher naming mcp__, server-scoped or
# not), including a match-all matcher. The
# runtime diet removed all of them; this check keeps a later edit from quietly
# adding one back. A clean hooks.json reports PASS.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available" >&2; exit 0; }

SBX="$(mktemp -d -t mtk-doctor-hotpath-XXXXXX)"
trap 'rm -rf "$SBX"' EXIT
PROJ="$SBX/proj"; mkdir -p "$PROJ/scripts" "$PROJ/hooks" "$PROJ/.claude"
cp "$REPO_ROOT/scripts/mtk-doctor.sh" "$PROJ/scripts/mtk-doctor.sh"
mkdir -p "$PROJ/hooks/lib" && cp "$REPO_ROOT/hooks/lib/hot_path_matchers.py" "$PROJ/hooks/lib/"
( cd "$PROJ" && git init -q . )
printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n' > "$PROJ/hooks/x.sh"
chmod +x "$PROJ/hooks/x.sh"

run_doctor() { ( cd "$PROJ" && env -u MTK_HELPER_ROOT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR HOME="$SBX/home" bash "$PROJ/scripts/mtk-doctor.sh" 2>&1 ) || true; }
hooks_json() { # $1 = JSON body of "hooks"
  printf '{"hooks":%s}\n' "$1" > "$PROJ/hooks/hooks.json"
}
H='{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/x.sh"}'

hooks_json "{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[$H]},{\"matcher\":\"Edit|Write\",\"hooks\":[$H]}],\"Stop\":[{\"hooks\":[$H]}]}"
out="$(run_doctor)"
grep -q 'no hot-path hooks registered' <<<"$out" || fail "clean hooks.json must PASS the hot-path check. Output: $out"
ok "clean hooks.json passes"

check_fails() { # $1 label  $2 hooks body  $3 expected detail fragment
  hooks_json "$2"
  local o; o="$(run_doctor)"
  grep -q 'hot-path hook registered' <<<"$o" || fail "$1: expected a hot-path FAIL. Output: $o"
  grep -qF -- "$3" <<<"$o" || fail "$1: FAIL must name '$3'. Output: $o"
  ok "$1"
}
check_fails "UserPromptSubmit is a hot-path FAIL" "{\"UserPromptSubmit\":[{\"hooks\":[$H]}]}" "UserPromptSubmit"
check_fails "Read|Grep matcher is a hot-path FAIL" "{\"PreToolUse\":[{\"matcher\":\"Read|Grep\",\"hooks\":[$H]}]}" "Read|Grep"
check_fails "Glob in a PostToolUse matcher is a FAIL" "{\"PostToolUse\":[{\"matcher\":\"Edit|Glob\",\"hooks\":[$H]}]}" "Edit|Glob"
check_fails "mcp__ matcher is a hot-path FAIL" "{\"PostToolUseFailure\":[{\"matcher\":\"mcp__.*\",\"hooks\":[$H]}]}" "mcp__.*"
check_fails "match-all matcher is a hot-path FAIL" "{\"PreToolUse\":[{\"hooks\":[$H]}]}" "PreToolUse"
check_fails "server-scoped mcp__ matcher is a FAIL" "{\"PreToolUse\":[{\"matcher\":\"mcp__github__.*\",\"hooks\":[$H]}]}" "mcp__github__.*"
check_fails "Bash|mcp__memory__.* is a FAIL" "{\"PostToolUse\":[{\"matcher\":\"Bash|mcp__memory__.*\",\"hooks\":[$H]}]}" "Bash|mcp__memory__.*"

# The shipped hooks.json passes.
out="$( cd "$REPO_ROOT" && env -u MTK_HELPER_ROOT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR HOME="$SBX/home" bash scripts/mtk-doctor.sh 2>&1 || true)"
grep -q 'no hot-path hooks registered' <<<"$out" || fail "the shipped hooks/hooks.json must pass the hot-path check. Output: $(grep -i 'hot-path' <<<"$out" || true)"
ok "shipped hooks.json passes"

printf '\nAll mtk-doctor hot-path checks passed.\n'
