#!/usr/bin/env bash
set -euo pipefail

# constitution-digest.sh must recognise a project's rule ids whatever scheme the
# project uses, not only the toolkit's own `- **C0.1**` shape.
#
# WHY. A 2026-09 field run (beacon) had its Critical Rules written as
# `- **§0.1** …`. The digest's grep matched only `**C[0-9]`, printed an empty
# Critical Rules section, and every spec Constitution Check downstream cited
# nothing — silently, because the principles file kept the exit code at 0.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/constitution-digest.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; }

SBX="$(mktemp -d -t mtk-digest-XXXXXX)"
trap 'rm -rf "$SBX"' EXIT

new_repo() {
  local d; d="$(mktemp -d "$SBX/repo-XXXXXX")"
  git -C "$d" init -q
  printf '%s' "$d"
}

# 1. Toolkit-native ids still work.
R="$(new_repo)"
cat > "$R/CLAUDE.md" <<'MD'
# Project

## Critical Rules

- **C0.1** Manifest versions must match.
- **C0.2** Every file must be listed.
MD
out="$(cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$SCRIPT")"
grep -q 'Totals: 2 Critical Rules' <<<"$out" || fail "C0.x ids: expected 2 rules, got: $(grep Totals <<<"$out")"
ok "C0.x ids still recognised"

# 2. The beacon shape: section ids (§0.1). Previously 0 rules and no hint.
R="$(new_repo)"
cat > "$R/CLAUDE.md" <<'MD'
# Project

## Critical Rules

- **§0.1** Every MCP SQL path validates through ISqlExecutionGate.
- **§0.2** No raw connection strings in code.
- **§1.5** Audit every write to regulated state.
MD
out="$(cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$SCRIPT")"
grep -q 'Totals: 3 Critical Rules' <<<"$out" || fail "§0.x ids: expected 3 rules, got: $(grep Totals <<<"$out")"
grep -q '§0.1' <<<"$out" || fail "§0.x ids: rule text missing from digest"
ok "§0.x ids recognised"

# 3. Other common schemes: S1.2, R-12, bare 0.1, ARCH-3.
R="$(new_repo)"
cat > "$R/CLAUDE.md" <<'MD'
## Critical Rules
- **S1.2** Rule with S prefix.
- **R-12** Rule with dash.
- **0.1** Bare numeric.
- **ARCH-3** Word prefix.
MD
out="$(cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$SCRIPT")"
grep -q 'Totals: 4 Critical Rules' <<<"$out" || fail "mixed ids: expected 4 rules, got: $(grep Totals <<<"$out")"
ok "S1.2 / R-12 / 0.1 / ARCH-3 ids recognised"

# 4. Bold prose that is NOT a rule id must not be counted.
R="$(new_repo)"
cat > "$R/CLAUDE.md" <<'MD'
## Critical Rules
- **C0.1** A real rule.
- **Decision rule for /mtk:** Say what you want in plain English.
- **Never** delete data files.
- **2 files** is the fix ceiling.
MD
out="$(cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$SCRIPT")"
grep -q 'Totals: 1 Critical Rules' <<<"$out" || fail "bold prose: expected 1 rule, got: $(grep Totals <<<"$out")"
ok "bold prose without an id shape is not counted"

# 5. Custom scheme via MTK_RULE_ID_PATTERN wins over the built-in.
R="$(new_repo)"
cat > "$R/CLAUDE.md" <<'MD'
## Critical Rules
- [RULE-7] Bracketed ids.
- [RULE-8] Another.
- **C0.1** Not this scheme.
MD
out="$(cd "$R" && CLAUDE_PROJECT_DIR="$R" MTK_RULE_ID_PATTERN='^\s*-\s*\[RULE-[0-9]+\]' bash "$SCRIPT")"
grep -q 'Totals: 2 Critical Rules' <<<"$out" || fail "custom pattern: expected 2 rules, got: $(grep Totals <<<"$out")"
ok "MTK_RULE_ID_PATTERN override honoured"

# 6. Zero matches with a Critical Rules section present → a stderr hint naming
#    the knob, so the empty section is never silent again.
R="$(new_repo)"
cat > "$R/CLAUDE.md" <<'MD'
## Critical Rules
- Rule (a): plain bullets with no id at all.
- Rule (b): still none.
MD
mkdir -p "$R/.claude/references"
printf -- '- [EXTRACTED] one principle\n' > "$R/.claude/references/architecture-principles.md"
err="$( (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$SCRIPT" >/dev/null) 2>&1 )"
grep -q 'MTK_RULE_ID_PATTERN' <<<"$err" || fail "zero-match hint: expected stderr hint naming MTK_RULE_ID_PATTERN, got: $err"
ok "zero-match with a Critical Rules section emits a hint"

echo "test-constitution-digest: all checks passed"
