#!/usr/bin/env bash
set -euo pipefail

# mtk-doctor cross-store lesson check: analytics.json vs .mtk/learnings.jsonl.
#
# WHY. A 2026-09 field run had analytics.json reporting 25 lessons captured while
# .mtk/learnings.jsonl was 0 bytes and tasks/lessons.md was populated — the
# "never seeded" store, in which every lesson query answers nothing. The first
# version of this check required BOTH stores to be empty, so that exact shape
# reported PASS. It must WARN, and name the migrate remedy.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/mtk-doctor.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; }

SBX="$(mktemp -d -t mtk-doctor-stores-XXXXXX)"
trap 'rm -rf "$SBX"' EXIT
PROJ="$SBX/proj"; mkdir -p "$PROJ/scripts" "$PROJ/.claude" "$PROJ/.mtk" "$PROJ/tasks" "$SBX/home"
cp "$DOCTOR" "$PROJ/scripts/mtk-doctor.sh"
( cd "$PROJ" && git init -q . )

run_doctor() { ( cd "$PROJ" && env -u MTK_HELPER_ROOT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR HOME="$SBX/home" bash "$PROJ/scripts/mtk-doctor.sh" 2>&1 ) || true; }

# 1. The field shape: analytics claims 25, JSONL empty, markdown populated → WARN + migrate remedy.
printf '{"lessons_captured": 25}\n' > "$PROJ/.claude/analytics.json"
: > "$PROJ/.mtk/learnings.jsonl"
printf '# Lessons\n\n## Regenerate the API contract from a running API\nbody\n\n## Second lesson\nbody\n' > "$PROJ/tasks/lessons.md"
out="$(run_doctor)"
grep -q 'lesson stores disagree' <<<"$out" || fail "field shape (25 / 0 / md=2) did not WARN. Output: $(grep -i lesson <<<"$out")"
grep -q 'learnings.sh migrate' <<<"$out" || fail "WARN does not name the migrate remedy"
grep -q 'never seeded' <<<"$out" || fail "WARN does not say the store was never seeded"
ok "analytics>0, JSONL empty, markdown populated → WARN with migrate remedy"

# 2. Both stores empty but analytics claims lessons → WARN (stale analytics).
: > "$PROJ/tasks/lessons.md"
out="$(run_doctor)"
grep -q 'lesson stores disagree' <<<"$out" || fail "both-empty shape did not WARN"
grep -q 'both empty' <<<"$out" || fail "both-empty WARN text wrong"
ok "analytics>0, both stores empty → WARN"

# 3. Stores agree (JSONL populated) → PASS.
printf '{"id":"L-1","title":"x"}\n' > "$PROJ/.mtk/learnings.jsonl"
out="$(run_doctor)"
grep -q 'lesson stores consistent' <<<"$out" || fail "populated JSONL did not PASS"
! grep -q 'lesson stores disagree' <<<"$out" || fail "populated JSONL still WARNs"
ok "JSONL populated → PASS"

# 4. Analytics claims nothing → PASS regardless of stores.
printf '{"lessons_captured": 0}\n' > "$PROJ/.claude/analytics.json"
: > "$PROJ/.mtk/learnings.jsonl"
out="$(run_doctor)"
grep -q 'lesson stores consistent' <<<"$out" || fail "analytics=0 did not PASS"
ok "analytics=0 → PASS"

echo "test-mtk-doctor-lesson-stores: all checks passed"
