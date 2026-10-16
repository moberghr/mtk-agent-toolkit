---
name: code-review-and-quality
description: Review a PR or diff outside implement — runs the compliance, silent-failure, test and architecture lanes from implement-review-lanes.md with full lane accounting.
type: skill
effort: max
context: fork
user-invocable: false
---

# Code Review And Quality

## Overview

Adversarial review of a PR or diff that did not come through `implement` (implement Phase 4 reads the reference directly). This skill is read-only except for workflow-artifact recording.

## When To Use

- Reviewing a PR, branch, or local diff before merge, outside the implement loop

## Workflow

1. Get the diff (`gh pr diff <n>` or `git diff <base>...HEAD`) and the changed-file set; exclude files that were already dirty before the change.
2. Read `.claude/references/implement-review-lanes.md` and pick lanes from its **Outside implement** column: `compliance-reviewer` always; `silent-failure-hunter` when the trigger regex matches; `test-reviewer` when public behavior changed; `architecture-reviewer` on a new slice, boundary, or cross-project call.
3. Dispatch them per **Dispatch rules** (inline when the Agent tool is unavailable) with deterministic `candidates.json` collected first, run `review-coverage.sh` on each lane result, run the **Defect-class sweep** on every confirmed finding, and apply **Lane accounting** before aggregating. `finding-verifier` is implement-only (HIGH/MAX).
4. Emit the findings table and fenced JSON per `.claude/references/review-finding-schema.md`, with the lane roster. On a full-lane PASS, write the push receipt: `bash scripts/review-receipt.sh write --lanes <csv> --rigor <level> --verdict PASS`.

## Verification

- [ ] Every dispatched lane is accounted for; the verdict is not PASS while any lane abstained or returned nothing
- [ ] Findings follow the schema; an empty `findings[]` carries `below_threshold_rationale`
