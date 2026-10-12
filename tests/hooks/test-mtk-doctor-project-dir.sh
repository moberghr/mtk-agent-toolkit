#!/usr/bin/env bash
set -euo pipefail

# test-mtk-doctor-project-dir.sh — mtk-doctor run from a plugin install must
# diagnose the PROJECT, not its own tree.
#
# The doctor resolves its own root from $0 and cd's there for toolkit checks
# (manifest, skills, hooks/ pipefail). Before this fix it ran every project check
# (constitution budget, settings.json permissions and hooks, context baseline,
# env calibration) from that directory too, so in a plugin install it measured the
# plugin's AGENTS.md and settings and never looked at the repo it was run for.
#
# Fixture: the doctor stays in this checkout (the "plugin"); a scratch project
# with a 200-line AGENTS.md, a settings.json carrying the invalid
# permissions.allowedTools key, and a hook block using PostToolUseFailure plus a
# made-up event. Checks: project AGENTS.md measured, allowedTools FAIL, --fix
# migrates its narrow entries, event names judged against the documented list, context-window
# calibration follows the model's real window.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/mtk-doctor.sh"

SBX="$(mktemp -d -t mtk-doctor-proj-XXXXXX)"
trap 'rm -rf "$SBX"' EXIT
PROJ="$SBX/project"
mkdir -p "$PROJ/.claude" "$SBX/home"
( cd "$PROJ" && git init -q . )
awk 'BEGIN { print "# Project constitution"; for (i = 2; i <= 200; i++) print "- rule " i }' > "$PROJ/AGENTS.md"
cat > "$PROJ/.claude/settings.json" <<'JSON'
{
  "permissions": {
    "allowedTools": ["Read", "Bash(dotnet build:*)"],
    "deny": ["Read(./.env)"]
  },
  "hooks": {
    "PostToolUseFailure": [],
    "NotARealEvent": []
  }
}
JSON

fails=0
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }
pass() { printf '  PASS  %s\n' "$1"; }

# Run as a plugin install would: cwd = project, CLAUDE_PROJECT_DIR = project,
# doctor script living elsewhere. HOME is sandboxed so no real plugin cache or
# user settings leak in.
run_doctor() {
  ( cd "$PROJ" && env -u MTK_HELPER_ROOT -u CLAUDE_PLUGIN_ROOT -u ANTHROPIC_MODEL \
      -u MTK_CONTEXT_WINDOW_TOKENS -u CLAUDE_CODE_DISABLE_1M_CONTEXT \
      -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY \
      HOME="$SBX/home" CLAUDE_PROJECT_DIR="$PROJ" "$@" bash "$DOCTOR" --json 2>/dev/null ) || true
}
# status<TAB>name<TAB>detail per check, from the doctor's JSON.
checks() {
  python3 -c '
import json, sys
for c in json.load(sys.stdin)["checks"]:
    print("\t".join((c["status"], c["name"], c["detail"])))'
}

OUT="$(run_doctor | checks)"

# 1. the project's AGENTS.md is the one measured
case "$OUT" in
  *$'WARN\tAGENTS.md exceeds 120-line budget\t200 lines'*) pass "project AGENTS.md (200 lines) measured" ;;
  *) fail "doctor did not measure the project AGENTS.md: $(printf '%s\n' "$OUT" | grep -i 'budget' || true)" ;;
esac

# 2. invalid permissions.allowedTools in project settings is a FAIL
grep -qE $'^FAIL\t[^\t]*allowedTools' <<< "$OUT" \
  && pass "permissions.allowedTools reported as FAIL" \
  || fail "no FAIL for permissions.allowedTools in project settings.json"

# 3. event names: PostToolUseFailure is known, a made-up event is not
grep -qE $'^WARN\tunknown hook event\tPostToolUseFailure' <<< "$OUT" \
  && fail "PostToolUseFailure flagged as unknown (MTK wires it)" \
  || pass "PostToolUseFailure accepted"
grep -qE $'^WARN\tunknown hook event\tNotARealEvent' <<< "$OUT" \
  && pass "made-up event flagged" \
  || fail "NotARealEvent in project settings.json was not flagged — event check is not reading the project"

# 4. context-window calibration: context-budget.sh sizes its window from the
#    model id, so an unset MTK_CONTEXT_WINDOW_TOKENS is reported as model-derived
#    (with the window), never as "miscalibrated"; only a pin that contradicts
#    the model's window WARNs.
ctx_line() { grep -E $'^(PASS|WARN)\tcontext budget' <<< "$1" || true; }
for m in claude-haiku-4-5 claude-opus-4-6 claude-sonnet-4-5; do
  o="$(ctx_line "$(run_doctor ANTHROPIC_MODEL="$m" | checks)")"
  case "$o" in
    *$'PASS\tcontext budget sized from the model id'*200000*) pass "$m: 200k window reported as model-derived, no WARN" ;;
    *) fail "$m: expected a model-derived PASS naming 200000, got: $o" ;;
  esac
done
for m in claude-haiku-5-5 claude-opus-5-5 claude-sonnet-5-5 'claude-opus-4-6[1m]' claude-fable-5-1; do
  o="$(ctx_line "$(run_doctor ANTHROPIC_MODEL="$m" | checks)")"
  case "$o" in
    *$'PASS\tcontext budget sized from the model id'*1000000*) pass "$m: 1M window reported as model-derived" ;;
    *) fail "$m: expected a model-derived PASS naming 1000000, got: $o" ;;
  esac
done
o="$(ctx_line "$(run_doctor ANTHROPIC_MODEL=claude-opus-5-5 CLAUDE_CODE_DISABLE_1M_CONTEXT=1 | checks)")"
case "$o" in *200000*) pass "CLAUDE_CODE_DISABLE_1M_CONTEXT=1 caps the window at 200k" ;; *) fail "CLAUDE_CODE_DISABLE_1M_CONTEXT=1 not reflected: $o" ;; esac
o="$(ctx_line "$(run_doctor ANTHROPIC_MODEL=claude-haiku-4-5 MTK_CONTEXT_WINDOW_TOKENS=1000000 | checks)")"
case "$o" in *$'WARN\tcontext budget pinned against the model'*) pass "a pin contradicting the model WARNs" ;; *) fail "pin vs model mismatch did not WARN: $o" ;; esac

# 5. --fix migrates the project settings (and only the project's)
PLUGIN_SETTINGS_BEFORE="$(cat "$REPO_ROOT/.claude/settings.json")"
( cd "$PROJ" && env -u MTK_HELPER_ROOT -u CLAUDE_PLUGIN_ROOT HOME="$SBX/home" \
    CLAUDE_PROJECT_DIR="$PROJ" bash "$DOCTOR" --fix >/dev/null 2>&1 ) || true
python3 - "$PROJ/.claude/settings.json" <<'PY' && pass "--fix activated the narrow entry, left the broad one inert" || fail "--fix did not migrate project settings.json as expected"
import json, sys
p = json.load(open(sys.argv[1]))["permissions"]
sys.exit(0 if p.get("allow") == ["Bash(dotnet build:*)"] and p.get("allowedTools") == ["Read"] else 1)
PY
[ "$(cat "$REPO_ROOT/.claude/settings.json")" = "$PLUGIN_SETTINGS_BEFORE" ] \
  && pass "--fix left the toolkit's own settings.json alone" \
  || fail "--fix modified the toolkit's own settings.json"

if [ "$fails" -gt 0 ]; then
  printf '%d mtk-doctor project-dir case(s) failed\n' "$fails" >&2
  exit 1
fi
echo "test-mtk-doctor-project-dir: all checks passed"
