# setup-bootstrap Slimming — Phase 2 (items 3 & 5)

- **Date:** 2026-05-29
- **Slug:** setup-bootstrap-slimming-phase2
- **Scope:** refactor (extract logic to scripts/tech-stack skills; no capability change)
- **Status:** shipped (item 5 in commit `beb45a7`; item 3 alongside). `setup-bootstrap/SKILL.md` 885 → 831 lines. Folded into the unreleased v7.9.0 changeset rather than separate patch bumps (nothing published yet).
- **Predecessor:** Phase 1 (items 1, 2, 6, 7, 8) shipped in v7.9.0, commit `c9ef15d` — `setup-bootstrap/SKILL.md` 1000 → 885 lines.

## Why

`setup-bootstrap/SKILL.md` was at the 1000-line hard cap. Phase 1 reclaimed
115 lines by extracting conditional *reference content* (monorepo template,
customization tables) to on-demand companions. Phase 2 targets the two
remaining heavy blocks, both of which are **logic or per-stack data that does
not belong in the always-loaded skill body**:

| Item | Current location | Lines | Nature |
|---|---|---|---|
| 3 | STEP 3.5a — "Verify Generated References" inline bash | ~44 | Verification *logic* (5 bash snippets) |
| 5 | STEP 4 — "Pre-Commit Review List" per-stack selection | ~24 | Per-stack *data* (conditional item lists) |

Combined target: another ~50–60 lines out, landing the skill around 825–835
with comfortable headroom.

---

## Item 3 — Extract reference-existence verification to a script

### Finding (important — corrects the Phase-1 assumption)

`scripts/verify-claims.sh` does **not** cover STEP 3.5a. They are distinct:

- **`verify-claims.sh`** (169 lines) parses *tagged claim lines*
  (`[EXTRACTED]`, `[ENFORCED]`), greps each cited evidence anchor, and
  **downgrades the tag** when an anchor has zero hits. It rewrites the file in
  place and emits `weak-claims.json` / `weak-claims-report.md`.
- **STEP 3.5a** answers a different question: *do the directories, `.csproj`/
  `.sln` projects, and framework versions referenced in the generated docs
  actually exist on disk?* It emits `STALE in <file>: ...` advisories and does
  **not** rewrite anything.

So item 3 is **not** "just call verify-claims" — it needs its own home.

### Design

Create `scripts/verify-references.sh` (S3.1 compliant: `set -euo pipefail`,
coreutils only, executable). It takes one or more generated files and runs the
five checks currently inline in STEP 3.5a:

1. Directory claims via `test -d` (PascalCase + lowercase path extraction)
2. Project-file claims (`.csproj` / `package.json` / `pyproject.toml`) via `find`
3. Framework/version claims cross-checked against actual project files
4. Solution-membership vs disk reality (`.sln`/`.slnx` project list vs `test -f`)
5. Proper-noun project/dir references in `.claude/rules/*.md`

```bash
# Usage
bash scripts/verify-references.sh CLAUDE.md .claude/rules/*.md \
  .claude/references/architecture-principles.md
# Exit 0 = no stale refs; exit 3 = stale refs found (prints STALE lines to stdout)
# Stack auto-detected from .claude/tech-stack so the .csproj/.sln checks only
# fire for dotnet, etc.
```

STEP 3.5a in the skill collapses from ~44 lines to ~8: a call, the "action on
stale references" policy (keep — that's judgment, not mechanics), and the
load-bearing **Rule** ("never infer disk presence from solution membership").

### Files touched

- **New:** `scripts/verify-references.sh`
- **New:** `tests/` smoke check or a pressure fixture (a fake repo with a stale
  `.csproj` reference must produce a `STALE` line; a clean repo must exit 0)
- **Edit:** `setup-bootstrap/SKILL.md` STEP 3.5a → call + policy + rule
- **Edit:** `.claude/manifest.json` — register the script
- **Edit:** `validate-toolkit.sh` already checks all `scripts/*.sh` for S3.1 — no
  new validator rule needed, just confirm it passes

### Risk

Medium. This is load-bearing grounding logic. **Parity is mandatory**: the
script must reproduce all five checks exactly. Mitigation — keep the bash
verbatim (move, don't rewrite), wrap in functions, and add a fixture that
proves a stale `.csproj` is still caught. Do not "improve" the regexes during
the move.

---

## Item 5 — Move pre-commit selection into tech-stack skills

### Finding

The bootstrap's "Pre-Commit Review List" is a **conditional selection** keyed by
detected tool (`If EF Core found: AsNoTracking…`, `If React found: Rules of
Hooks…`). The tech-stack skills already carry this content, but as **general
coding-style guidance** (e.g. `tech-stack-dotnet` line 51 "Add `AsNoTracking()`
for read-only queries"), not as a structured pre-commit selection. So this is
**not a pure dedup** — the structured, tool-keyed list has no home in the
tech-stack skills yet.

### Design

This mirrors how bootstrap already pulls `## Settings Additions`,
`## Scan Recipes`, and `## Format Command` from the active tech-stack skill.
Add a declarative section to each tech-stack skill:

```markdown
## Pre-Commit Review Items

Conditional, tool-keyed items for the generated pre-commit-review-list.md.
bootstrap selects items whose trigger tool was detected; caps at 10.

- [EF Core] AsNoTracking on reads, Select() over Include(), CancellationToken propagated
- [MediatR] one SaveChanges per handler, validate request
- [Lambda] DbContext disposal, cold-start considerations
```

The three "always include (any stack)" items (no PII in logs, tests for new
public methods, no hardcoded secrets) stay in the skill body — they are
stack-agnostic. STEP 4's "Pre-Commit Review List" collapses to: read the active
tech-stack skill's `## Pre-Commit Review Items`, filter by detected tools, add
the three always-include items, cap at 10.

### Schema change (S2.13)

`## Pre-Commit Review Items` becomes an **optional** tech-stack section. Update
`rules/skill-authoring.md` S2.13 to list it as optional (not required — older
stacks without it must still validate). `validate-toolkit.sh` needs no change if
the section is optional; confirm.

### Files touched

- **Edit:** `tech-stack-dotnet/SKILL.md`, `tech-stack-python/SKILL.md`,
  `tech-stack-typescript/SKILL.md` — add `## Pre-Commit Review Items`
- **Edit:** `setup-bootstrap/SKILL.md` STEP 4 → read-and-filter
- **Edit:** `.claude/rules/skill-authoring.md` S2.13 — note the optional section
- **Edit:** `CHANGELOG.md` + version bump (patch, e.g. v7.9.1)

### Risk

Low–medium. The content already exists; the move makes per-stack knowledge live
with its stack (consistent with the toolkit's tech-stack architecture). The only
subtlety is the schema note so validation stays green for stacks that haven't
added the section.

---

## Sequencing

1. **Item 5 first** (lower risk, no grounding logic). Ship as a patch bump.
2. **Item 3 second** (needs the fixture for parity confidence). Ship as a
   separate commit/PR so the script extraction can be reviewed in isolation.

Each item is independent and can be its own PR. Neither depends on the other.

## Success criteria

- `setup-bootstrap/SKILL.md` drops ~50–60 more lines (target ≤ 835)
- `bash scripts/validate-toolkit.sh` passes after each item
- **Item 3:** a fixture repo with a stale `.csproj` reference still produces a
  `STALE` line via `scripts/verify-references.sh`; a clean repo exits 0
- **Item 5:** running bootstrap on a dotnet repo with EF Core detected still
  yields the EF Core pre-commit items in the generated list, capped at 10
- No capability regression: detection, gates, grounding, and the generated
  pre-commit list are byte-comparable to pre-refactor output on a sample repo

## Out of scope

- Touching the preview gate, secret-scan gate, or claim-grounding intent
- Rewriting (vs. relocating) any verification regex
- Reordering STEP sequence
