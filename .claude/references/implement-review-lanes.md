---
description: Single source for code review — lane sets per rigor, dispatch rules, the silent-failure trigger regex, the defect-class sweep, lane accounting and ABSTAINED; read by implement Phase 4 and code-review-and-quality
globs: []
alwaysApply: false
---
# Review Lanes — sets, dispatch, accounting

Read when `implement` reaches Phase 4, or when `code-review-and-quality` reviews a PR or diff
outside implement. Findings follow `.claude/references/review-finding-schema.md`.

## Lane sets

Stage 1 (`compliance-reviewer`, opus) always runs first: spec compliance, security, architecture
and coding standards against the sealed spec. Fix **Critical** findings before Stage 2. Stage 2
lanes run on sonnet, in parallel (one message, several `Agent` calls).

| Lane | LIGHT / STANDARD | HIGH | MAX | Outside implement |
|---|---|---|---|---|
| `compliance-reviewer` | always | always | always | always |
| `silent-failure-hunter` | trigger regex | trigger regex | always | trigger regex |
| `test-reviewer` | public behavior changed | always | always | public behavior changed |
| `architecture-reviewer` | new slice/boundary/handler/cross-project | same condition | always | same condition |
| `context-miner` | skip | always | always | on request |

Size the set from the **current** rigor level — the one recomputed in Phase 3.5 if scope was
reduced. At HIGH, a change that adds or moves no module and crosses no boundary (a pure rename,
a frontmatter-only batch) skips `architecture-reviewer`.

**Silent-failure trigger.** Dispatch `silent-failure-hunter` alongside Stage 1 when `git diff`
matches any of `\b(catch|except|finally)\b`, `\.catch\(`, `\?\?`, `\|\|`, or adds
`// eslint-disable`, `# noqa`, `@ts-ignore`, `@ts-expect-error`, `Skip =`, `it\.skip`, `xit\(`.
It emits `category: "error-handling"`; merge and dedupe by `(file, line, rule)`.

## Dispatch rules

- **Inputs, same for every lane:** the context-pack path (`results.context_pack`, read instead of
  CLAUDE.md, the stack skill and the guideline files — pass the path, never the body); start
  caller/callee questions from the pack's `## Change map` and re-derive only where a symbol shows
  `+N more` or the extractor was unavailable; the spec and sidecar paths; the diff; the behavioral
  diff; the scope classification; the manifest summary. Each lane reads exactly the rule files the
pack's `## Applicable rules` lists (plus an unmatched one only when the diff touches its globs),
never all of `.claude/rules/`. Outside implement there is no pack: resolve
  the stack with `bash scripts/resolve-tech-stack.sh --check <changed paths>` and pass the stack
  skill's `## Reference Files` plus its `## ORM & Data Layer Guidance` and `## Framework Patterns`.
- **Scope to this run's files.** Hand each lane the changed-file set and exclude the pre-existing
  dirty baseline, or it attributes someone else's edits to this run.
- **A reviewer is a pass to perform, not a dispatch mechanism.** When the Agent tool is
  unavailable or forbidden, read the agent's `.md` and apply its checklist inline. That costs
  isolation, never coverage; the final report says which lanes ran inline.
- **Dependency surface.** A lane judging a call into a framework, SDK or package reads that
  dependency's real exception/return surface from local source before accepting the call as safe.
- **What every lane checks:** correctness, including stubs per `.claude/references/stub-detection.md`;
  security and compliance; architectural fit; test strength; performance risk. Cite an F-code from
  `.claude/references/ai-failure-modes.md` in `failure_mode` when a finding matches one. Load a
  domain supplement (e.g. `domain-finance.md`) when present. With CI runs available,
  `bash hooks/ci-status.sh` names failed checks to focus on.
- **Findings:** apply the schema's False-Positive Exclusion List before scoring confidence; surface
  findings at or above the `.claude/review-config.json` threshold (default 80); an empty
  `findings[]` needs `below_threshold_rationale` saying what was checked. Output a markdown table
  plus the fenced JSON result. A mismatch between the behavioral diff and the code is critical.

## Defect-class sweep

A confirmed finding is a sample, not the population. When a finding is **confirmed**, name the
*pattern* (not "this handler reads the cookie header" but "handlers that read a forbidden header
from an intercepted request"), grep the repo for it, and report each hit as **confirmed**,
**not-applicable** (with why) or **needs-check**. Fix what is in scope; record the rest as
follow-up findings with paths. A sweep that finds nothing is one line saying so. Sibling code with
passing tests is where this pays: passing tests are why nobody looked.

## Lane accounting and ABSTAINED

Account for every dispatched lane **before** aggregating findings. One outcome per lane: `PASS`,
`NEEDS_CHANGES`, `ABSTAINED`, or `NO_RESPONSE`.

- A lane that returns null, errors, times out, or emits unparseable output is `NO_RESPONSE`, which
  counts as `ABSTAINED`. **Silence is not assent** — the `Agent` tool returns null on terminal
  errors.
- **The review cannot pass while any lane is `ABSTAINED` or `NO_RESPONSE`;** the aggregate is
  `NEEDS_HUMAN_REVIEW`. Re-dispatch (recording both attempts) or escalate to a human.
- A skipped lane, or one run inline when it should have been forked, is recorded as `ABSTAINED`
  with the reason — never reported as a clean two-stage review that did not happen.
- **`ABSTAINED(by-policy)`** is the one abstention that does not block. When Phase 2.9 recorded
  `dispatch_capability=forbidden|unavailable`, a lane that could not be forked records
  `ABSTAINED (by-policy: <reason>; compensations C1-C3)` and Phase 4 may pass — **only if** the
  inline-MAX compensations were applied and named, and the report says which lanes ran inline.
  Without them it is an ordinary `ABSTAINED` and still blocks.
- A `context-miner` run over a change with no usable history (only new files, a squashed import)
  is a valid empty `PASS` with a `below_threshold_rationale`, not an abstention; record it as
  `PASS` and say "no history" in the roster.
- Report the roster: lanes dispatched, outcome of each, reason for any abstention. Corroboration
  outranks volume: a finding raised independently by two lanes ranks above one raised loudly once.

## Iteration cap

Drive the fix loop through `"$WFA" remediation "$MTK_WF_UUID" review` once per review iteration.
It returns `ESCALATE` when iterations reach `MTK_MAX_REMEDIATION_ITERS` (default 3), else
`CONTINUE`. On `ESCALATE`, stop and hand to a human with the iteration count and the open
findings (`.claude/references/orchestration-gates.md` → `failure_stop_gate`).
