---
name: spec-driven-development
description: Use when the task is a new feature, breaking change, multi-file change, or any work where approval should happen before coding begins.
type: skill
license: MIT
compatibility:
  - claude-code
  - codex
trigger: new-feature|breaking-change|multi-file-change|approval-required
skip_when: typo-fix|config-update|single-line-change
user-invocable: false
---

# Spec-Driven Development

## Overview

Write the implementation spec before writing code. The spec is the shared source of truth between the engineer, the command flow, and the reviewers. Code without a spec is guessing.

## When To Use

- New endpoints, handlers, routes, or views
- Database changes or migrations
- Multi-file work
- Breaking changes
- Any task where approval should happen before coding
- Any task likely to take more than a short focused session

### When NOT To Use

- Typo fixes
- One-line config updates with no behavior impact
- Small bug fixes that clearly stay within quick-fix scope

## Workflow

1. Read standards in this order:
   - `CLAUDE.md`
   - The coding guidelines from the active tech stack skill's `## Reference Files`
   - `.claude/references/security-checklist.md`
   - `.claude/references/testing-patterns.md`
   - `.claude/references/architecture-principles.md` if present
   - Relevant lessons from `tasks/lessons.md`
2. Resolve the lessons path using the main worktree when in a worktree.
3. Surface assumptions before planning. State what you believe about runtime, architecture, storage, auth, and boundaries. Do not silently fill in major gaps.
4. Classify scope:
   - `internal-refactoring`
   - `new-feature`
   - `breaking-change`
5. Read 2-3 nearby files that represent the local pattern to follow.
6. Ask clarifying questions only for ambiguities that would materially change the plan.
7. Produce a spec with these sections:
   - Summary
   - Success criteria
   - Architecture and design
   - Security and compliance impact
   - Change manifest
   - Test manifest
   - Implementation batches
   - Risks and assumptions
   - Open questions
8. Run an elegance check: reduce file count, new abstractions, and moving parts if a simpler design exists.
9. Persist the spec to disk:
   - Create `docs/specs/` if it does not exist.
   - Save the human-readable spec to `docs/specs/YYYY-MM-DD-<feature-slug>.md` using the current date and a kebab-case slug of the feature name.
   - **Also emit a machine-parseable sidecar** at `docs/specs/YYYY-MM-DD-<feature-slug>.json` with the schema in the next section. This sidecar drives `spec-drift-detection` after implementation.
   - This enables session recovery, human review outside chat, and reuse across sessions.
   - Add `docs/specs/` to `.gitignore` if not already present — specs are working artifacts, not committed deliverables.
10. Always stop for approval before implementation. When invoked from `/mtk:implement`, this means handing control back to the command's Phase 2.5 approval gate (which uses `AskUserQuestion`). Do not silently continue to implementation.

## Machine-Parseable Manifest (JSON Sidecar)

Every spec is accompanied by a structured manifest at
`docs/specs/<date>-<slug>.json`. This is the source of truth for drift detection.

```json
{
  "slug": "feature-slug",
  "date": "YYYY-MM-DD",
  "scope": "new-feature | internal-refactoring | breaking-change",
  "change_manifest": [
    { "path": "src/X.cs", "action": "create | modify | delete", "purpose": "one-line why" }
  ],
  "public_contracts": [
    { "kind": "endpoint | handler | method | event | cli-flag",
      "signature": "POST /api/orders or Namespace.Class.Method(...) or OrderCreated event",
      "change": "new | modified | removed" }
  ],
  "success_criteria": [
    { "id": "SC1", "description": "testable outcome", "verification": "name of test or command" }
  ],
  "test_manifest": [
    { "path": "tests/X_Tests.cs", "covers": ["SC1", "SC2"] }
  ],
  "out_of_scope": ["explicit non-goals"],
  "security_impact": "none | requires-audit-trail | new-auth-path | secrets-change | pii-exposure | iam-change",
  "assumptions": ["..."],
  "risks": ["..."]
}
```

Rules:

- Every entry in `change_manifest` must be intended — do not pre-populate
  with files you "might" touch.
- `public_contracts` is what callers or external consumers will see change.
  Internal helpers don't count.
- `security_impact` is NOT `none` if the diff touches auth, payments,
  audit trails, secrets, PII paths, or IAM configuration. Be honest here;
  `spec-drift-detection` will catch understated impact and block.
- Keep the JSON in sync with the markdown spec. They are one artifact in
  two shapes, not independent documents.

## Required Outputs

- A clear scope classification
- A file-level change manifest covering every file to be touched
- A test manifest covering every behavioral change
- A batch breakdown with build/test checkpoints
- A list of assumptions and unresolved risks
- Concrete, testable success criteria
- A JSON sidecar manifest at `docs/specs/<date>-<slug>.json` matching the
  Machine-Parseable Manifest schema (drives drift detection)

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "The requirement is obvious, I can just start" | Obvious to whom? Specs exist to flush out wrong assumptions before they become code. |
| "I'll write the spec after I implement it" | That is documentation, not specification. The value is in deciding before coding. |
| "This is small enough to skip approval" | Small multi-file work still creates risk. Approval gates exist to catch bad direction early. |
| "I already know which files will change" | You have a hypothesis. Read neighboring files and prove the manifest. |

## Red Flags

- Planning after code has already started
- Files likely to be touched but omitted from the change manifest
- Missing tests for new public behavior
- Approval gate skipped or merged into implementation
- Success criteria written as vague aspirations instead of verifiable outcomes

## Verification

- [ ] The plan can be handed to another engineer with no missing context
- [ ] Every file and every test file appears in the manifest
- [ ] Success criteria are specific and testable
- [ ] Assumptions are explicit
- [ ] The scope still matches the original request
- [ ] The JSON sidecar exists at `docs/specs/<date>-<slug>.json` and matches
      the markdown spec's change_manifest, test_manifest, success_criteria,
      and security_impact
- [ ] `security_impact` honestly reflects touched trust boundaries (not `none`
      if auth / payments / audit / secrets / PII / IAM are involved)
