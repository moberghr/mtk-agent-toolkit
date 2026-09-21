#!/usr/bin/env bash
set -euo pipefail

# constitution-digest.sh must recognise a project's rule ids whatever scheme the
# project uses, not only the toolkit's own `- **C0.1**` shape. It must also resolve
# the constitution file itself AGENTS.md-first: AGENTS.md-only, CLAUDE.md-shim +
# AGENTS.md, and legacy CLAUDE.md-only repos must all name the right source file
# in the digest heading and count the right rules (cases 5b-5e below).
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

# 5b. constitution_file() resolution: AGENTS.md-only repo (no CLAUDE.md at all).
R="$(new_repo)"
cat > "$R/AGENTS.md" <<'MD'
# Project

## Critical Rules

- **C0.1** Manifest versions must match.
- **C0.2** Every file must be listed.
MD
out="$(cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$SCRIPT")"
grep -q 'Totals: 2 Critical Rules' <<<"$out" || fail "AGENTS.md-only: expected 2 rules, got: $(grep Totals <<<"$out")"
grep -q '## Critical Rules (AGENTS.md)' <<<"$out" || fail "AGENTS.md-only: heading did not name AGENTS.md, got: $out"
ok "AGENTS.md-only repo resolves the constitution to AGENTS.md"

# 5c. constitution_file() resolution: CLAUDE.md is a shim (@AGENTS.md line) beside
#     a hand-curated AGENTS.md — the digest must read AGENTS.md, not the shim.
R="$(new_repo)"
cat > "$R/AGENTS.md" <<'MD'
# Project

## Critical Rules

- **C0.1** Real rule from AGENTS.md.
- **C0.2** Another real rule.
- **C0.3** Third rule.
MD
cat > "$R/CLAUDE.md" <<'MD'
# Project

@AGENTS.md

See AGENTS.md for the canonical constitution.

## Claude Code only

Nothing here should be counted.
MD
out="$(cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$SCRIPT")"
grep -q 'Totals: 3 Critical Rules' <<<"$out" || fail "shim+AGENTS.md: expected 3 rules, got: $(grep Totals <<<"$out")"
grep -q '## Critical Rules (AGENTS.md)' <<<"$out" || fail "shim+AGENTS.md: heading did not name AGENTS.md, got: $out"
ok "CLAUDE.md shim + AGENTS.md resolves the constitution to AGENTS.md"

# 5d. constitution_file() resolution: legacy repo — CLAUDE.md-only, no AGENTS.md.
#     Must resolve exactly as before this function existed (byte-identical contract).
R="$(new_repo)"
cat > "$R/CLAUDE.md" <<'MD'
# Project

## Critical Rules

- **C0.1** Legacy rule one.
- **C0.2** Legacy rule two.
- **C0.3** Legacy rule three.
MD
out="$(cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$SCRIPT")"
grep -q 'Totals: 3 Critical Rules' <<<"$out" || fail "legacy CLAUDE.md-only: expected 3 rules, got: $(grep Totals <<<"$out")"
grep -q '## Critical Rules (CLAUDE.md)' <<<"$out" || fail "legacy CLAUDE.md-only: heading did not name CLAUDE.md, got: $out"
ok "legacy CLAUDE.md-only repo resolves the constitution to CLAUDE.md unchanged"

# 5e. AGENTS.md and CLAUDE.md both exist, but CLAUDE.md is NOT a shim (no
#     @AGENTS.md line) — must still resolve to CLAUDE.md. This is the toolkit
#     repo's own current shape and must not flip silently.
R="$(new_repo)"
cat > "$R/AGENTS.md" <<'MD'
## Critical Rules
- **C0.1** Should not be used — not a shim.
MD
cat > "$R/CLAUDE.md" <<'MD'
## Critical Rules
- **C0.1** Real rule one.
- **C0.2** Real rule two.
MD
out="$(cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$SCRIPT")"
grep -q 'Totals: 2 Critical Rules' <<<"$out" || fail "non-shim CLAUDE.md + AGENTS.md: expected 2 rules, got: $(grep Totals <<<"$out")"
grep -q '## Critical Rules (CLAUDE.md)' <<<"$out" || fail "non-shim CLAUDE.md + AGENTS.md: heading did not name CLAUDE.md, got: $out"
ok "CLAUDE.md without an @AGENTS.md line resolves to CLAUDE.md even when AGENTS.md exists"

# 5f. A GENERATOR-MARKED AGENTS.md is the legacy references summary, never the
#     constitution. Even beside a CLAUDE.md shim (which would otherwise resolve
#     to AGENTS.md), the digest must read CLAUDE.md. Promoting a generated
#     pointer file would make every downstream Constitution Check cite headings
#     instead of rules.
R="$(new_repo)"
cat > "$R/AGENTS.md" <<'MD'
# AGENTS.md

> Auto-generated by MTK. Sections marked `## Custom:` are preserved across regeneration.

## Critical Rules (from CLAUDE.md)

- **C9.1** Summary copy that must never be counted.
- **C9.2** Second summary copy.
MD
cat > "$R/CLAUDE.md" <<'MD'
# Project

@AGENTS.md

## Critical Rules

- **C0.1** Real rule one.
- **C0.2** Real rule two.
- **C0.3** Real rule three.
- **C0.4** Real rule four.
MD
out="$(cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$SCRIPT")"
grep -q 'Totals: 4 Critical Rules' <<<"$out" || fail "marked AGENTS.md + shim: expected 4 rules from CLAUDE.md, got: $(grep Totals <<<"$out")"
grep -q '## Critical Rules (CLAUDE.md)' <<<"$out" || fail "marked AGENTS.md + shim: heading did not name CLAUDE.md, got: $out"
grep -q 'C9.1' <<<"$out" && fail "marked AGENTS.md + shim: summary rules leaked into the digest"
ok "generator-marked AGENTS.md is never the constitution, even beside a CLAUDE.md shim"

# 5g. The marker must only count within the first 10 lines. The same string far
#     down a hand-authored AGENTS.md (e.g. prose describing the legacy script)
#     must NOT disqualify it — otherwise documenting the marker demotes the file.
R="$(new_repo)"
{
  printf '# AGENTS.md\n\n## Critical Rules\n\n'
  printf -- '- **C0.1** Real rule one.\n- **C0.2** Real rule two.\n\n'
  printf '## Notes\n\n'
  for i in $(seq 1 12); do printf 'filler line %%s\n' "$i"; done
  printf '\nThe legacy summary carries "Auto-generated by MTK" in its header.\n'
} > "$R/AGENTS.md"
out="$(cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$SCRIPT")"
grep -q 'Totals: 2 Critical Rules' <<<"$out" || fail "late marker: expected 2 rules, got: $(grep Totals <<<"$out")"
grep -q '## Critical Rules (AGENTS.md)' <<<"$out" || fail "late marker: heading did not name AGENTS.md, got: $out"
ok "the marker string below line 10 does not demote a hand-authored AGENTS.md"

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
