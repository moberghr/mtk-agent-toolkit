---
description: Catalog of recurring AI-assisted coding failure modes — stable F-codes with severity and a one-line detection cue for reviewers
globs: ["**/*"]
alwaysApply: false
---

# AI Failure Modes Catalog

Recurring patterns where AI-assisted development produces incorrect or misleading output. Ids
`F1`–`F16` are stable: reviewers cite them in a finding's `failure_mode` field so patterns
aggregate across reviews. Severity maps to the review schema: **must-fix** → `critical`,
**should-fix** → `warning`, **worth-noting** → `suggestion`.

| Id | Name | Severity | Detection cue |
|---|---|---|---|
| F1 | Catch-all error swallowing | must-fix | A `catch`/`except` that neither rethrows nor takes a documented recovery action; a log-only catch without a stated intent to swallow. |
| F2 | Hardcoded-success returns | must-fix | A method returning a fixed literal (`true`, completed task, success DTO) for every input without doing the work — a stub unless marked `TODO` or a test double. |
| F3 | Hallucinated APIs or packages | must-fix | A call, type or package that is not in the dependency manifests or the installed version's surface. Check the local source, not memory. |
| F4 | Copy-from-similar drift | should-fix | A block that mirrors a neighbouring handler; check every domain constant, enum value and field name for having been carried over unchanged. |
| F5 | Defensive-guard bloat | worth-noting | Null/range guards or try/catch with no failure scenario in the current call chain; they hide the real invariant model. |
| F6 | Obvious-comment noise | worth-noting | Comments that restate the identifier; a surviving comment needs domain intent, an invariant, or a non-obvious constraint. |
| F7 | Mock-your-own-DTOs | should-fix | A test that builds its own expected output and never invokes the system under test. |
| F8 | Test deletion under pressure | must-fix | A deleted or skipped existing test (`[Skip]`, `it.skip`, `xit`) without a stated reason. |
| F9 | Fake fallback values | must-fix | An error path returning a domain-plausible default (0, empty list, null object) the caller cannot tell from success. |
| F10 | Dead-code accretion | worth-noting | Unreferenced private members, methods, imports or classes with no stated reason to keep them. |
| F11 | Import or namespace breakage | must-fix | An import/`using` that does not resolve in the current solution, or names a renamed or other-project namespace. |
| F12 | Docs drift | should-fix | A public signature changed while its doc comment, README snippet or OpenAPI text still describes the old contract. |
| F13 | Async-void misuse | must-fix | `async void` outside an event handler. |
| F14 | ConfigureAwait omission in library code | should-fix | An `await` without `.ConfigureAwait(false)` in `*.Infrastructure`, `*.Core` or `*.Shared` (application-layer code is exempt). |
| F15 | Frozen-replay / non-varying evidence | must-fix | Completion evidence that would not change if the change were reverted: cached results, a stale build artifact, a benchmark whose ground truth never re-ran. Evidence must be fresh, exercise the touched path, and be falsifiable. |
| F16 | Unverified prose claims | should-fix | README, changelog or sample text asserting behavior the code does not have, a sample never run, or a doc edit outside the declared scope. |

## Use

- Load during review at any rigor level (`implement-review-lanes.md`). Match the cue, then read the
  code — a cue is a reason to look, not a finding on its own.
- F1 and F9 are the `silent-failure-hunter` lane's core; F7 and F8 belong to `test-reviewer`;
  F15 is checked by `verification-before-completion` against its evidence table.
- A confirmed F-code finding triggers the defect-class sweep: grep for the same pattern elsewhere.
