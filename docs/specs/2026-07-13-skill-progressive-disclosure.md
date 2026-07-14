# Skill Progressive Disclosure — Extract Oversized SKILL.md Bodies

**Date:** 2026-07-13 · **Scope:** internal-refactoring · **Security impact:** none
**Origin:** deferred Item 2 of `docs/plans/2026-07-03-token-optimization.md` ("progressive-disclosure the fattest SKILL.md bodies"), scoped by the 2026-07-13 md-size audit (9-agent workflow, each extraction claim adversarially verified).

## Summary

Three skills carry large payloads that load in full on every invocation: `setup-bootstrap` (845 lines / ~11.0k tokens), `setup-audit` (732 / ~7.4k), and `subagent-implementation` (347 / ~5.0k). Per S2.26 a SKILL.md is a navigation layer, not a payload. This change moves the adversarially-verified extractable sections (~950 lines total) into ten new companion files under the shared `.claude/references/` directory — the exact pattern `setup-bootstrap` already uses for `config-ingestion.md`, `preview-gate.md`, `command-verification.md`, `bootstrap-customization.md`, and `regen-diff-contract.md` — each behind an imperative read-on-demand pointer resolved via the skill's existing `## MTK File Resolution` block. Engineers invoking `/mtk-setup` or the subagent implementation path get the same behavior at roughly half the per-invocation context cost, and the deferred content only loads in the branch that needs it.

Skill behavior is intended to be byte-for-byte equivalent: no gate, ordering rule, abort condition, or safety contract moves. Only branch-local detail and verbatim output templates move.

## Success criteria

| ID | Criterion | Verification |
|---|---|---|
| SC1 | Toolkit validation passes after every batch | `bash scripts/validate-toolkit.sh` exits 0 and prints "Toolkit validation passed" |
| SC2 | Line budgets met: `setup-bootstrap/SKILL.md` ≤ 520, `setup-audit/SKILL.md` ≤ 340, `subagent-implementation/SKILL.md` ≤ 220 | `wc -l` on each file |
| SC3 | No content loss: every extracted section's distinctive heading/marker occurs exactly once across (SKILL.md + its companions) | grep loop per moved section (see Test manifest) reports 0 missing, 0 duplicated |
| SC4 | Cross-skill step coupling intact: the `^## STEP` heading sets of `setup-bootstrap` (18) and `setup-audit` (17) are unchanged | `diff <(git show HEAD:<file> \| grep '^## STEP') <(grep '^## STEP' <file>)` is empty for both |
| SC5 | Anatomy intact: `subagent-implementation/SKILL.md` retains `## Overview`, `## When To Use`, `## Workflow`, `## Verification` | `grep -c` finds all four headings |
| SC6 | Combined payload cut: sum of `wc -w` across the three SKILL.md files ≤ 11,500 words (pre-change: 18,057). *Amended 2026-07-13 from ≤10,500 via Phase 2.5 re-open, engineer-approved: the original ceiling assumed prose-density removal, but the authorized extractions were template-heavy (word-light) and the remaining inline text is the spec-designated stay-inline safety core. Actual: 11,457 (−36.5%).* | `wc -w` sum |
| SC7 | Missing-file branch defined: each of the three SKILL.md files states exactly once that an unresolvable companion file stops the affected step (never reconstructed from memory) | `grep -c "do not reconstruct"` = 1 per file |
| SC8 | Stale pointer fixed: `templates/workflows/subagent-implementation.workflow.js` comment cites the new companion path | `grep "subagent-implementer-prompt" templates/workflows/subagent-implementation.workflow.js` |

## Architecture and design

**Pattern (named precedent, not invented):** mirror `.claude/references/config-ingestion.md` and its pointer at `.claude/skills/setup-bootstrap/SKILL.md:302` — "…live in **`.claude/references/<name>.md`**. Read it now and follow it." Every new companion gets:

- YAML frontmatter: `name`, `description` (what + which step reads it), `globs: [".claude/skills/<skill>/**"]`, `alwaysApply: false` (validator-enforced on all `.claude/references/**/*.md`).
- A manifest entry keyed `references/<name>.md` shaped like the existing `config-ingestion.md` entry (`source`, `target`, `action: sync`, `applyTo: [".claude/skills/<skill>/**"]`, `description`).
- Pointer wording in SKILL.md is imperative and phase-anchored: "Read `.claude/references/<name>.md` (path per `## MTK File Resolution`) now and follow it" — for verbatim templates, add "do not paraphrase it from memory."
- One shared note per SKILL.md (near the MTK File Resolution block): if a companion file cannot be resolved, stop the affected step and report the missing file — do not reconstruct its content from memory. (Lesson `tasks/lessons.md` §"Skill prose that delegates verification to a script must define the engine-absent and engine-failed branches".)

**What moves (per the verified audit):**

`setup-bootstrap` → 4 companions (~382 net lines out; verifier-corrected from a 425 gross claim):
- `bootstrap-interview.md` — STEP 2.5 post-scan interview: question set, adaptive-ambiguity protocol, answer routing, `setup-answers.json` schema (~74 ln). Stub keeps the `--non-interactive` skip/reuse gates inline.
- `bootstrap-supporting-files.md` — STEP 4's once-consulted subsections: git pre-commit hook, CI staleness gate, skills/agents checklist, pre-commit-review-list selection, tasks dir, `.mtkignore`, `.claudeignore` block, analyzer config, companion plugin (.NET), recommended tooling, cross-agent mirrors; plus STEP 3.6 stack-reference pruning and the TypeScript package-manager note (~225 ln). Stubs keep the never-overwrite and ask-don't-assume decisions inline.
- `bootstrap-template-cache.md` — STEP 4.8 template-cache snapshot spec (~41 ln).
- `bootstrap-report.md` — the STEP 5 verbatim report template (~58 ln); pointer marked mandatory-read because ~15 earlier steps route report lines into it and `verify-claims.sh` consumes the output.

`setup-audit` → 4 companions (~415 net lines out; verifier-corrected from 443):
- `audit-rerun-migration.md` — Migration Path (pre-v7→v7+), Re-Run Merge Logic, RE-RUN PLAN block, extended stamp delta-field rules; read only when STEP -1 classifies migration/re-run (~68 ln).
- `audit-convention-scans.md` — the five STEP 2.5 scan blocks, `conventions.md` output template, `detected-tools.json` spec (~104 ln).
- `audit-output-templates.md` — architecture-principles skeleton, confidence format/legend blocks, `ambiguities.json` schema, provenance template, STEP 4 report block; read once at STEP 3 start (~166 ln).
- `audit-merge-mode.md` — the entire MERGE MODE branch; read only on `--merge` (~82 ln).
- Additionally: the three redundant STEP 3.7 subsections (rule tags, transient-state lint, terminology denylist, ~14 ln) collapse to one-line pointers at the existing `.claude/references/audit-grounding.md` §1/§2/§4 — no new file.

`subagent-implementation` → 2 companions (~156 net lines out):
- `subagent-implementer-prompt.md` — the fenced implementer prompt template plus the canonical batch-result JSON schema (deduping the copy embedded in manual Step 3.3, which keeps a one-line field summary) (~78 ln).
- `subagent-dynamic-workflow.md` — the dynamic-workflow path steps and the DOT decision graph (~80 ln). The `## Workflow` heading itself stays in SKILL.md (C0.3); only the graph body moves.

**What explicitly stays inline (verified load-bearing):** all STEP/Phase headings and their one-line summaries; setup-bootstrap's File Preservation Policy, STEP 3.5c secret-scan gate, STEP 4.5 nesting rules, the 120-line CLAUDE.md ceiling enforcement, and the closing `## IMPORTANT` block (deliberate end-of-context recency reinforcement of the v7.10.x preservation fix — not redundant); setup-audit's MANDATORY gates (verbatim-version, majority-verify, Rules for Generation, tag semantics, verify-claims/retry/seed-cache, AUDIT MODE invariants); subagent-implementation's threshold gate, ask-once model pick, retry/halt/inconclusive semantics, and the fork rule. In `subagent-dynamic-workflow.md`'s pointer, the preferred-path rule stays inline: when the Workflow tool is available the dynamic path MUST be used — choosing the manual path to avoid the Read is a scope violation.

## Requirements

### Ubiquitous
- The system shall keep every `^## STEP` heading of `setup-bootstrap/SKILL.md` and `setup-audit/SKILL.md` byte-identical to its pre-change text.
- The system shall list every new companion file in `.claude/manifest.json` `files` with `source`, `target`, `action`, and `description` fields.
- The system shall include YAML frontmatter with `name`, `description`, `globs`, and `alwaysApply: false` in every new companion file.

### Event-driven
- When a SKILL.md step reaches content that was extracted, the skill shall instruct an imperative Read of the named companion file resolved per the skill's `## MTK File Resolution` block.
- When a pointer targets a verbatim output template, the pointer shall include the instruction "do not paraphrase it from memory".

### State-driven
- While running from a plugin-cache install (`$CLAUDE_PLUGIN_ROOT` set), companion reads shall resolve under the `$CLAUDE_PLUGIN_ROOT` prefix.

### Unwanted behaviours
- If a companion file cannot be resolved at read time, then the skill shall stop the affected step and report the missing file path.
- If moving a section would remove a MANDATORY gate, an abort condition, or a step-ordering rule from SKILL.md, then the implementer shall leave that section inline and record the deviation in the batch report.

## Change manifest

| Path | Action | Purpose |
|---|---|---|
| `.claude/skills/setup-bootstrap/SKILL.md` | modify | Replace 4 section groups with pointer stubs; add missing-file note |
| `.claude/skills/setup-audit/SKILL.md` | modify | Replace 4 section groups + 3 redundant STEP 3.7 subsections with pointers; add missing-file note |
| `.claude/skills/subagent-implementation/SKILL.md` | modify | Replace prompt template + dynamic-path/graph with pointers; add missing-file note |
| `.claude/references/bootstrap-interview.md` | create | STEP 2.5 interview protocol |
| `.claude/references/bootstrap-supporting-files.md` | create | STEP 4 supporting-file subsections + STEP 3.6 pruning |
| `.claude/references/bootstrap-template-cache.md` | create | STEP 4.8 snapshot spec |
| `.claude/references/bootstrap-report.md` | create | STEP 5 report template |
| `.claude/references/audit-rerun-migration.md` | create | Migration + re-run merge logic |
| `.claude/references/audit-convention-scans.md` | create | STEP 2.5 scans + conventions/detected-tools templates |
| `.claude/references/audit-output-templates.md` | create | Principles skeleton + report/provenance/ambiguities templates |
| `.claude/references/audit-merge-mode.md` | create | MERGE MODE branch |
| `.claude/references/subagent-implementer-prompt.md` | create | Implementer prompt template + batch-result schema |
| `.claude/references/subagent-dynamic-workflow.md` | create | Dynamic-workflow path + decision graph |
| `.claude/manifest.json` | modify | 10 new `references/*` entries (C0.2) |
| `templates/workflows/subagent-implementation.workflow.js` | modify | Update the line-25 comment pointer to the new companion path |
| `CHANGELOG.md` | modify | Release-notes entry (at release, with the C0.1 three-file version bump and `checksums.sha256` regen per S4.11) |

No new dependencies.

## Test manifest

This is a markdown/bash toolkit — the structural test suite is `scripts/validate-toolkit.sh` (covers SC1 and, via its existing checks, manifest sync, references frontmatter, skill line caps, description budgets). Behavioral coverage for setup-bootstrap remains `evals/setup-bootstrap/*.md` (unchanged — skill behavior is preserved, not extended). SC2–SC8 are verified by the explicit commands in the Success criteria table, run per batch. **Waiver (+C #16):** no new test files; every changed property is asserted by validate-toolkit.sh or a listed one-line command, and the change adds no new behavior to test.

## Implementation batches

1. **subagent-implementation** (smallest; proves the pattern): create 2 companions, edit SKILL.md, add 2 manifest entries, fix workflow.js comment. Checkpoint: SC1, SC2 (≤220), SC3, SC5, SC7, SC8.
2. **setup-audit**: create 4 companions, edit SKILL.md (incl. audit-grounding.md pointer collapse), add 4 manifest entries. Checkpoint: SC1, SC2 (≤340), SC3, SC4, SC7.
3. **setup-bootstrap** (largest; carries safety contracts): create 4 companions, edit SKILL.md, add 4 manifest entries. Checkpoint: SC1, SC2 (≤520), SC3, SC4, SC6, SC7; then full sweep of all criteria + CHANGELOG entry.

Each batch is a single revertible commit; rollback is `git revert` of that commit (no migrations, no state).

## Risks and assumptions

**Assumptions**
- The companion frontmatter + manifest-entry + pointer pattern is as described `[VERIFIED:.claude/references/config-ingestion.md]` `[VERIFIED:.claude/skills/setup-bootstrap/SKILL.md]`.
- Validator caps and references-frontmatter enforcement are as cited `[VERIFIED:scripts/validate-toolkit.sh]`.
- Item 2 of the token-optimization plan is deferred, unimplemented, and unclaimed by any newer spec `[VERIFIED:docs/plans/2026-07-03-token-optimization.md]`.
- No hook, script, eval, or test greps SKILL.md content that moves; the only content-coupled consumer is the comment in `templates/workflows/subagent-implementation.workflow.js` `[VERIFIED:templates/workflows/subagent-implementation.workflow.js]`.

**Risks**
- *Model skips the Read and improvises* (highest consequence for `bootstrap-report.md`, whose output `verify-claims.sh` consumes). Mitigation: imperative mandatory-read wording + the SC7 missing-file stop rule.
- *Plugin-cache installs fail to resolve bare relative paths.* Mitigation: every pointer routes through `## MTK File Resolution` (state-driven requirement).
- *Cross-skill step coupling breaks* (`setup-refresh` re-runs setup-audit "STEP 0.5 through STEP 3.7"; setup-bootstrap cites setup-audit STEP numbers). Mitigation: SC4 byte-stable STEP headings.
- *Preferred-path inversion* — a lazy orchestrator picks the manual path to avoid reading `subagent-dynamic-workflow.md`. Mitigation: the inline fork rule states the dynamic path is mandatory when the Workflow tool is available.
- *Audit line counts are ±5 approximations*; a section may prove load-bearing during implementation. Mitigation: SC2 targets carry slack, and the second Unwanted-behaviour requirement licenses leaving a section inline with a reported deviation.
- *Release-time misses* — version bump is a three-file operation (`manifest.json`, `plugin.json`, `marketplace.json`; recurring lesson) and `checksums.sha256` must be regenerated last (S4.11).
- trap: per-skill `references/` subdirectories (proposed by the audit agents) — rejected; see Rejected alternatives.

Dirty-worktree: none — `git status --porcelain` was empty at spec time.

## Rejected alternatives

- **Per-skill `.claude/skills/<skill>/references/` subdirs** (the audit's original proposal): invents a second companion-file convention; loses the validator's `.claude/references/**` frontmatter enforcement and the known manifest shape; the shared-references pattern already exists with seven precedents.
- **Raising the validator line caps**: treats the symptom; S2.26 says the budget is the ceiling, not the target.
- **Extracting `implement/SKILL.md` too**: audit found only ~60 extractable lines; the rest is dense but load-bearing orchestration control flow, and its `MTK_AUTO_PROCEED` precondition list is a human-approval gate that must stay inline. Out of scope.
- **Dynamic context injection (S2.18) instead of Read pointers**: injection suits runtime state (branch, diff stats), not multi-hundred-line branch-local payloads; S2.26 prescribes reference files for those.

## Constitution Check

- **C0.1** — release-time only: version bump touches all three manifests (marketplace.json included, per the recurring lesson in `tasks/lessons.md`).
- **C0.2** — every created file gets a `.claude/manifest.json` entry in the same batch; validator enforces disk↔manifest sync.
- **C0.3** — anatomy preserved: subagent-implementation keeps all four required sections; setup-bootstrap/setup-audit remain phase-structured with their `## STEP` headings intact (SC4/SC5).
- **C0.4** — every new companion carries a `---` frontmatter block.
- **C0.8** — `validate-toolkit.sh` runs at every batch checkpoint (SC1).
- **S2.26** — the mandate for this change: SKILL.md as navigation layer.
- **S2.10/S2.11** — companions load at the phase that needs them, never front-loaded.
- **S2.9** — substantial skill modification follows `writing-skills` (pointer wording pressure-checked against the "skips the Read" rationalization).
- **S4.11** — `checksums.sha256` regenerated as the last change in the release commit.

## Prior Work Check

**Query 1 — search_prior_work.** The read-on-demand companion pattern already exists (5 "Read it now" pointers in setup-bootstrap; 7 companion files in `.claude/references/`) — **reused, not reimplemented**. No existing file covers the sections being extracted (no name collisions; `monorepo-bootstrap.md`/`bootstrap-customization.md` contain none of the STEP 2.5/STEP 4 content). Prior slimming work (spec 2026-05-29, setup-bootstrap 1000→831) and token-optimization Item 2 (deferred) are the direct ancestors of this spec.

**Query 2 — get_constraints.** flag: version bump = three files (`tasks/lessons.md` 2026-04-23 + v7.17 recurrence) — folded into Constitution Check C0.1. flag: delegated reads must define absent/failed branches (`tasks/lessons.md` §skill-prose-delegation) — folded into SC7 and the Unwanted-behaviour requirements. block: none. architecture-principles.md absent (constraints-unavailable for that source; Critical Rules digest used instead).

**Query 3 — get_risk_profile.** All touched paths are **shared** toolkit surface (skills + manifest distributed to every install); no regulated or app-boundary paths. `security_impact: none` matches the highest category. Phase 4 review: compliance-reviewer + the standard review lanes; no extra regulated-path reviewer required.

**Verdict: PASS** (two flag-level constraints, both folded into the spec).
