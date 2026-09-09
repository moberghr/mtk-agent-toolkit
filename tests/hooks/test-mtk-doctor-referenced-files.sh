#!/usr/bin/env bash
set -euo pipefail

# mtk-doctor must FAIL when a file the skills reference at runtime resolves
# nowhere along the MTK resolution order, and WARN when it resolves only by
# searching the plugin cache (inline script resolvers never look there).
#
# WHY. A 2026-09 field run (beacon) found security-checklist.md,
# testing-patterns.md, review-config.json and the handoff schema "missing" only
# when a phase tried to read them. All four ship in the manifest — resolution had
# failed, and nothing had said so up front.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/mtk-doctor.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; }

SBX="$(mktemp -d -t mtk-doctor-XXXXXX)"
trap 'rm -rf "$SBX"' EXIT

# The doctor anchors on its own parent dir, so a sandboxed "install" is a copy
# of the script under <sandbox>/scripts/.
PROJ="$SBX/proj"; mkdir -p "$PROJ/scripts" "$SBX/home-empty"
cp "$DOCTOR" "$PROJ/scripts/mtk-doctor.sh"
( cd "$PROJ" && git init -q . )

run_doctor() { # extra env assignments as args
  ( cd "$PROJ" && env -u MTK_HELPER_ROOT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR "$@" bash "$PROJ/scripts/mtk-doctor.sh" 2>&1 ) || true
}

# 1. Nothing resolvable: no env, no local copy, empty plugin cache → FAIL per file.
out="$(run_doctor HOME="$SBX/home-empty")"
grep -q 'referenced file unresolvable' <<<"$out" || fail "no FAIL for unresolvable referenced files. Output: $out"
grep -q 'security-checklist.md' <<<"$out" || fail "security-checklist.md not named among unresolvable files"
grep -q 'handoff.schema.json' <<<"$out" || fail "handoff.schema.json not named among unresolvable files"
grep -q 'MTK_HELPER_ROOT' <<<"$out" || fail "remedy does not name MTK_HELPER_ROOT"
ok "unresolvable referenced files FAIL, each named, remedy given"

# 2. MTK_HELPER_ROOT pointing at a checkout → PASS via that root.
out="$(run_doctor HOME="$SBX/home-empty" MTK_HELPER_ROOT="$REPO_ROOT")"
grep -q 'runtime-referenced files resolve' <<<"$out" || fail "PASS line missing with MTK_HELPER_ROOT set. Output: $out"
grep -q 'via MTK_HELPER_ROOT' <<<"$out" || fail "PASS line does not credit MTK_HELPER_ROOT"
! grep -q 'referenced file unresolvable' <<<"$out" || fail "still FAILing with MTK_HELPER_ROOT set"
ok "MTK_HELPER_ROOT resolves every referenced file → PASS"

# 3. Only a plugin-cache copy exists and no env var is set → WARN (inline
#    resolvers would still miss it), not PASS and not FAIL.
CACHE="$SBX/home-cache/.claude/plugins/cache/mtk/mtk/9.9.9"
mkdir -p "$CACHE/.claude/skills/context-engineering"
cp "$REPO_ROOT/.claude/skills/context-engineering/SKILL.md" "$CACHE/.claude/skills/context-engineering/SKILL.md"
for f in .claude/references/security-checklist.md .claude/references/testing-patterns.md \
         .claude/references/performance-checklist.md .claude/references/mtk-file-resolution.md \
         .claude/review-config.json .claude/schemas/handoff.schema.json \
         scripts/learnings.sh scripts/constitution-digest.sh scripts/workflow-artifact.sh \
         scripts/build-context-pack.sh scripts/resolve-tech-stack.sh scripts/mtk-verify-run.sh; do
  mkdir -p "$CACHE/$(dirname "$f")"; cp "$REPO_ROOT/$f" "$CACHE/$f"
done
out="$(run_doctor HOME="$SBX/home-cache")"
grep -q 'resolve only via plugin-cache search' <<<"$out" || fail "no WARN for cache-only resolution. Output: $out"
! grep -q 'referenced file unresolvable' <<<"$out" || fail "cache-only case wrongly FAILed"
grep -q "MTK_HELPER_ROOT=$CACHE" <<<"$out" || fail "WARN remedy does not name the cache root to pin"
ok "cache-only resolution WARNs and names the root to pin"

# 4. Same cache, CLAUDE_PLUGIN_ROOT set → PASS via CLAUDE_PLUGIN_ROOT.
out="$(run_doctor HOME="$SBX/home-cache" CLAUDE_PLUGIN_ROOT="$CACHE")"
grep -q 'via CLAUDE_PLUGIN_ROOT' <<<"$out" || fail "CLAUDE_PLUGIN_ROOT not credited. Output: $out"
ok "CLAUDE_PLUGIN_ROOT resolves → PASS"

# 5. In this checkout itself every file is local → PASS via install.
out="$( cd "$REPO_ROOT" && env -u MTK_HELPER_ROOT -u CLAUDE_PLUGIN_ROOT HOME="$SBX/home-empty" bash "$DOCTOR" 2>&1 || true )"
grep -q 'runtime-referenced files resolve' <<<"$out" || fail "dev checkout should PASS the referenced-files check. Output: $(grep -i referenced <<<"$out")"
ok "dev checkout resolves locally"

echo "test-mtk-doctor-referenced-files: all checks passed"
