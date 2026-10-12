#!/usr/bin/env bash
set -euo pipefail

# test-mtk-doctor-usage.sh — `mtk-doctor --usage` (raw usage counts) and the
# CONFIG section (what is active).
#
# --usage must report raw counters with their n and no thresholds or verdicts,
# degrade on an absent or corrupt analytics.json, and never write. CONFIG must
# WARN when the project names a stack or domain with nothing behind it.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/mtk-doctor.sh"

SBX="$(mktemp -d -t mtk-doctor-usage-XXXXXX)"
trap 'rm -rf "$SBX"' EXIT
PROJ="$SBX/project"
mkdir -p "$PROJ/.claude" "$PROJ/tasks" "$PROJ/docs/specs" "$SBX/home"
( cd "$PROJ" && git init -q . )

fails=0
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }
pass() { printf '  PASS  %s\n' "$1"; }

run_doctor() {
  ( cd "$PROJ" && env -u MTK_HELPER_ROOT -u CLAUDE_PLUGIN_ROOT HOME="$SBX/home" \
      CLAUDE_PROJECT_DIR="$PROJ" bash "$DOCTOR" "$@" 2>/dev/null )
}
field() { python3 -c 'import json,sys; d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d[k]
print(d)' "$1"; }

# 1. absent analytics degrades, exit 0
out="$(run_doctor --usage --json)" || fail "--usage exited non-zero with no analytics"
[ "$(printf '%s' "$out" | field analytics.status)" = "absent" ] && pass "absent analytics reported" || fail "absent analytics not reported: $out"

# 2. counters come through raw, with n
cat > "$PROJ/.claude/analytics.json" <<'JSON'
{ "first_session": "2026-09-01", "last_session": "2026-10-01", "sessions": 7,
  "total_operations": 140, "total_modifications": 30, "specs_created": 2,
  "lessons_captured": 1, "scope_guard_warnings": 3 }
JSON
printf '# Lessons\n\n## one\n\n## two\n' > "$PROJ/tasks/lessons.md"
: > "$PROJ/docs/specs/2026-10-01-a.md"
before="$(cksum "$PROJ/.claude/analytics.json" "$PROJ/tasks/lessons.md")"
out="$(run_doctor --usage --json)"
[ "$(printf '%s' "$out" | field analytics.n_sessions)" = "7" ] && pass "n_sessions = 7" || fail "n_sessions wrong: $out"
[ "$(printf '%s' "$out" | field analytics.scope_guard_warnings)" = "3" ] && pass "raw counter passed through" || fail "counter missing: $out"
[ "$(printf '%s' "$out" | field artifacts.lessons_md_entries)" = "2" ] && pass "lesson entries counted" || fail "lesson count wrong: $out"
[ "$(printf '%s' "$out" | field artifacts.specs)" = "1" ] && pass "specs counted" || fail "spec count wrong: $out"
[ "$before" = "$(cksum "$PROJ/.claude/analytics.json" "$PROJ/tasks/lessons.md")" ] && pass "read-only" || fail "--usage modified a file"

# 3. no verdicts in text output
txt="$(run_doctor --usage)"
if grep -qE '[Aa]nomal|[Hh]ealthy|WARN|FAIL' <<< "$txt"; then fail "text output carries a verdict: $txt"; else pass "no thresholds or verdicts"; fi

# 4. corrupt analytics degrades
printf '{ not json' > "$PROJ/.claude/analytics.json"
out="$(run_doctor --usage --json)" || fail "--usage exited non-zero on corrupt analytics"
[ "$(printf '%s' "$out" | field analytics.status)" = "unparseable" ] && pass "corrupt analytics reported" || fail "corrupt analytics not reported: $out"

# 5. CONFIG warns on a stack / domain with nothing behind it
printf 'cobol\n' > "$PROJ/.claude/tech-stack"
printf '# comment\nfinance\nnosuchdomain\n' > "$PROJ/.claude/domains"
cfg="$(run_doctor --json || true)"
checks="$(printf '%s' "$cfg" | python3 -c 'import json,sys
for c in json.load(sys.stdin)["checks"]:
    if c["category"] == "config": print(c["status"] + "\t" + c["name"])')"
grep -q $'^WARN\ttech stack cobol has no skill' <<< "$checks" && pass "unknown stack WARN" || fail "no WARN for unknown stack: $checks"
grep -q $'^WARN\tdomain nosuchdomain has no linter pack' <<< "$checks" && pass "missing domain pack WARN" || fail "no WARN for missing domain: $checks"
grep -q $'^PASS\tlinter pack domain-finance/' <<< "$checks" && pass "finance domain pack listed" || fail "finance pack not listed: $checks"
grep -q $'^PASS\tagent compliance-reviewer' <<< "$checks" && pass "agents listed" || fail "agents not listed: $checks"

if [ "$fails" -gt 0 ]; then
  printf '%d failure(s)\n' "$fails" >&2
  exit 1
fi
printf 'test-mtk-doctor-usage: all checks passed\n'
