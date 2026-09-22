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


# --- Constitution resolution in the core + context checks -------------------
# AGENTS.md is the canonical constitution. It counts toward the always-on
# baseline only when it is actually loaded (CLAUDE.md absent, or a shim with a
# bare `@AGENTS.md` line); when both files exist and CLAUDE.md does not import
# it, the doctor WARNs — unless AGENTS.md is generator-marked, which makes it a
# legacy references summary rather than a constitution. A legacy CLAUDE.md-only
# repo is unchanged.
#
# Trap: mtk-doctor.sh resolves ROOT_DIR from $0, so each fixture is a sandboxed
# "install" — a copy of the script under <fixture>/scripts/ — same as above.

# $1 = fixture name; echoes the fixture root.
make_const_proj() {
  local d="$SBX/$1"
  mkdir -p "$d/scripts" "$d/.claude" "$SBX/home-$1"
  cp "$DOCTOR" "$d/scripts/mtk-doctor.sh"
  ( cd "$d" && git init -q . )
  printf '%s\n' "$d"
}

run_const_doctor() { # $1 = fixture root
  ( cd "$1" && env -u MTK_HELPER_ROOT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR \
      HOME="$SBX/home" bash "$1/scripts/mtk-doctor.sh" 2>&1 ) || true
}

# 5. Shim: CLAUDE.md imports AGENTS.md → AGENTS.md is in the always-on
#    baseline and there is no import WARN.
D="$(make_const_proj const-shim)"
printf '# AGENTS\n\n## Critical Rules\n\n- **C9.1** The rule.\n' > "$D/AGENTS.md"
printf '@AGENTS.md\n' > "$D/CLAUDE.md"
out="$(run_const_doctor "$D")"
grep -q 'CLAUDE.md + AGENTS.md + rules/INDEX.md' <<<"$out" || fail "shim: AGENTS.md not counted in the always-on baseline. Output: $(grep -i 'always-on' <<<"$out")"
! grep -q 'CLAUDE.md does not import AGENTS.md' <<<"$out" || fail "shim: import WARN raised despite the @AGENTS.md line"
ok "shim (@AGENTS.md): AGENTS.md in the always-on baseline, no WARN"

# 6. Both files, no import line → WARN (AGENTS.md is silently ignored by the
#    default claude-md-or-agents-md mode) and it is NOT in the baseline.
D="$(make_const_proj const-noimport)"
printf '# AGENTS\n\n## Critical Rules\n\n- **C9.1** The rule.\n' > "$D/AGENTS.md"
printf '# Project\n\nNo import line here.\n' > "$D/CLAUDE.md"
out="$(run_const_doctor "$D")"
grep -q 'CLAUDE.md does not import AGENTS.md' <<<"$out" || fail "no-import: expected the import WARN. Output: $(grep -i agents <<<"$out")"
! grep -q 'CLAUDE.md + AGENTS.md + rules/INDEX.md' <<<"$out" || fail "no-import: AGENTS.md must not count toward the always-on baseline"
ok "both files without @AGENTS.md import → WARN, AGENTS.md not in the baseline"

# 7. Legacy CLAUDE.md-only (no AGENTS.md) → unchanged: no import WARN, no
#    AGENTS.md in the baseline.
D="$(make_const_proj const-legacy)"
printf '# Project\n\n## Critical Rules\n\n- **C0.1** The legacy rule.\n' > "$D/CLAUDE.md"
out="$(run_const_doctor "$D")"
! grep -q 'CLAUDE.md does not import AGENTS.md' <<<"$out" || fail "legacy: import WARN raised with no AGENTS.md present"
! grep -q 'CLAUDE.md + AGENTS.md + rules/INDEX.md' <<<"$out" || fail "legacy: AGENTS.md must not appear in the baseline"
grep -q 'always-on context baseline' <<<"$out" || fail "legacy: always-on baseline line missing. Output: $out"
ok "legacy CLAUDE.md-only repo unchanged"

# 8. Generator-marked AGENTS.md beside a non-importing CLAUDE.md — the legacy
#    PRE-INVERSION shape, and the correct one. The import WARN must NOT fire:
#    advising a shim here would promote a generated references summary over the
#    real constitution in CLAUDE.md. AGENTS.md is not loaded, so it stays out of
#    the always-on baseline (the loaded rule is unchanged by the marker).
D="$(make_const_proj const-marked-noimport)"
{ printf '# AGENTS.md\n\n'
  printf '> Auto-generated by MTK. Sections marked `## Custom:` are preserved across regeneration.\n\n'
  printf '## Critical Rules\n\n- **C9.1** Summary copy.\n'
} > "$D/AGENTS.md"
printf '# Project\n\n## Critical Rules\n\n- **C0.1** The real rule.\n' > "$D/CLAUDE.md"
out="$(run_const_doctor "$D")"
! grep -q 'CLAUDE.md does not import AGENTS.md' <<<"$out" || fail "marked AGENTS.md: import WARN must not fire for a generator-marked summary. Output: $(grep -i agents <<<"$out")"
! grep -q 'CLAUDE.md + AGENTS.md + rules/INDEX.md' <<<"$out" || fail "marked AGENTS.md: an unimported AGENTS.md must not count toward the always-on baseline"
ok "generator-marked AGENTS.md beside a real CLAUDE.md → no import WARN"

# 9. Generator-marked AGENTS.md that CLAUDE.md DOES import — the marker decides
#    which file is canonical, not which bytes are loaded. It is read by the
#    model, so it still counts toward the always-on baseline, and there is no
#    WARN (the import line is present).
D="$(make_const_proj const-marked-import)"
{ printf '# AGENTS.md\n\n'
  printf '> Auto-generated by MTK. Sections marked `## Custom:` are preserved across regeneration.\n\n'
  printf '## Critical Rules\n\n- **C9.1** Summary copy.\n'
} > "$D/AGENTS.md"
printf '@AGENTS.md\n' > "$D/CLAUDE.md"
out="$(run_const_doctor "$D")"
grep -q 'CLAUDE.md + AGENTS.md + rules/INDEX.md' <<<"$out" || fail "marked+imported: a loaded AGENTS.md must still count toward the always-on baseline. Output: $(grep -i 'always-on' <<<"$out")"
! grep -q 'CLAUDE.md does not import AGENTS.md' <<<"$out" || fail "marked+imported: import WARN raised despite the @AGENTS.md line"
ok "generator-marked but imported AGENTS.md still counts toward the always-on baseline"

echo "test-mtk-doctor-lesson-stores: all checks passed"
