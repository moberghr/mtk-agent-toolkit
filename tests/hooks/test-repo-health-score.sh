#!/usr/bin/env bash
set -euo pipefail

# test-repo-health-score.sh — the repo-health scorecard is a per-asset action
# list, not a score.
#
# Checks: no medal / pass-count aggregate in either format; nine assets; spec,
# plan and rule-file counts are not assets (they rewarded MTK paperwork); assets
# 5 and 6 are `na` outside the toolkit and scored inside it; action_needed lists
# exactly the partial/fail assets; an all-pass repo reports "none".

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCORE="$REPO_ROOT/scripts/repo-health-score.sh"

SBX="$(mktemp -d -t repo-health-score-XXXXXX)"
trap 'rm -rf "$SBX"' EXIT

fails=0
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }
pass() { printf '  PASS  %s\n' "$1"; }

# Run from a copy of the script inside the sandbox repo so the sibling
# resolvers are the real ones but nothing in this checkout is scored.
mk_repo() {
  local d="$1"
  mkdir -p "$d/scripts" "$d/.claude/skills/tech-stack-python" "$d/.claude/references" "$d/tasks"
  ( cd "$d" && git init -q . )
  cp "$SCORE" "$REPO_ROOT/scripts/resolve-constitution.sh" "$REPO_ROOT/scripts/resolve-tech-stack.sh" "$d/scripts/"
  printf '# Constitution\n\nRun `pytest` to test.\n' > "$d/AGENTS.md"
  printf 'python\n' > "$d/.claude/tech-stack"
  printf -- '---\nname: tech-stack-python\n---\n' > "$d/.claude/skills/tech-stack-python/SKILL.md"
  for i in 1 2 3 4 5; do printf -- '- rule %s [EXTRACTED]\n' "$i"; done > "$d/.claude/references/architecture-principles.md"
  printf '# Lessons\n\n## one\n' > "$d/tasks/lessons.md"
  printf '# Readme\n' > "$d/README.md"
  printf '.claude/settings.local.json\n' > "$d/.gitignore"
}
score() { ( cd "$1" && "${BASH:-bash}" scripts/repo-health-score.sh "${@:2}" ); }
status_of() { python3 -c 'import json,sys
d=json.load(sys.stdin)
print(next(a["status"] for a in d["assets"] if a["name"].startswith(sys.argv[1] + ".")))' "$1"; }

# 1. Target repo (outside the toolkit), all actionable assets passing
T="$SBX/target"; mk_repo "$T"
js="$(score "$T" --json)"
md="$(score "$T")"
python3 -c 'import json,sys; d=json.load(sys.stdin); assert set(d) == {"assets", "action_needed"}, d.keys()' <<< "$js" \
  && pass "JSON carries assets + action_needed only" || fail "unexpected JSON keys: $js"
[ "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["assets"]))' <<< "$js")" = "9" ] \
  && pass "nine assets" || fail "asset count is not 9"
if grep -qiE 'medal|platinum|gold|silver|bronze|scoring assets' <<< "$md$js"; then fail "medal/score aggregate still emitted"; else pass "no medal or aggregate"; fi
if grep -qiE 'Recent specs|Recent plans|Rules documented' <<< "$md$js"; then fail "paperwork-count asset still present"; else pass "spec/plan/rule counts are not assets"; fi
[ "$(status_of 5 <<< "$js")" = "na" ] && [ "$(status_of 6 <<< "$js")" = "na" ] \
  && pass "assets 5 and 6 na outside the toolkit" || fail "assets 5/6 not na outside the toolkit: $js"
grep -q 'outside the toolkit' <<< "$md" && pass "na reason shown" || fail "na reason missing"
[ "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["action_needed"])' <<< "$js")" = "[]" ] \
  && pass "all-pass repo: empty action list" || fail "action list not empty: $js"
grep -q 'Needs action:\*\* none' <<< "$md" && pass "markdown says none" || fail "markdown action line wrong: $md"

# 2. Failing assets land in action_needed
rm "$T/README.md"; : > "$T/.gitignore"
js="$(score "$T" --json)"
act="$(python3 -c 'import json,sys; print("|".join(json.load(sys.stdin)["action_needed"]))' <<< "$js")"
[ "$act" = "7. README present|9. Sensitive files gitignored" ] && pass "action list = failing assets" || fail "action list wrong: $act"

# 3. Inside the toolkit, 5 and 6 are scored
K="$SBX/toolkit"; mk_repo "$K"
mkdir -p "$K/.claude-plugin"
printf '{"version":"1.2.3"}\n' > "$K/.claude/manifest.json"
printf '{"version":"1.2.3"}\n' > "$K/.claude-plugin/plugin.json"
printf '#!/usr/bin/env bash\nexit 0\n' > "$K/scripts/validate-toolkit.sh"
js="$(score "$K" --json)"
[ "$(status_of 5 <<< "$js")" = "pass" ] && [ "$(status_of 6 <<< "$js")" = "pass" ] \
  && pass "assets 5 and 6 scored inside the toolkit" || fail "assets 5/6 not scored in toolkit: $js"
printf '{"version":"9.9.9"}\n' > "$K/.claude-plugin/plugin.json"
printf '#!/usr/bin/env bash\nexit 1\n' > "$K/scripts/validate-toolkit.sh"
js="$(score "$K" --json)"
[ "$(status_of 5 <<< "$js")" = "fail" ] && [ "$(status_of 6 <<< "$js")" = "fail" ] \
  && pass "version drift and validator failure fail" || fail "toolkit failures not detected: $js"

if [ "$fails" -gt 0 ]; then
  printf '%d failure(s)\n' "$fails" >&2
  exit 1
fi
printf 'test-repo-health-score: all checks passed\n'
