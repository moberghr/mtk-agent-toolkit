---
description: Single source for code review — lane sets per rigor, dispatch rules, the silent-failure trigger regex, the defect-class sweep, lane accounting and ABSTAINED; read by implement Phase 4 and code-review-and-quality
globs: []
alwaysApply: false
---
# Review Lanes — sets, dispatch, accounting

Read when `implement` reaches Phase 4, or when `code-review-and-quality` reviews a PR or diff
outside implement. Findings follow `.claude/references/review-finding-schema.md`.

## Lane sets

Stage 1 (`compliance-reviewer`, sonnet at high effort) always runs first: spec compliance, security, architecture
and coding standards against the sealed spec. Fix **Critical** findings before Stage 2. Stage 2
lanes run on sonnet, in parallel (one message, several `Agent` calls).

| Lane | LIGHT / STANDARD | HIGH | MAX | Outside implement |
|---|---|---|---|---|
| `compliance-reviewer` | always | always | always | always |
| `silent-failure-hunter` | trigger regex | trigger regex | always | trigger regex |
| `test-reviewer` | public behavior changed | always | always | public behavior changed |
| `architecture-reviewer` | new slice/boundary/handler/cross-project | same condition | always | same condition |
| `context-miner` | skip | always | always | on request |

`finding-verifier` is a **verify stage** after the lanes, not a lane (see Review protocol).

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
  `bash "$MTK_ROOT/hooks/ci-status.sh"` names failed checks to focus on.
- **Findings:** apply the schema's False-Positive Exclusion List before scoring confidence; surface
  findings at or above the `.claude/review-config.json` threshold (default 80); an empty
  `findings[]` needs `below_threshold_rationale` saying what was checked. Output a markdown table
  plus the fenced JSON result. A mismatch between the behavioral diff and the code is critical.

## Review protocol

Run in this order. `$MTK_ROOT` is the root stated per `mtk-file-resolution.md`; every script below runs as `bash "$MTK_ROOT/<path>"`. `$CHANGED` is the path of a file holding the changed-file list (one path per line, dirty baseline excluded). `$WFA`, `$RUN` (`.mtk/workflows/$MTK_WF_UUID`) and `$MTK_WF_UUID` exist only in implement; outside it (`code-review-and-quality`) there is no workflow artifact, so skip steps 2 and 4's persistence, keep candidates and coverage in a scratch dir, and say in the report that the review is not bound to the tree.

1. **Candidates.** Before dispatch, collect deterministic hits on the changed lines into `$RUN/review/candidates.json` (array shape in `review-finding-schema.md`; `candidate_id` `C001`…, `source` = `linter`, `secret-scan` or `analyzer`). Sources:
   - `bash "$MTK_ROOT/hooks/pre-commit-linters.sh" --range <base>...HEAD` (or `--head` for uncommitted work) → JSON `findings[]` of `file`, `line`, `rule`, `rationale`.
   - `bash "$MTK_ROOT/scripts/secret-scan.sh" <changed files>` → `<file>:<line>: <pattern>` lines, exit 1 on a hit (exit 0 = clean; any other code = crashed).
   - build/lint output piped through `bash "$MTK_ROOT/hooks/parse-build-diagnostics.sh" [--format <msbuild|ruff|tsc|biome>] --file <output>` → JSON `findings[]`; keep only those on changed lines.

   Pass the path to `compliance-reviewer`, which must dispose of every candidate (`candidates_disposed`). No hits ⇒ no file. **A collector that crashed or is absent is not "no hits"**: record it and tell the compliance lane the candidate set is partial.
2. **Bind to the tree (implement).** `"$WFA" review-input "$MTK_WF_UUID" --record` at dispatch; `--check` before aggregating. Exit 0 ⇒ bound. Exit 1 (tree changed) ⇒ re-dispatch the lanes whose files changed, **without** showing them earlier findings, and record again. Exit 2 or any other code ⇒ the review is **unbound**: record it, report `NEEDS_HUMAN_REVIEW`, never claim a bound PASS.
3. **Coverage.** For each lane result: `bash "$MTK_ROOT/scripts/review-coverage.sh" <lane-result.json> "$CHANGED" [--candidates "$RUN/review/candidates.json"]`. Exit 0 ⇒ complete. Exit 1 ⇒ lane `ABSTAINED` with `abstention.reason` `incomplete: <what is missing>`. Exit 2, 127 or any other non-zero ⇒ `NO_RESPONSE` / `ABSTAINED incomplete: coverage engine unavailable`; never `PASS`.
4. **Verify (HIGH/MAX only).** Dispatch `finding-verifier` once per top-level directory group of the merged findings (one message, parallel). Apply its verdicts as the schema table says: `rejected` and `immaterial` leave remediation, `pre_existing` goes to the follow-up list. A verifier that fails, returns nothing or returns `ABSTAINED` ⇒ that group is `unverified` and its findings stay as raised.
5. **Iterate.** See Iteration cap.
6. **Receipt.** Qualifies only when all hold: overall `PASS` with every lane accounted (by-policy abstentions allowed, no other `ABSTAINED` / `NO_RESPONSE`); the reviewed tree is committed (the script refuses a dirty tracked tree); then, in implement, `review-input --check` exit 0 run **after** that commit (committing exactly the reviewed tree still reads unchanged; anything edited after review does not). Order: commit → `--check` → `bash "$MTK_ROOT/scripts/review-receipt.sh" write --lanes <csv of lanes that ran> --rigor <level> --verdict PASS`. When the engineer owns the commit, hand them the `--check` and `write` commands to run after committing. Never on `NEEDS_CHANGES` or `NEEDS_HUMAN_REVIEW`. A non-zero exit from the script ⇒ tell the engineer: the verdict stands but no receipt was recorded; never claim one.

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
- `context-miner` records `search_status: ran | unavailable` per source (git log, lessons store, `gh`).
  Git log or the lessons store `unavailable` ⇒ `ABSTAINED` with `abstention.reason`
  `could-not-search: <source>`. `gh` unavailable is noted in the roster, not an abstention.
- A `context-miner` run over a change with no usable history (only new files, a squashed import)
  whose required sources `ran` is a valid empty `PASS` with a `below_threshold_rationale`, not an
  abstention; record it as `PASS` and say "no history" in the roster.
- Report the roster: lanes dispatched, outcome of each, reason for any abstention. Corroboration
  outranks volume: a finding raised independently by two lanes ranks above one raised loudly once.

## Iteration cap

Drive the fix loop through `"$WFA" remediation "$MTK_WF_UUID" review` once per review iteration.
It returns `ESCALATE` when iterations reach `MTK_MAX_REMEDIATION_ITERS` (default 3), else
`CONTINUE`. Pass the merged findings JSON array (post-verify, remediation-relevant only) as
`--findings <file>`, or the open count as `--open N`: the tracker reconciles finding UIDs as
`FIXED` / `STILL_OPEN` / `NEW` and `ESCALATE`s with reason `stalled` when a non-zero open count
stops falling, before the cap. On `ESCALATE`, stop and hand to a human with the iteration count and the open
findings (`.claude/references/orchestration-gates.md` → `failure_stop_gate`).
