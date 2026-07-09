# Spec: Approval Seal + Executable Lesson Contracts

- **Status:** draft (awaiting Phase 2.5 approval)
- **Date:** 2026-07-07
- **Slug:** approval-seal-and-lesson-contracts
- **Scope:** new-feature (backward-compatible)
- **security_impact:** requires-audit-trail
- **Origin:** Competitive scan of trending Claude Code toolkits (last 30 days). Two borrows, both grep-verified as absent in MTK today.

## Summary

Two borrows from the competitive scan, both about making approval and captured
knowledge *checkable* rather than advisory:

1. **Approval seal** (from `VisionForge-OU/foreman` hash-sealed approval +
   `Seppelllo/hashgate` "approve a state, not an intention"). MTK's Phase 2.5
   human approval is currently a soft state — nothing binds the *bytes* that were
   approved. Editing an approved spec/plan silently keeps the approval. This adds
   a SHA-256 seal over the approved artifact bodies, recorded on the workflow
   artifact at the moment the human approves, and re-checked later.

2. **Executable lesson contract** (from `Forsy-AI/agent-apprenticeship`
   `runtime_training` schema). MTK lessons are freeform prose — advisory and
   un-checkable. This adds an OPTIONAL, backward-compatible contract shape
   (`output_contract`, `prefinal_verification_checklist`, `confidence`,
   `source_evidence_refs`) to the learnings schema, plus a well-formedness lint
   in `mtk-doctor`.

Both features stop short of their heaviest form this pass (see Rejected
alternatives): the seal enforces via MTK's existing advisory + evidence-gate
layers rather than a new blocking PreToolUse gate; the lesson contract ships as
schema + lint, not a runner.

## Success Criteria

| ID | Description | Verification | Evidence channel | Observable |
|---|---|---|---|---|
| SC1 | `workflow-artifact.sh seal <uuid> <files...>` records a combined SHA-256 + file list on the artifact | new bats-style test in `tests/pressure-tests/approval-seal.md` walked manually + `seal` then `verify-seal` returns 0 | script-output | `verify-seal` exits 0 immediately after `seal` |
| SC2 | Editing any sealed artifact makes `verify-seal` report a mismatch with both hashes | manual pressure-test scenario | script-output | `verify-seal` exits non-zero and prints `sealed=<h1> current=<h2>` after an edit |
| SC3 | `spec-approval-trigger.sh` emits an advisory re-queue (exit 0) when an edit lands on a stale-sealed artifact | pressure test | script-output | hook exits 0 and queues `planning-and-task-breakdown` with reason naming the stale seal |
| SC4 | `verification-before-completion` refuses a "done" claim while a seal is stale | pressure test scenario in the skill's test | script-output | documented block step present; scenario shows completion refused until re-seal |
| SC5 | A lesson with a well-formed contract passes `mtk-doctor`; a malformed one is reported | `bash scripts/mtk-doctor.sh` on fixtures | cli-stdout | doctor prints PASS for well-formed, WARN naming the malformed `check_id`/field |
| SC6 | Existing prose lessons (no contract fields) still validate and render unchanged | `bash scripts/learnings.sh regen-markdown` + `mtk-doctor` | cli-stdout | zero new warnings on the current `tasks/lessons.md` |
| SC7 | `bash scripts/validate-toolkit.sh` passes with the new files registered | validate | script-output | prints "Toolkit validation passed" |

## Architecture and Design

### Feature 1 — Approval seal (Hybrid enforcement, WF-artifact binding) `[ASSUMED]`

- **Binding:** a combined SHA-256 over the byte-bodies of the approved spec
  (`docs/specs/<slug>.md`), plan (`docs/plans/<slug>.md`), and `tasks/todo.md`,
  stored on `.mtk/workflows/<uuid>` under `results.approval_seal = { hash,
  files[], sealed_at }`. The workflow artifact is where the human Phase 2.5
  approval already lives, so the seal and the approval are one record.
- **New subcommands in `scripts/workflow-artifact.sh`:**
  - `seal <uuid> <path...>` — compute the combined hash over the given files (in
    a stable order), store the seal, print the hash.
  - `verify-seal <uuid>` — recompute over the recorded file list; exit 0 on
    match, non-zero on mismatch, printing `sealed=<h1> current=<h2>` and the
    changed paths.
- **Creation point (no self-approval):** `implement` Phase 2.5 calls `seal`
  **only** on the human's `AskUserQuestion` approval, immediately after
  `workflow-artifact.sh gate ... plan_trust_gate pass`. The hash is derived by
  the script from disk, so the agent cannot forge a seal for a different body.
  Full "human types the hash" (hashgate) is a non-goal this pass.
- **Advisory half:** `hooks/spec-approval-trigger.sh` (PostToolUse Edit|Write)
  broadens its path match to `docs/specs/*.md`, `docs/plans/*.md`, and
  `tasks/todo.md`; when an edit lands on a file covered by an active seal, it
  runs `verify-seal`; on mismatch it re-queues the approval suggestion and notes
  the stale seal. Stays exit 0 (tier-2 advisory, S3.13).
- **Blocking half:** `verification-before-completion` adds a step that runs
  `verify-seal` before accepting a completion claim; a stale seal blocks "done"
  until the artifacts are re-approved and re-sealed.

### Feature 2 — Executable lesson contract (schema + lint) `[ASSUMED]`

- **Schema:** extend `.claude/references/learnings-schema.md` with four OPTIONAL
  fields (all absent-by-default, no migration of existing lessons):
  - `output_contract` — object, e.g. `{ required_files:[], json_fields:[] }`
  - `prefinal_verification_checklist` — array of `{ check_id, description,
    verification_method, blocking }`
  - `confidence` — enum `low|medium|high`
  - `source_evidence_refs` — array of strings (provenance)
- **Engine:** `scripts/learnings.sh add` accepts `--output-contract`,
  `--prefinal-checklist`, `--confidence`, `--source-evidence-refs`; stores them;
  `regen-markdown` renders a `Contract` subsection when present (via
  `mtk_guarded_write`, S3.16). Prose-only lessons render exactly as before.
- **Lint:** `scripts/mtk-doctor.sh` gains a lesson-contract check: for any lesson
  declaring contract fields, verify checklist entries carry the required keys and
  `confidence` is in-enum; report malformed entries (WARN, never FAIL — the
  feature is optional).
- **Surfacing:** `golden-path-capture` and `promote-lesson` document when to
  populate the contract (promotion to team asset is the natural point).

## Security and Compliance Impact

`security_impact: requires-audit-trail`. Feature 1 strengthens the approval
evidence trail: the seal + the stale-detection log make "these exact bytes were
approved" tamper-evident, which is directly relevant to the finance domain
(auditable approvals). No auth, secrets, PII, or IAM surface is touched. No new
external dependency (SHA-256 via the coreutils baseline / `shasum`; S3.3).

## Requirements

### Ubiquitous
- The system shall store the approval seal as a combined SHA-256 over the recorded file list on the workflow artifact.
- The system shall treat all four lesson contract fields as optional, leaving lessons that omit them valid and unchanged.

### Event-driven
- When the engineer approves at the Phase 2.5 gate, the system shall record an approval seal over the spec, plan, and todo bodies.
- When `regen-markdown` runs on a lesson that declares contract fields, the system shall render a Contract subsection for that lesson.

### State-driven
- While an approval seal is recorded for a workflow, the system shall recompute and compare it before accepting a completion claim.

### Unwanted behaviours
- If an edit lands on a file covered by an active approval seal, then the system shall re-queue the approval suggestion and record the stale seal with both hashes.
- If a completion claim is made while the approval seal is stale, then the system shall refuse the claim until the artifacts are re-approved and re-sealed.
- If a lesson declares a `prefinal_verification_checklist` entry missing a required key, then `mtk-doctor` shall report that entry as malformed.

## Change Manifest

| # | Path | Action | Purpose |
|---|---|---|---|
| 1 | `scripts/workflow-artifact.sh` | modify | add `seal` + `verify-seal` subcommands |
| 2 | `.claude/skills/implement/SKILL.md` | modify | Phase 2.5 calls `seal` on human approval |
| 3 | `.claude/skills/spec-driven-development/SKILL.md` | modify | document the seal (one paragraph) |
| 4 | `hooks/spec-approval-trigger.sh` | modify | stale-seal detection + broadened path match; advisory re-queue |
| 5 | `.claude/skills/verification-before-completion/SKILL.md` | modify | blocking seal-check step before completion |
| 6 | `tests/pressure-tests/approval-seal.md` | create | adversarial scenarios (SC1–SC4) |
| 7 | `.claude/references/learnings-schema.md` | modify | four optional contract fields |
| 8 | `scripts/learnings.sh` | modify | accept/store/render contract fields |
| 9 | `.claude/skills/golden-path-capture/SKILL.md` | modify | document optional contract |
| 10 | `.claude/skills/promote-lesson/SKILL.md` | modify | document contract at promotion |
| 11 | `scripts/mtk-doctor.sh` | modify | lesson-contract well-formedness lint |
| 12 | `tests/pressure-tests/lesson-contract.md` | create | adversarial scenarios (SC5–SC6) |
| 13 | `.claude/manifest.json` | modify | register #6, #12; version 7.25.0 |
| 14 | `.claude-plugin/plugin.json` | modify | version 7.25.0 |
| 15 | `.claude-plugin/marketplace.json` | modify | version 7.25.0 |
| 16 | `CHANGELOG.md` | modify | 7.25.0 entry |
| 17 | `scripts/validate-toolkit.sh` | modify | register new pressure tests / structural check (S3.10) if needed |
| 18 | `checksums.sha256` | modify | regenerate LAST (S4.11) |

## Test Manifest

| Path | Covers |
|---|---|
| `tests/pressure-tests/approval-seal.md` | SC1, SC2, SC3, SC4 |
| `tests/pressure-tests/lesson-contract.md` | SC5, SC6 |
| `bash scripts/validate-toolkit.sh` | SC7 |
| `bash scripts/run-fixtures.sh && bash scripts/run-evals.sh` | regression (no behavior change to router) |

## Implementation Batches

- **B1 — Seal engine + creation point.** `workflow-artifact.sh` `seal`/`verify-seal`; `implement` Phase 2.5 wiring; one-paragraph note in `spec-driven-development`. Checkpoint: `seal` then `verify-seal` round-trips (SC1).
- **B2 — Seal enforcement + test.** `spec-approval-trigger.sh` stale detection (advisory, broadened paths); `verification-before-completion` blocking step; `tests/pressure-tests/approval-seal.md`. Checkpoint: SC2–SC4 scenarios pass.
- **B3 — Lesson schema + engine.** `learnings-schema.md` optional fields; `learnings.sh` flags/store/render. Checkpoint: prose lessons unchanged (SC6), a contract lesson renders a Contract subsection.
- **B4 — Lesson surfacing + lint + test.** `golden-path-capture` + `promote-lesson` docs; `mtk-doctor` lint; `tests/pressure-tests/lesson-contract.md`. Checkpoint: SC5.
- **B5 — Release chores.** manifest entries + version 7.25.0 ×3; CHANGELOG; validate-toolkit; rebuild derived indexes; regenerate `checksums.sha256` LAST. Checkpoint: SC7 (`validate-toolkit` green).

## Constitution Check

- **C0.1 / S4.6** version bumped in manifest.json + plugin.json + marketplace.json together (B5).
- **C0.2** new files (#6, #12) added to manifest.json `files` (B5).
- **C0.3 / S2.2** no new skills created; existing skills keep their anatomy. Pressure tests satisfy **S2.7** (verification/approval-affecting change).
- **C0.5 / S3.1–S3.2** modified/any new bash keeps `set -euo pipefail` and executable bit.
- **C0.8 / S3.9** `validate-toolkit.sh` must print "Toolkit validation passed" before completion.
- **S3.13–S3.15** the advisory half stays tier-2 (exit 0, respects `MTK_HOOKS_TIER2`).
- **S3.16** `learnings.sh regen-markdown` continues to write `tasks/lessons.md` via `mtk_guarded_write`.
- **S4.11** `checksums.sha256` regenerated as the final change.

## Rejected Alternatives

- **Blocking PreToolUse seal gate (full hashgate).** Rejected this pass: fail-closed edit-blocking is the least MTK-native option; hybrid (advisory + evidence-gate) gets most of the benefit with MTK's existing enforcement layers. `trap:` revisit if stale approvals still ship.
- **Human-types-the-hash approval.** Rejected: heavier UX than MTK's `AskUserQuestion` gate warrants; deterministic script-side hashing already prevents forging a seal for different bytes.
- **Lesson checklist runner / verify-completion wiring (Feature 2 heavy forms).** Deferred: schema + lint is the backward-compatible MVP; a `lesson-verify.sh` runner and evidence-gate wiring are a clean follow-up once the shape proves useful.
- **Two separate specs.** Kept as one spec; batches B1–B2 (Feature 1) and B3–B4 (Feature 2) are independent and ship as separate commits (S4.4).

## Risks and Assumptions

- `[ASSUMED]` Enforcement = **Hybrid** (advisory + evidence-gate blocking). Unanswered at the ambiguity gate; recommended default. Surfaces at Phase 2.5.
- `[ASSUMED]` Binding = **WF artifact over spec+plan+todo**. Unanswered; recommended default.
- `[ASSUMED]` Lesson depth = **schema + doctor lint** (no runner). Unanswered; recommended default; keeps scope minimal.
- `[VERIFIED:scripts/workflow-artifact.sh]` `seal`/`verify-seal` do not exist today (subcommand grep: only init/event/set/list/gate).
- `[VERIFIED:scripts/learnings.sh]` contract flags do not exist today.
- Risk: broadening `spec-approval-trigger.sh` to `docs/plans/*.md` + `tasks/todo.md` could raise advisory-hint frequency — mitigated by firing only when an *active seal* covers the edited file.
- Risk (dirty-worktree): current branch is `docs/readme-landing-refresh`; implementation must branch off `main` (S4.1/S4.2) — recorded as a Phase 3 precondition.

## Open Questions

None blocking — the three `[ASSUMED]` decisions are surfaced at the Phase 2.5 gate for confirm/revise.
