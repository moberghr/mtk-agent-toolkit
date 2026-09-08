# MTK Token & Speed Optimization Plan — 2026-09-07

**Source:** performance audit of v7.34.0 on `fix/killed-batch-recovery-and-receipt-timing`,
cross-checked against the 2026-09-07 field run (8 batches, 3h43 active, 3.6M subagent
tokens, 14 real review findings). Every number below was measured on this checkout with
`wc -c`, a two-hop reference trace, and a hook timing loop; the memory entry
`mtk-perf-audit-2026-09-07` holds the raw figures.

**Method.** Each workstream names the files and line anchors it touches, the measurement
that proves it landed, and what must not change. Workstreams are independent unless the
Sequencing section says otherwise. Nothing here changes what the loop checks — only how
much text it carries and how many turns it spends doing so.

---

## Baseline (what we are optimizing against)

| Metric | Today | Target after plan |
|---|---|---|
| Implement-chain text reachable in 2 hops | 374k chars / 45 files (~94k tok) | ≤ 230k chars (−40%) |
| Boilerplate share of chain-skill text | 27% (59k chars) | ≤ 10% |
| `## MTK File Resolution` copies | 9 × 2.3k chars | 1 reference + one-line pointer |
| Implementer fixed preamble (dotnet repo) | ~63k chars per batch | ≤ 25k chars |
| Compliance-reviewer fixed preamble | ~107k chars per lane | ≤ 40k chars |
| `dotnet build` / `dotnet test` output | unbounded | quiet + wrapper always |
| Batch execution | sequential | independent waves in parallel |
| Prescribed `workflow-artifact.sh` calls per run | ~65 (each a model turn) | ≤ 30 |
| Hook latency | 40–170 ms, parallel | unchanged (not a bottleneck) |
| Skill descriptions | 6,803 / 7,000 chars | unchanged |

**What earned keep (do not touch):** hook set and wiring; description budget; the rigor
score; the approval gate; the two-stage review; the killed-batch recovery and tier
fallback just added. The plan removes text and turns, never checks.

---

## WS1 — Bound build/test output by default (biggest token lever)

**Why first.** Fixed preambles are ~7% of the 3.6M tokens; the rest is code reads and tool
output. On a .NET repo, build and test logs dominate that. Today the bound is a judgment
call the implementer makes before seeing the output, so it is skipped.

**Changes**

1. `.claude/skills/tech-stack-dotnet/SKILL.md:26-28` — build/test commands become:
   - Compile: `dotnet build --nologo -v q`
   - Test (batch): `dotnet test --nologo -v q --no-build --filter <project>`
   - Test (full): `dotnet test --nologo -v q --no-build`
   - Add one line: "Batch checkpoints run these through
     `bash scripts/mtk-verify-run.sh --label <batch-id>-<step> -- <cmd>`; the wrapper's
     bounded tail is the evidence, the log path is the receipt."
   - Note `--no-build` requires the build step to have run in the same checkpoint; say so.
2. `.claude/skills/tech-stack-python/SKILL.md:29-30` — `pytest -q --tb=short`
   (`-p no:cacheprovider` optional); full run `pytest -q --tb=short`.
3. `.claude/skills/tech-stack-typescript/SKILL.md:52-54` — `tsc --noEmit --pretty false`;
   vitest/jest with `--reporter=dot` / `--silent` where the runner supports it.
4. `.claude/references/subagent-implementer-prompt.md:60-66` — replace the conditional
   "When output will exceed ~30 lines" with an unconditional rule: every build/test
   command in VERIFY runs through `mtk-verify-run.sh`; raw output never goes in
   `build.evidence` / `tests.evidence`.
5. `hooks/compress-monitor.sh` — keep as is; with WS1 the nag should stop firing on
   checkpoints. Use that as the acceptance signal (see below).

**Acceptance**

- Run the dotnet fixture (or a client repo) checkpoint before/after; compare tool-result
  chars for build + test. Target: ≥ 80% reduction on a green build, ≥ 60% on a red one
  (the wrapper keeps the failing tail).
- `compress-monitor` emits zero tips across a full implement run on a green path.
- `bash scripts/validate-toolkit.sh` passes (tech-stack section list unchanged).

**Risk.** `--no-build` on a test step whose build was skipped fails with a clear error;
the prompt must pair them. `-v q` hides analyzer warnings the compliance reviewer may want
— the reviewer lane already reads the diff, not the build log, so this is acceptable;
note it in the reference.

---

## WS2 — Per-run context pack for subagents

**Why.** Each implementer re-reads CLAUDE.md + tech-stack skill + all coding guidelines
(~63k chars here); each compliance reviewer re-reads ~107k chars. Across 8 implementers
and ~5 reviewer lanes that is ~260k tokens of the same text, plus the wall-clock of
reading it.

**Design.** The orchestrator writes `.mtk/workflows/<uuid>/context-pack.md` once, after
Phase 2 (the change manifest is now known), containing:

1. Build/test/format commands for the resolved stack (from the tech-stack skill's
   `## Build & Test Commands` and `## Format Command`, post-WS1).
2. CLAUDE.md `## Critical Rules` verbatim; the rest of CLAUDE.md summarized to headings.
3. Coding-guideline sections whose headings match the change manifest's file kinds
   (handlers → MediatR slice section; EF entities → EF Core checklist; tests → testing
   supplement). Selection is by a small heading-keyword table in the pack script, not by
   the model.
4. `architecture-principles.md` `[EXTRACTED]` lines only.
5. Applicable `tasks/lessons.md` entries (already selected in Phase 0; paste them).

**Changes**

- New `scripts/build-context-pack.sh <uuid> <sidecar.json>` — pure bash/python3, writes the
  pack, prints its path and size. Add to `.claude/manifest.json`.
- `.claude/skills/implement/SKILL.md` Phase 2 (after plan write) — one step: build the pack,
  record `results.context_pack=<path>` on the artifact.
- `.claude/references/subagent-implementer-prompt.md:22-25` — "Read first" becomes the pack
  path plus `.claude/references/dotnet/coding-guidelines.md` **only for sections the pack
  names**. Keep "read before editing; match local patterns".
- `.claude/agents/compliance-reviewer.md:52-63` and the other five agents — replace the
  nine-item read list with: the pack, `review-finding-schema.md`, and the spec/sidecar.
  Keep the agent's own checklist and the rules glob (`.claude/rules/*.md`) for the
  compliance lane only, since it cites rule IDs.
- `.claude/references/workflow-artifact-schema.md` — add `results.context_pack`.
- `.claude/references/review-finding-schema.md` (16k chars, read by 9 skills) — split the
  schema (≤ 4k) from the worked examples; agents read the schema, the examples move to
  `review-finding-examples.md` loaded only by `writing-skills`.

**Acceptance**

- Pack size ≤ 25k chars on this repo with a dotnet manifest; ≤ 40k for the compliance lane
  (pack + schema + rules).
- Field run: per-implementer input tokens drop ≥ 40% versus the 2026-09-07 baseline (the
  receipt's per-batch timing section plus the harness token report).
- Reviewer findings on the eval fixtures in `evals/code-review-and-quality/` unchanged
  (no lost coverage).

**Risk.** A too-aggressive section filter drops a guideline the batch needed. Mitigation:
the pack always includes the guideline table of contents with paths, so an implementer can
pull a section on demand, and `pre-commit-review-list.md` still runs in full.

---

## WS3 — Parallel batch waves

**Why.** 8 sequential batches took 90 min (40% of active time). `depends` exists in the
sidecar schema and the dynamic-workflow path already knows how to run waves; the planning
skill never requires the field to be filled, so it is always `[]` and everything serializes.

**Changes**

- `.claude/skills/planning-and-task-breakdown/SKILL.md:44,51,91` — make `depends`
  mandatory and machine-checkable: every batch lists the batch ids it depends on; a batch
  with an empty list must state `"depends_rationale": "independent: no shared files"`.
  Add a rule: two batches that share a file in `files` must have a dependency edge.
- `.claude/schemas/handoff.schema.json:107` — `depends` required; add `wave` (integer,
  derived) as optional output.
- `.claude/references/subagent-dynamic-workflow.md:72-77` — keep "correctness beats
  wall-clock" but change the default: compute waves from `depends`; run each wave with
  `parallel()`, waves in sequence. Cap wave width at 3 (env `MTK_BATCH_WAVE_MAX`, default 3)
  so a single run cannot fan out past the org spend guard.
- `.claude/skills/subagent-implementation/SKILL.md:193,212` — same rule; the manual
  Agent-loop path dispatches a wave in one message with multiple `Agent` calls (already the
  pattern in `docs/parallelism-patterns.md`).
- `plan-gap-reviewer` — add one check: a `depends` edge missing between two batches that
  touch the same file is `BLOCKING`.
- Drift micro-check after a wave: run once for the wave's union of files, not per batch.

**Acceptance**

- `evals/rigor/` fixture with 6 batches where 4 are independent: schedule produces 3 waves
  (2 / 3 / 1) and the eval passes.
- Field run: batch-phase wall-clock drops ≥ 30% for a plan with ≥ 2 independent batches.
- A plan where every batch shares a file still serializes (regression fixture).

**Risk.** Two concurrent implementers editing a shared `.csproj` or DI registration file.
The shared-file rule above forces an edge; add `Program.cs`/`*.csproj`/`DependencyInjection*`
to a "serialize-if-touched" list in the planning skill.

---

## WS4 — Shrink the orchestrator's instruction load (model-era cleanup)

**Why.** 59k chars (27%) of chain-skill text is Overview / When To Use / Rules / Common
Rationalizations / Red Flags / Verification / MTK File Resolution. The rationalization and
red-flag tables were written to stop earlier models skipping steps; on current models they
dilute the steps that matter. The file-resolution block is copied into 9 skills.

**Changes**

1. **File resolution once.** New `.claude/references/mtk-file-resolution.md` (the current
   block). The `/mtk` router (`.claude/skills/mtk/SKILL.md` Execution section) resolves the
   root once and states it as `MTK_ROOT=<path>` before loading the target. The 9 skills
   (`batch-fix fix implement mtk-setup pre-commit-review setup-audit setup-converge
   setup-refresh setup-bootstrap`) replace the block with two lines: "Resolve per
   `mtk-file-resolution.md` if `MTK_ROOT` is not already stated." Saves ~13k chars.
2. **Rationalizations and red flags to one reference.** New
   `.claude/references/workflow-rationalizations.md` holding the union of the 26 `## Common
   Rationalizations` and 31 `## Red Flags` tables, grouped by skill. Each skill keeps at most
   3 skill-specific rows inline; everything else is a pointer. `implement` loads the reference
   only at rigor MAX or when Phase 7 records a repeated ceremony reduction. Saves ~25k chars.
3. **Verification sections shrink to checklists.** Validator S2.2 requires `## Verification`
   on workflow skills, so keep the heading but cap the body at 8 checkbox lines; move any
   prose into the Workflow step it verifies. Add the cap to `scripts/validate-toolkit.sh`
   (warn at first, fail one release later). Saves ~10k chars.
4. **Overview / When To Use for non-entry skills.** 41 of 45 skills are
   `user-invocable: false`; their Overview repeats the frontmatter description. Cap Overview
   at 3 lines and When To Use at 5 bullets for those. Saves ~12k chars.
5. **Line density.** `subagent-implementation` averages 115 chars/line; the 500-line budget
   is not the constraint. Add a char-budget check to the validator: 20k chars for workflow
   skills, 35k for phase-structured/entry-point skills, warn-only in this release.
6. **`.claude/skills/context-engineering/SKILL.md:133-168`** — rewrite Context Budget
   Tracking and Proactive Reset for the 1M default: drop "60–120 lines per skill" and "prune
   at 5+ skills" (the loop itself loads 15); keep the rot-symptom override; make the reset
   boundary the `context-budget` hook figure, not a fixed 40%.
7. **`.claude/references/model-routing.md:47-55,82-84`** — bind the slots to the current
   generation explicitly (fast → Haiku 4.5, default → Sonnet 5, strong → Opus 5) and add one
   row: Fable 5.1 is an optional `strong` binding for the compliance and security lanes
   only, never for implementers. Update `scripts/mtk-doctor.sh` and
   `scripts/validate-toolkit.sh` model-name checks to accept the new aliases.

**Acceptance**

- Two-hop reachable text from `implement` ≤ 230k chars (re-run the trace script from the
  audit).
- `bash scripts/validate-toolkit.sh` passes with the new char-budget and Verification-cap
  checks in warn mode.
- Pressure tests in `tests/pressure-tests/` still pass by reading (the adversarial
  scenarios are unchanged; only the inline tables moved).
- Evals in `evals/` unchanged in outcome.

**Risk.** Moving rationalization tables out of a skill can lower rigor on a model that
needed them. Mitigation: they stay one Read away and `implement` loads them at MAX; if an
eval regresses on Sonnet, restore that skill's table inline and record it.

---

## WS5 — Fewer ceremony turns

**Why.** The chain prescribes ~65 `workflow-artifact.sh` invocations per run; each is a
separate Bash tool call, so a model turn with a full cache read. `list` also takes ~600 ms
because it spawns python3 twelve times.

**Changes**

- `.claude/skills/implement/SKILL.md` (15 calls) and `.claude/references/orchestration-gates.md`
  (6), `implement-preflight.md` (5), `implement-approval-gate.md` (4) — state one rule at
  the top of `workflow-artifacts/SKILL.md` and reference it: "Artifact updates ride in the
  same Bash call as the action they record" (`<checkpoint cmd> && "$WFA" set … && "$WFA"
  event …`). Rewrite each prescribed call site to show the combined form.
- `scripts/workflow-artifact.sh` — add `batch` subcommand: one invocation, several
  `set`/`event`/`gate` ops from stdin (JSON lines). Rewrite `cmd_list` (line 211) to a
  single python3 pass.
- `phase_started` + first `set` of a phase collapse into one call.

**Acceptance**

- Count of prescribed `"$WFA"` / `workflow-artifact.sh` occurrences across the chain ≤ 30.
- `workflow-artifact.sh list` ≤ 100 ms with 46 artifacts.
- Receipt timing section still populates (`phase_started`/`agent_dispatched` pairs intact).

---

## WS6 — Timing evidence on the dynamic-workflow path

**Why.** The new receipt timing section needs `agent_dispatched` / `agent_returned` pairs.
The manual Agent-loop path emits them (`subagent-implementation/SKILL.md:91`); the
dynamic-workflow path does not, so a Workflow-tool run yields a receipt with empty
per-batch timing — and WS3 makes that path the common one.

**Changes**

- `.claude/references/subagent-dynamic-workflow.md` — the generated script's `agent()` wrapper
  records `dispatched_at` / `returned_at` in each batch result; after the run returns, the
  orchestrator replays them as `agent_dispatched` / `agent_returned` events (one `batch`
  call from WS5) before the drift check.
- `.claude/references/implement-archive-receipt.md` — note that replayed timestamps are
  accepted and labelled `source: workflow-replay`.

**Acceptance.** A dynamic-workflow eval run produces a receipt whose per-batch table has no
`not recorded` cell.

---

## Sequencing

```
WS1 (bound output)        ── standalone, ship first: 3 files, highest token win
WS5 (fewer turns)         ── standalone; WS6 depends on its `batch` subcommand
WS6 (timing replay)       ── after WS5
WS3 (parallel waves)      ── after WS6 so parallel runs are measurable
WS2 (context pack)        ── standalone; measure with WS1 already in
WS4 (instruction shrink)  ── last; touches the most files, easiest to bisect if an eval moves
```

Suggested releases: **7.35.0** = WS1 + WS5 + WS6 (small, mechanical, measurable);
**7.36.0** = WS3 + WS2 (needs one field run each to confirm); **7.37.0** = WS4 (breadth).
Each release re-runs the audit measurements and records them in CHANGELOG under a
"Measured" line so the next audit has a baseline.

## Out of scope

- Hook changes — measured and not a bottleneck.
- Description budget — 41 non-invocable skills still need descriptions for `Skill` routing.
- Prompt-cache tuning of the orchestrator prompt — the harness owns cache boundaries; the
  only lever we have is less text, which WS4 covers.
- Model pricing decisions — the plan names tiers, not prices.

---

## Status — 2026-09-07 (branch `perf/token-and-speed-optimization`)

All six workstreams landed in one branch rather than three releases; measured against the
same commands as the audit:

| Metric | Baseline | Now | Target | Met |
|---|---|---|---|---|
| Implement-chain skill text | 213,933 chars | 206,414 chars | −40% | no — see WARN list |
| `## MTK File Resolution` full copies | 9 | 0 | 1 reference | yes |
| Implementer fixed preamble (dotnet) | ~63k | 19,516 chars | ≤ 25k | yes |
| Compliance-reviewer fixed preamble | ~107k | 55,490 chars | ≤ 40k | no (rules dir is 22k of it; the lane must cite rule IDs) |
| `review-finding-schema.md` | 16,017 | 4,601 chars | ≤ 4.5k | ~ (101 over) |
| Build/test output | unbounded | quiet flags + wrapper always | — | yes |
| Batch execution | sequential | waves from `depends`, cap 3 | — | yes (unit-tested; field run pending) |
| Standalone bookkeeping turns in chain | 47 | 28 | ≤ 30 | yes |
| `workflow-artifact.sh list` | ~600 ms | 66 ms | ≤ 100 ms | yes |
| Dynamic-workflow timing in receipt | empty | replayed with `--ts` | populated | yes (eval pending) |

Open follow-ups: char-budget and section-cap WARNs become `fail` next release once
setup-bootstrap / batch-fix / subagent-implementation are split; one field run to confirm the
pack loses no reviewer coverage and to measure wave wall-clock; `evals/subagent-implementation`
to be run through the grader.

**Added after the plan (2026-09-08):** spawn-context probes showed the harness system prompt,
not MTK's prompt, dominates subagent startup (~37k tokens general-purpose, ~54k for an MTK
reviewer, on this machine). Root cause on MTK's side: agents declared `allowed-tools`, which
Claude Code ignores on agent definitions; `tools:` is now set on all six and enforced by the
validator. Follow-ups: an `mtk:implementer` agent type with a fixed tool set (verify the
Workflow runtime's `agent()` accepts a custom type first), drop the CLAUDE.md section from the
context pack (CLAUDE.md is auto-injected into every subagent), cap the spec excerpt in the
implementer prompt.

