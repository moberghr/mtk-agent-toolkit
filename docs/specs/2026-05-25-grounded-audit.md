# Grounded Audit — verify-before-claim for setup-bootstrap / setup-audit

> Bundled into v7.8.0 alongside ai-ready-borrows. Addresses real-world bootstrap failure mode: a recent external run on a React codebase produced ~20 factual errors that a single grep would have falsified. This spec turns each failure class into an enforceable gate.

## 1. Goal & scope

The audit pipeline is thorough but unverified. Generated `CLAUDE.md`, `architecture-principles.md`, and `conventions.md` carry factual claims (file paths, API names, integration flags, enumerations) that the LLM invents alongside real ones, and downstream tools treat all of it as ground truth. We add three primitives and four content rules:

**Primitives:**
1. **`scripts/verify-claims.sh`** — post-generation grep/AST sweep over generated docs; drops or downgrades claims that have no source hit; emits a `weak-claims.json` ranked report.
2. **Audit SHA stamp** — every generated doc gets an `audited-against: <sha>` frontmatter line written at generation time.
3. **`scripts/audit-drift-check.sh`** — diffs current HEAD against the stamped SHA, flags claims touching changed files; surfaces as a tier-1 nudge and via `/mtk repo-health`.

**Content rules (encoded in `.claude/references/audit-grounding.md`):**
4. **Rule confidence tags** — `[ENFORCED]` / `[CONVENTION]` / `[ASPIRATIONAL]` on every rule line in generated CLAUDE.md and architecture-principles.md. Mirrors the existing principle-level S1.15 tags but applies to *prescriptive rules*.
5. **Transient-state ban** — generators MUST NOT bake branch names, dates other than the audit date, PR numbers, or current-user identifiers into generated rules. Lint pass blocks.
6. **No partial lists** — generators either enumerate fully or emit a single source link (`see <path>`). Partial enumerations (6 of 12 localStorage keys) steer downstream AI to the wrong subset.
7. **Terminology denylist** — small explicit list of common confusions (path-alias vs baseUrl, HTML vs JSX, enum vs typed object, etc.) checked at generation time.

### Out of scope (deferred)

- Auto-fixing claims — verify-claims drops or downgrades only; never rewrites.
- Cross-doc consistency checking (e.g., CLAUDE.md says React 18 but tech-stack file says React 19) — separate v7.9 work.
- AST-level claim verification beyond what tree-sitter repomap already provides — grep-first is sufficient for the failure modes observed.

### Classification

- **Scope:** feature (multi-skill, manifest-affecting, no new entry-point command — rides inside setup-audit + setup-bootstrap)
- **security_impact:** none (read-only verification of already-generated content)
- **breaking_change:** no — adds new sections to generated docs; existing audits remain readable
- **Implementation path:** incremental (~10 files, single coherent batch)

## 2. EARS-style requirements

- **U1** When `setup-audit` writes `architecture-principles.md` or `conventions.md`, the system SHALL stamp `audited-against: <commit-sha>` and `audited-at: <ISO8601>` into the frontmatter or a `<!-- mtk-stamp -->` comment block at the top of the file.
- **U2** When `setup-bootstrap` writes `CLAUDE.md`, the system SHALL include the same stamp in a footer comment block (the file is human-edited; footer placement avoids merge conflicts on STEP -1 re-runs).
- **U3** After any generation step, the system SHALL invoke `scripts/verify-claims.sh <generated-file>` which SHALL:
  - parse claim lines (lines with a `[EXTRACTED]` / `[INFERRED:N]` / `[ENFORCED]` / `[CONVENTION]` tag, OR lines citing `path:line` / a path glob),
  - run a grep (and tree-sitter symbol lookup when `.claude/.mtk-cache/repomap.json` exists) for each cited evidence anchor,
  - downgrade `[EXTRACTED] → [INFERRED:0.5]` for any claim whose evidence has zero hits, and downgrade `[ENFORCED] → [ASPIRATIONAL]`,
  - emit `.claude/.mtk-cache/weak-claims.json` listing the N lowest-evidence claims with file/line, evidence anchor, hit count, and severity.
- **U4** Every prescriptive rule line in generated CLAUDE.md and architecture-principles.md SHALL carry exactly one tag from `[ENFORCED]` / `[CONVENTION]` / `[ASPIRATIONAL]`. Untagged rule lines SHALL be quarantined into a `## Untagged (review)` section rather than left in the main body.
- **U5** Generators SHALL NOT emit transient state into rules. Specifically the lint blocks any line containing: a branch name matching `^(feat|fix|chore|docs|refactor)/`, an ISO date other than the audit date, a PR number (`#\d+`), or a username from `git log -1 --format=%ae`. Detected lines are dropped with a warning.
- **U6** When a rule cites an enumeration, the generator SHALL either list ALL items or emit a single link to the canonical source. Partial enumerations are detected by the pattern `(e\.g\.,? \w+,( \w+,){2,}|including [A-Z]\w+,( [A-Z]\w+,){2,})` followed by no `etc. — see <path>` or full list closer. Detected lines are downgraded to `[ASPIRATIONAL]` and footnoted.
- **U7** Generators SHALL run claim text through a terminology denylist (canonical pairs documented in `.claude/references/audit-grounding.md`); detected confusions are flagged in `weak-claims.json` for human review (not auto-rewritten).
- **U8** When `/mtk repo-health` is invoked AND a stamped audit doc exists, the system SHALL run `scripts/audit-drift-check.sh` which SHALL compute `git diff --name-only <stamped-sha>..HEAD`, intersect with file paths cited in generated docs, and surface invalidated claims as a `🟨` row in the scorecard's AI Context bucket.
- **U9** After `setup-bootstrap` or `setup-audit` completes, the system SHALL write `.claude/.mtk-cache/weak-claims-report.md` containing a top-5 `## ⚠️ Weakest claims — verify first` block (file:line, evidence anchor, hit count) and SHALL print the file path in the final summary so the engineer can paste it into a PR body or review note.

## 3. Change manifest

**New files (5):**
- `scripts/verify-claims.sh` — grep-verify cited evidence; emit weak-claims report
- `scripts/audit-drift-check.sh` — compare stamped SHA against HEAD; flag invalidated claims
- `.claude/references/audit-grounding.md` — canonical rules (rule tags, transient ban, partial-list policy, terminology denylist)
- `tests/pressure-tests/audit-grounding.md` — adversarial scenarios (fabricated claim, partial list, transient branch name, terminology trap)
- `docs/plans/2026-05-25-grounded-audit.md` — execution plan

**Modified files (6):**
- `.claude/skills/setup-audit/SKILL.md` — add STEP 3.7 (stamp + verify-claims) and STEP 3.8 (rule tagging + transient lint); update STEP 4 to surface weak claims
- `.claude/skills/setup-bootstrap/SKILL.md` — same stamp + verify pass; add weak-claims block to PR/summary body
- `.claude/skills/repo-health/SKILL.md` — call `audit-drift-check.sh`; scorecard row reports drift count
- `.claude/references/repo-health-assets.md` — add asset note: AI Context bucket items downgrade to 🟨 when drift detected
- `.claude/manifest.json` — register 4 new files (script + reference + pressure test + plan; the spec itself is intentionally not in manifest, matching v7.8.0 pattern for `docs/specs/*.md` borrows)
- `CLAUDE.md` — single line under "Skill Routing": add `bash scripts/verify-claims.sh <file>` row, note SHA stamping
- `.claude/rules/skill-authoring.md` — add S2.25: generated docs carry `audited-against` stamp

**Note:** `.claude-plugin/plugin.json` already at 7.8.0 — no bump needed since this rides inside the existing v7.8.0 release.

## 4. Verification

- `bash scripts/validate-toolkit.sh` passes — manifest matches disk, frontmatter present on new files
- `bash scripts/verify-claims.sh .claude/references/architecture-principles.md` runs on this repo's own audit doc and produces a weak-claims report (eat-our-own-dogfood)
- `bash scripts/audit-drift-check.sh` correctly identifies a synthetic drift (stamp old SHA, modify file, expect drift flag)
- Pressure test `tests/pressure-tests/audit-grounding.md` — four adversarial scenarios all caught
- Manual: re-run a setup-bootstrap simulation on a fixture repo with a fabricated claim; verify the claim is downgraded and appears in weak-claims.json

## 5. Open decisions

None — the 7 fixes from the audur feedback map 1:1 to U1–U9 and the design choices are forced by existing MTK primitives (S1.15 confidence tags, shrink-guard pattern, repomap.json).
