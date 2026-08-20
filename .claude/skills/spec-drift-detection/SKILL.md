---
name: spec-drift-detection
description: Use after implementation completes and before review begins, to verify the actual change matches the approved spec — files touched, public contracts added, security impact, and declared scope.
type: skill
license: MIT
compatibility:
  - claude-code
  - codex
trigger: post-implementation|pre-review|spec-approved|ship-gate
skip_when: no-spec|typo-fix|single-line-change
user-invocable: false
effort: high
required-toolsets: [read-only]
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

- Quick fixes that ran through the fix workflow without a spec
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
   - **Preferred (deterministic):** run
     `bash scripts/validate-handoff.sh docs/specs/<date>-<slug>.json`
     to compute file-level and security-impact drift against the
     manifest. Treat its output as authoritative for those axes.
   - If the handoff has an `implement.actual_files` array, diff it
     against `change_manifest[].path` directly — no git invocation needed.
   - Otherwise, fall back to `git diff --name-status <base>...HEAD`.
   - For contract-level drift (not covered by the script): grep the diff
     for added/modified public contracts (controller routes, handler
     classes, exported functions, etc., per active tech stack).

3a. **EARS / ANT structural lint of the spec itself.** Run
   `bash scripts/lint-ears.sh <spec.md>` (the markdown spec next to the JSON
   sidecar). EARS / ANT violations on the spec count as drift of the spec
   from its own contract — emit one finding per violation with
   `source: "drift"`, `severity: "warning"`, `confidence: 100`,
   `rule: "EARS / ANT"`. They do not block on their own (warning, not
   critical), but they signal a spec that should be tightened before the
   next iteration. If `scripts/lint-ears.sh` is absent, skip with a one-line
   note in the output.

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
   | Ownership | Touched a slice/module not listed in the spec's declared ownership (cross-slice creep) | 80–90 |
   | Dependency shift | New package, SDK, or external service in the diff that was not declared in the spec's dependency intake | 90–100 |
   | Usage | Public contract removed/renamed but call-sites in other slices weren't updated | 85–95 |

   **Ownership.** Parse the spec's declared slice/module ownership (from the
   architecture-and-design section or `change_manifest[].path` prefixes) and
   compare against the slice prefixes of every touched file. Cross-slice
   touches without justification are drift.

   **Dependency shift.** Diff the lockfile / project file (`packages.lock.json`,
   `*.csproj <PackageReference>`, `requirements.txt`, `pyproject.toml`,
   `package.json` + `package-lock.json`, `pnpm-lock.yaml`, `Cargo.toml`) and
   list any added/upgraded dependencies. Cross-check against the spec's
   declared dependency intake (Claude-Ready checklist +C #6). Undeclared
   dependencies are drift — they should have triggered the security/license
   review gate during spec writing.

   **Usage.** For removed/renamed public contracts in `public_contracts`,
   grep the repo for remaining call-sites. Any unupdated call-site is a
   usage-drift critical finding.

   **Coverage.** For every `coverage_claims[]` entry in the sidecar, re-grep the
   write sites now that the code exists. A claim that one point covers several
   callers is drift the moment a caller bypasses it — and this is the drift class
   that leaves a feature passing every test while doing nothing for one of its
   paths. An entry with `verified: false`, an empty `write_sites`, or a newly
   added write site that does not route through the claimed point is a
   **critical** finding. An unenumerated coverage claim in the spec body is the
   same finding: the claim was never checkable.

   **Pre-authorised descopes.** Read `conditional_descopes[]`. An entry with
   `fired: true` is a legitimate scope *reduction* (item 4 below) — but only with
   `evidence` naming what made the condition true. `fired: true` without
   evidence is silent drift wearing the spec's authority, and is a critical
   finding. Conversely, work that quietly stopped matching the manifest while a
   matching descope sat unfired is an unrecorded reduction: flip it, evidence it,
   and re-score rigor.

   **Collateral churn.** Run `bash hooks/collateral-guard.sh --range <base>...HEAD
   --manifest docs/specs/<date>-<slug>.json`. Whitespace/EOL-only rewrites,
   undeclared generated files, and wholesale asset regeneration are not spec
   drift in the contract sense, but they land in the same commit and they hide
   the real diff from every reviewer downstream. Report the verdict; a finding
   here is a warning unless the collateral is a lockfile carrying an undeclared
   dependency, which the dependency axis already makes critical.

5. **Emit the schema-conformant output** (markdown table + fenced JSON).
   Drift findings mix with any AI review findings downstream. `severity`
   mapping:
   - Missing/extra file → `critical` (spec approval didn't cover this code)
   - Contract divergence → `critical`
   - Security-impact understated → `critical`
   - Success criterion unmapped → `warning`
   - Out-of-scope hit → `warning`
   - Ownership / cross-slice creep → `warning` (escalates to `critical` if
     the crossed slice is regulated — auth, payments, audit)
   - Dependency shift (undeclared) → `critical`
   - Usage drift (stale call-site after rename) → `critical`

6. **Verdict:**
   - Any `critical` drift → `NEEDS_CHANGES`. The engineer either fixes the
     implementation to match the spec, or re-opens the spec, amends it, and
     re-runs through the Phase 2.5 approval gate.
   - No critical drift → `PASS`. Continue to Phase 4 review. A clean PASS is
     the precondition for archiving the spec delta into its baseline
     (implement Phase 7.5, `scripts/spec-archive.sh`) — do **not** archive
     while any critical drift is open, or the baseline would record a state
     the code does not match. See `.claude/references/delta-spec-model.md`.

## Monorepo Ripple Check

After comparing the manifest, also run a cross-package ripple check on the change manifest. This catches "one-package change with many-package impact" surprises.

```bash
bash scripts/monorepo-ripple.sh $(git diff --name-only HEAD)
```

- Exits 0 on non-monorepo (no output) — no false positives.
- On a monorepo, emits lines `RIPPLE <pkg>: affects <downstream>`.
- Treat ≥1 ripple line as a **warning-level** drift finding (not blocking), unless the spec's `change_manifest` already lists the downstream packages — then it's expected and silent.

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

## Architecture Principle Drift (S1.15)

In addition to manifest drift, also compare the implementation against tagged
principles in `.claude/references/architecture-principles.md`. Severity is
determined by the principle's confidence tag:

| Tag | Contradicting change → |
|---|---|
| `[EXTRACTED]` | **block** (critical drift) — the principle was directly observed in code; violating it is a regression. |
| `[INFERRED:>=0.7]` | **flag** (medium drift) — likely-correct pattern; surface for engineer decision. |
| `[INFERRED:<0.7]` | **note** (low drift) — weak inference; mention but do not block. |
| `[AMBIGUOUS]` | **note** — sources disagree; surface both options. Do not block. |

If `architecture-principles.md` is missing or has no tags (legacy format),
skip principle drift and continue with manifest drift only — emit a one-line
note that principle drift was unavailable.

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` for the shared table. Drift-specific traps: "the extra file was just a helper, it's basically in scope" (if it wasn't in the change_manifest, the approval gate did not cover it — flag it), "security_impact was 'none' but this auth change is tiny" (if the diff touches auth, payments, or audit — even tiny — the field was wrong), and "this drift is minor, I'll just fix it silently" (silent drift is the exact compliance failure this skill exists to prevent — emit the finding).

## Red Flags

- Drift check run without a spec manifest on disk
- Reviewer silently modifies the spec to match the implementation
- Critical drift downgraded to warning because "it's close enough"
- `security_impact` field ignored because the diff "looks small"
- Out-of-scope items marked as acceptable scope expansion without engineer
  confirmation

## Gate

If the workflow artifact is active, drift findings flip the `phase_exit_gate` for the review phase. Critical drift → `phase_exit_gate fail` (triggers remediation). Spec amendment with engineer approval → re-evaluate `plan_trust_gate` from `pending`. See `.claude/references/orchestration-gates.md`.

## Verification

- [ ] Spec manifest was loaded from disk, not reconstructed from memory
- [ ] Every touched file was compared against the manifest's change_manifest
- [ ] Public contracts added in the diff were compared against the manifest
- [ ] security_impact was verified against the actual files touched
- [ ] Findings follow `.claude/references/review-finding-schema.md` with
      `source: "drift"`
- [ ] Verdict matches the severity of the drift (critical → NEEDS_CHANGES)
- [ ] No silent spec edits were made to suppress drift findings
- [ ] `bash scripts/lint-ears.sh` was run against the spec markdown (or
      explicitly skipped with a note when the script is unavailable)
- [ ] Ownership axis: every touched slice was compared against the spec's
      declared ownership; cross-slice creep was flagged
- [ ] Dependency axis: lockfile/project-file diff was inspected; undeclared
      additions were flagged as critical
- [ ] Usage axis: renamed/removed public contracts were grepped for
      remaining call-sites
- [ ] Coverage axis: every `coverage_claims[]` entry was re-grepped against the
      implemented code; unenumerated or bypassed claims were flagged critical
- [ ] Descope axis: every `conditional_descopes[]` entry that fired carries
      evidence, and no unrecorded reduction was left unflipped
- [ ] Collateral axis: `hooks/collateral-guard.sh` was run and its verdict
      reported
