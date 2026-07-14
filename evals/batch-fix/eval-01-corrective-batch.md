---
category: positive
skill: batch-fix
signal: must-batch-not-implement
---

# Five independent nits across five files, no new contract

## Scenario

A PR review left five unrelated findings, each a small fix in its own file:

1. A missing null guard in `OrderService.cs`.
2. A wrong log level (`Info` → `Warning`) in `PaymentClient.cs`.
3. A typo in a user-facing string in `Messages.resx`.
4. A stale `<PackageReference>` version comment in `Api.csproj`.
5. An off-by-one in a date-range helper in `DateRange.cs` (behavioral).

None introduce a new public contract, endpoint, entity, or slice. The findings
are independent — no ordering between them. Five files means this is past
`fix`'s 1-3 file scope, but it is not a feature.

## Prompt

```prompt
Apply these 5 review findings: null guard in OrderService, log level in
PaymentClient, the resx typo, the csproj version comment, and the off-by-one in
DateRange. Active tech stack: dotnet.
```

## Expected Signals

- Routes to / runs `batch-fix`, **not** `implement` (no full spec, no
  `docs/plans/` plan file, no JSON sidecar) and **not** `fix` (>3 files).
- Enumerates the five findings as an independent numbered list and writes a
  short findings spec stub + `tasks/todo.md`.
- Presents **one** approval gate on the list before editing any file.
- Executes the findings **inline** (no subagent-per-batch).
- Writes a failing-first test for finding #5 (behavioral, off-by-one); treats
  #1-#4 proportionally (#3/#4 are mechanical → no TDD).
- Proportional review: `pre-commit-review` over the whole diff; does not spin up
  `architecture-reviewer` (no boundary crossed).
- Verifies with a fresh build + targeted tests before reporting done.

## Grading Rubric

- **PASS** — batch-fix lane used; findings enumerated; one gate; inline; behavioral
  finding gets a test; proportional review + fresh verification; nothing escalated
  (nothing needed it).
- **PARTIAL** — correct lane and gate, but misses the failing-first test on the
  behavioral finding, or over-reviews a mechanical batch, or skips verification.
- **FAIL** — runs the full `implement` apparatus (spec + plan + Phase 2.5 + subagents),
  OR treats it as a single `fix` and quietly edits 5 files, OR skips the approval gate.
