---
name: spec-drift-detection
description: Use after implementation completes and before review begins, to verify the actual change matches the approved spec — files touched, public contracts added, security impact, and declared scope.
license: MIT
compatibility:
  - claude-code
  - codex
trigger: post-implementation|pre-review|spec-approved|ship-gate
skip_when: no-spec|typo-fix|single-line-change
---

# Spec-Drift Detection

## Overview

Verify that the implementation actually delivered what the spec promised —
nothing more, nothing less. Drift between spec and implementation is a
compliance risk in regulated environments: it means the approval gate at
Phase 2.5 did not cover the final code. Detect divergence before review.

## When To Use

- After implementation batches complete
- Before handing to `compliance-reviewer` in Phase 4
- When a spec manifest exists at `docs/specs/<date>-<slug>.json`
- Whenever a change was supposed to follow a spec-driven flow and the reviewer
  wants to confirm the scope was honored

### When NOT To Use

- Quick fixes that ran through `/mtk:fix` without a spec
- Typo fixes and config updates
- Sessions where no spec manifest was ever produced

## Workflow

1. **Locate the spec manifest.**
   - Default: the latest `docs/specs/*.json` on the current branch.
   - Override: accept an explicit path if the engineer supplies one.
   - If no manifest exists, **STOP** and report `BLOCKED — no spec manifest
     found; drift cannot be checked. Either generate one via
     `spec-driven-development` or confirm this change is quick-fix scope.`

2. **Load the manifest schema fields:**
   - `scope` — classification string
   - `change_manifest` — array of `{ path, action, purpose }`
   - `public_contracts` — array of `{ kind, signature, change }`
   - `success_criteria` — array of `{ id, description, verification }`
   - `out_of_scope` — array of strings
   - `security_impact` — enum string

3. **Collect actual change data:**
   - `git diff --name-status HEAD` (or against branch base) for touched files
   - For each touched source file, grep for added/modified public contracts
     (controller routes, handler classes, exported functions, etc., per active
     tech stack)
   - Security-surface files touched — any path matching auth, payments,
     audit, secrets, infra (use path-scoped globs when Phase 4 lands)

4. **Compare and emit findings** per
   `.claude/references/review-finding-schema.md`, with `source: "drift"`:

   | Axis | Finding criteria | Confidence band |
   |------|------------------|-----------------|
   | File-list match | File touched that is NOT in change_manifest | 95–100 (deterministic) |
   | File-list match | File declared in change_manifest that was NOT touched | 95–100 |
   | Public contract | Signature added that is NOT in public_contracts | 85–95 |
   | Public contract | Contract declared but not implemented | 90–100 |
   | Security impact | `security_impact: none` but auth/payments/audit files touched | 95+ |
   | Out-of-scope | Declared out_of_scope item that appears to be implemented | 80–90 |
   | Success criteria | Criterion has no mapped test in the diff | 80 |

5. **Emit the schema-conformant output** (markdown table + fenced JSON).
   Drift findings mix with any AI review findings downstream. `severity`
   mapping:
   - Missing/extra file → `critical` (spec approval didn't cover this code)
   - Contract divergence → `critical`
   - Security-impact understated → `critical`
   - Success criterion unmapped → `warning`
   - Out-of-scope hit → `warning`

6. **Verdict:**
   - Any `critical` drift → `NEEDS_CHANGES`. The engineer either fixes the
     implementation to match the spec, or re-opens the spec, amends it, and
     re-runs through the Phase 2.5 approval gate.
   - No critical drift → `PASS`. Continue to Phase 4 review.

## Rules

- No drift check without a spec manifest. If the manifest is missing,
  escalate; do not fabricate one from the git diff.
- Drift findings are high-confidence by construction: they come from
  comparing two structured lists, not from judgment.
- The spec is the source of truth — do not rewrite it silently to match
  implementation. If the implementation is correct and the spec is wrong,
  stop and ask the engineer to amend the spec and re-approve.
- A clean `PASS` does not mean the code is good — only that it matches what
  was approved. Code quality still goes through `compliance-reviewer`.

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "The extra file was just a helper, it's basically in scope" | If it wasn't in the change_manifest, the approval gate did not cover it. Flag it. |
| "The missing file in the manifest was replaced by a better approach" | That is a scope decision. Surface it so the engineer can amend the spec or revert. |
| "security_impact was 'none' but this auth change is tiny" | If the diff touches auth, payments, or audit — even tiny — the security_impact field was wrong. Flag it. |
| "This drift is minor, I'll just fix it silently" | Silent drift is the exact compliance failure this skill exists to prevent. Emit the finding. |
| "The spec is outdated; the implementation is right" | Then amend the spec via `spec-driven-development`, re-approve, and re-run. Drift checks run against the current spec, not a hypothetical one. |

## Red Flags

- Drift check run without a spec manifest on disk
- Reviewer silently modifies the spec to match the implementation
- Critical drift downgraded to warning because "it's close enough"
- `security_impact` field ignored because the diff "looks small"
- Out-of-scope items marked as acceptable scope expansion without engineer
  confirmation

## Verification

- [ ] Spec manifest was loaded from disk, not reconstructed from memory
- [ ] Every touched file was compared against the manifest's change_manifest
- [ ] Public contracts added in the diff were compared against the manifest
- [ ] security_impact was verified against the actual files touched
- [ ] Findings follow `.claude/references/review-finding-schema.md` with
      `source: "drift"`
- [ ] Verdict matches the severity of the drift (critical → NEEDS_CHANGES)
- [ ] No silent spec edits were made to suppress drift findings
