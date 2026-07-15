---
name: implement
description: Full feature implementation loop orchestrating planning, batching, verification, and review skills
type: skill
user-invocable: false
---

# MTK Implement — Full Feature Loop

## MTK File Resolution

MTK skills and shared references live either in the project (local install) or the plugin cache (marketplace install). Resolve once:

1. If `$CLAUDE_PLUGIN_ROOT` is set, prefix `.claude/skills/` and `.claude/references/` reads with it.
2. Otherwise, if `.claude/skills/context-engineering/SKILL.md` exists locally → project-relative paths work as-is.
3. Otherwise, fall back to `find ~/.claude/plugins -maxdepth 8 -name "SKILL.md" -path "*/mtk/*/context-engineering/*" -type f 2>/dev/null | sort -V | tail -1 | sed 's|/.claude/skills/context-engineering/SKILL.md||'`. If empty, MTK skills are unavailable — warn the engineer and proceed with `CLAUDE.md` only.

Always project-relative (never prefixed): `CLAUDE.md`, `.claude/tech-stack`, `.claude/rules/`, `tasks/`, `docs/`, `.claude/references/architecture-principles.md`, `.claude/references/pre-commit-review-list.md`, `.mtk/` (workflow state). Resolve skills and scripts from the same root: a split (skills from a local dev checkout, scripts from the plugin cache) risks version drift — anchor both the same way.

---

You are a senior engineer building serious software. This skill is the user-facing entry point for substantial work. Language and framework specifics come from the active tech stack skill.

The skill itself is intentionally thin. The source of truth for workflow behavior is the skill layer:

- `.claude/skills/context-engineering/SKILL.md`
- `.claude/skills/workflow-artifacts/SKILL.md`
- `.claude/skills/spec-driven-development/SKILL.md`
- `.claude/skills/planning-and-task-breakdown/SKILL.md`
- `.claude/skills/incremental-implementation/SKILL.md`
- `.claude/skills/test-driven-development/SKILL.md`
- `.claude/skills/source-driven-development/SKILL.md`
- `.claude/skills/code-review-and-quality/SKILL.md`
- `.claude/skills/security-and-hardening/SKILL.md`
- `.claude/skills/verification-before-completion/SKILL.md`
- `.claude/skills/spec-drift-detection/SKILL.md`
- `.claude/skills/brainstorming/SKILL.md`
- `.claude/skills/code-simplification/SKILL.md`
- `.claude/skills/tech-stack-{stack}/SKILL.md` — loaded based on `.claude/tech-stack`

## Phase 0: Load Context (Progressive Disclosure)

Before doing anything else:

0. Init or resume a workflow artifact (`.claude/skills/workflow-artifacts/SKILL.md`).
   - Run `scripts/workflow-artifact.sh list`.
   - If a single active `BUILD` workflow exists for this feature, ask via `AskUserQuestion` whether to resume that uuid or start a new one.
   - Otherwise: `MTK_WF_UUID=$(scripts/workflow-artifact.sh init BUILD --goal "<one-line user goal>")` and remember the uuid for the rest of the session.
   - Emit `phase_started phase-0` immediately after init/resume.
1. Follow `.claude/skills/context-engineering/SKILL.md`.
2. Read `CLAUDE.md`. If missing, stop and tell the engineer to run `/mtk-setup`.
3. **Load the active tech stack:** read `.claude/tech-stack` (plain text, single word like `dotnet` or `python`). Then read `.claude/skills/tech-stack-{stack}/SKILL.md`. This provides build/test commands, ORM guidance, framework patterns, and reference file paths used throughout the workflow. If `.claude/tech-stack` is missing, do not halt: run `bash scripts/setup-detect.sh --json` (read-only) to infer the stack, and load the matching `tech-stack-{stack}` skill if one exists for the inferred primary. If inference is empty or no matching skill exists, warn the engineer that the tech stack is unconfigured (suggest `/mtk-setup`) and proceed with `CLAUDE.md`-only context.
4. Read only the references needed for the **current phase**:
   - **Always (Phase 0):** the coding guidelines from the tech stack's `## Reference Files`, `.claude/references/architecture-principles.md` if present
   - **Defer to Phase 1 (spec):** `.claude/references/security-checklist.md` (only if scope touches auth/financial/infra), `.claude/references/testing-patterns.md`
   - **Defer to Phase 3 (implementation):** `.claude/references/performance-checklist.md`, plus stack-specific references from the tech stack's `## Reference Files` (e.g., ORM checklist, framework patterns)
   - **Defer to Phase 4 (review):** `.claude/references/pre-commit-review-list.md` if present
   - **Path-scoped auto-load (any phase):** references in `.claude/manifest.json` may declare an `applyTo` glob array. When the current phase has files in scope (from `change_manifest` or `git diff --name-only HEAD`), activate references whose globs match any touched file. Skip references whose globs match nothing for this task. See `context-engineering` skill for the match procedure.
5. Resolve the lessons path using the main worktree if needed, then read relevant entries from `tasks/lessons.md`.
6. Detect `--terse` or `--verbose` for output intensity:
   - **`--terse`:** Minimal output. Skip explanations, rationale, and intermediate status. Report only: decisions, actions, findings, and evidence. No filler phrases. Aimed at senior engineers who read diffs.
   - **`--verbose`:** Full explanations. Include rationale for each decision, alternatives considered, references consulted, and step-by-step reasoning. Aimed at engineers learning the codebase or reviewing unfamiliar areas.
   - **Default (no flag):** Balanced output. Brief rationale for non-obvious decisions, standard reporting, no excess explanation.

**Progressive disclosure principle:** Load references at the phase where they are first needed, not all upfront. This preserves context budget for the actual code and decisions that matter in each phase. Re-anchor on references when switching phases.

**Parallel loading:** Within a single phase, load independent references in parallel — issue multiple `Read` calls in one message. Same for independent `Glob`/`Grep` discovery. See `docs/parallelism-patterns.md`.

## Phase 0.5: Brainstorm (When Needed)

If the approach is unclear, multiple designs are plausible, or the engineer asks "how should we..." — follow `.claude/skills/brainstorming/SKILL.md` before writing the spec.

Skip this phase when:
- The engineer already specified the approach
- The task is a straightforward addition following existing patterns
- The scope is narrow enough that only one viable design exists

## Phase 1: Produce The Executable Spec

Follow `.claude/skills/spec-driven-development/SKILL.md`.

**Resolve ambiguity before drafting, not at the approval gate.** The spec skill's ambiguity gate (step 6) is mandatory — if two or more plausible designs, undefined scope edges, or unresolved architectural choices exist, ask via `AskUserQuestion` *before* writing the spec. The Phase 2.5 approval gate is a go/no-go on a fully-informed plan, not a place to surface open questions for the first time.

The resulting plan must include:

- scope classification
- change manifest
- test manifest
- implementation batches
- assumptions and risks

**Persist the spec to disk before continuing.** Save to `docs/specs/YYYY-MM-DD-<feature-slug>.md` using today's date and a kebab-case slug. Create `docs/specs/` if missing. This is mandatory — the engineer must be able to read and edit the spec outside of chat.

After the spec lands, record its path on the workflow artifact:
`scripts/workflow-artifact.sh set "$MTK_WF_UUID" results.spec_path=docs/specs/<file>`

## Phase 2: Write The Task Breakdown

Follow `.claude/skills/planning-and-task-breakdown/SKILL.md`.

Write **both** files (mandatory, not optional):

1. `tasks/todo.md` — checkable batches and post-implementation review items
2. `docs/plans/YYYY-MM-DD-<feature-slug>.md` — full plan alongside the spec, same date and slug as Phase 1

Create `docs/plans/` if missing. Then record both paths on the workflow artifact:
`scripts/workflow-artifact.sh set "$MTK_WF_UUID" results.plan_path=docs/plans/<file> results.todo_path=tasks/todo.md`

## Rigor Score (Continuous Ceremony Scaling)

Compute once after Phase 2, from the JSON sidecar at `docs/specs/<date>-<slug>.json`. Ceremony scales with the change's blast radius — a small fix gets a light pass, a breaking multi-batch change gets the full apparatus, and everything in between gets *proportional* rigor rather than a binary jump.

| Signal | Points |
|---|---|
| Implementation batches | +1 per batch |
| Change manifest size | +1 per 3 non-mechanical files (rounded up) |
| `security_impact != "none"` | +3 |
| Public contracts added or modified | +1 each (cap +4) |
| `scope == "breaking-change"` | +3 |

| Score | Rigor level |
|---|---|
| ≤ 3 | LIGHT |
| 4–7 | STANDARD |
| 8–11 | HIGH |
| ≥ 12 | MAX |

**Hard-trigger floor:** any of `plan.batches.length >= 3`, the count of non-mechanical `change_manifest` entries `>= 6`, or `security_impact != "none"` forces the level to at least HIGH regardless of score. An entry is **mechanical** only when it changes no logic and no public contract — rename-only, formatting-only, or otherwise no-behavioral-change (cf. the TDD `skip_when` categories `rename-only|formatting-only|no-behavioral-change`); an entry touching any public contract — including a serialized shape, persisted schema, or wire format — is never mechanical; mechanical entries are still implemented and verified, they just don't count toward the floor or the size score. These are the long-standing subagent-path triggers — the score scales ceremony continuously *between* them; it never relaxes them.

What the level dials:

| Dial | LIGHT | STANDARD | HIGH | MAX |
|---|---|---|---|---|
| Phase 3 path | inline | inline | subagent | subagent |
| Phase 4 Stage 2 reviewers | conditional (per Stage 2 rules) | conditional | `test-reviewer` always; `architecture-reviewer` if boundary/slice condition applies | both + `silent-failure-hunter` |
| `MTK_AUTO_PROCEED` eligibility | yes | yes | no | no |

State the score and level in one line in the Phase 2.5 gate rendering (e.g. `Rigor: HIGH (score 9 — 3 batches, 8 files, security_impact=new-auth-path)`) so the engineer sees why the ceremony is sized the way it is. When any `change_manifest` entries are mechanical, surface the split in that line so the engineer can veto the discount (e.g. `Rigor: STANDARD (score 4 — 8 files, 6 mechanical)`).

## Phase 2.5: Approval Gate (STOP HERE)

Mandatory. Before starting Phase 3, ask via the `AskUserQuestion` tool.

First, **render the plan and todo inline in the terminal** so the engineer can review them without opening files. Don't just cite the file paths — print the content:

1. A one-line header: scope classification, batch count, total files in the change manifest, and the computed rigor level with its score breakdown (see Rigor Score above).
2. The **full contents of `tasks/todo.md`** (the batch checklist with checkboxes and post-implementation review items). It is compact and is the primary thing the engineer approves.
3. A **batch breakdown from the plan**: for each batch, its title, files in scope, acceptance criteria, and boundary. This is the structured plan, not the raw markdown dump.
4. A **gate sequence** line — the full pipeline that will run against the approved batches, so the engineer sees what happens *between and after* them, not just the batch list. Derive it purely from facts already computed by this point (batch count from the plan; the Stage 2 reviewer set the Rigor Score table already dictates for this level — no new computation). Format: `Gate sequence: <N> batches → Phase 3.5 drift check → Stage 1 compliance-reviewer → Stage 2 [<reviewer set for this level>] → Phase 6 cleanup → Phase 7 compound`. The Stage 2 set follows the level: `test-reviewer` + `architecture-reviewer` at HIGH, both + `silent-failure-hunter` at MAX, and the conditional per-Stage-2-rules set at LIGHT/STANDARD (name the reviewers that apply).
5. The spec/plan/todo file paths, cited at the end for reference and editing. Print them as **bare repo-relative paths** (e.g. `docs/plans/2026-06-03-foo.md`, not a markdown link or a path buried in prose) so the terminal auto-linkifies them as clickable. Append `:<line>` when pointing at a specific batch (e.g. `tasks/todo.md:42`) so the click jumps straight to that line.

Keep the rendering proportional — the todo and batch breakdown are bounded by batch count, so this stays readable. The complete plan and spec markdown remain available via the `Show full plan & spec in terminal` option below for engineers who want every detail.

**`MTK_AUTO_PROCEED` opt-in.** If `MTK_AUTO_PROCEED=1` is set in the environment (typically via `.claude/settings.local.json` `env`), the orchestrator MAY default the recommended option on this gate (`Approve & run until done`) without an `AskUserQuestion` round-trip — but only when ALL of the following hold:

- The spec has zero open decisions (`open_decisions` array empty in the JSON sidecar).
- The spec has zero unresolved `[ASSUMED]` claims (no `[ASSUMED]`-tagged entry in the sidecar `assumptions` array, and none in the spec body). An assumption the model made on the engineer's behalf is an open decision in disguise — it gets a human at the gate. (`[VERIFIED:path]` and `[CITED:url]` claims do not block; only `[ASSUMED]` does.)
- No plan-gap-reviewer `BLOCKING` findings are unresolved.
- No unresolved package-legitimacy checkpoint (`checkpoint:human-verify` from planning for an externally-recommended package) remains open.
- `skill_precedence_gate` is `pass`.
- The scope classification is not "breaking change" or "high security_impact".
- The rigor level is LIGHT or STANDARD (HIGH/MAX changes always get a human at the gate).

If any condition fails, AUTO_PROCEED MUST NOT be applied — fall back to `AskUserQuestion`. Auto-proceed never overrides explicit user standards, open plan decisions, or the failure-stop gate. When AUTO_PROCEED is applied, record the gate decision on the workflow artifact: `scripts/workflow-artifact.sh gate "$MTK_WF_UUID" plan_trust_gate pass --reason "AUTO_PROCEED — all preconditions met"`.

Then invoke `AskUserQuestion` with:

- **Question:** "Plan and todo are written. How would you like to proceed?"
- **Options:**
  - `Approve & run until done` — autonomous mode. Proceed through Phases 3-7; stop only on blocking issues (build failures needing design input, unexpected security findings, or scope expansion beyond the manifest). Set internal flag `autonomous = true` for the rest of the session.
  - `Approve (interactive)` — proceed, but ask focused follow-ups when decisions materially affect the implementation.
  - `Edit first` — pause so the engineer can edit the spec/plan/todo files; wait for their next message. (Open questions should already be resolved in Phase 1's ambiguity gate — use this for fine-tuning, not for surfacing new ambiguity.)
  - `Revise` — rewrite Phase 1/2 (overwriting the same file paths) and return to this gate.
  - `Show full plan & spec in terminal` — print the complete plan and spec markdown (full files, beyond the batch breakdown already shown), then re-ask this gate.

If `AskUserQuestion` is deferred in this session, call `ToolSearch` with `select:AskUserQuestion` first. If the harness does not expose it (e.g. Cursor, Copilot CLI, Gemini CLI), stop and print one line: "Approval gate requires AskUserQuestion (unavailable in this harness). Tell me: Approve & run until done / Approve (interactive) / Edit first / Revise." Wait for the engineer — do not proceed.

Until the engineer answers: read-only Bash only, no Edit/Write on source code, no Phase 3. Proceed to Phase 3 only after `Approve & run until done` or `Approve (interactive)`. In autonomous mode, never call `AskUserQuestion` again for Phases 3-7 — stop and report instead.

On approval, record the gate decision on the workflow artifact:
`scripts/workflow-artifact.sh gate "$MTK_WF_UUID" plan_trust_gate pass --reason "<approve mode>"`

Then **seal the approved artifacts** — bind the exact bytes the engineer just approved so a later edit cannot silently keep the approval:
`scripts/workflow-artifact.sh seal "$MTK_WF_UUID"`
With no explicit paths, `seal` binds the artifact's own recorded `results.spec_path` / `plan_path` / `todo_path` (set in Phases 1–2) — the exact approved set, not a re-typed list. (Explicit **repo-relative** paths may still be passed; the stale-seal hook matches sealed files by repo-relative path.) The seal is created **only** here, on the engineer's approval answer — never earlier by the agent editing state — and is derived from disk by the script, so it cannot be presented for a body other than the one on disk. `verification-before-completion` (Phase 4) re-checks it with `verify-seal` and refuses completion on a STALE seal, and `spec-approval-trigger.sh` re-queues this gate on any post-approval edit to a sealed artifact. On `Revise` or `Edit first`, leave the gate `pending`, do not seal, and emit a `field_updated` event. See `.claude/references/orchestration-gates.md` for full gate semantics.

Note: this gate controls when *Claude* asks. Harness tool-permission prompts (file-write/Bash approvals) are a separate layer — autonomous mode does not bypass them.

## Phase 3: Implement In Batches

**Fork — pick the implementation path from the JSON sidecar at `docs/specs/<date>-<slug>.json`:**

- **Subagent path** (`.claude/skills/subagent-implementation/SKILL.md`) — when the rigor level is HIGH or MAX (any hard trigger — `plan.batches.length >= 3`, non-mechanical `change_manifest` entries >= 6, `security_impact != "none"` — or score ≥ 8; see Rigor Score). Dispatches one fresh implementer subagent per batch with orchestrator-side drift micro-checks. Asks once which model (Sonnet/Opus) to use for the implementer. Prefers the native dynamic-workflow runtime when the `Workflow` tool is available (drift/persistence/Phase-4 stay orchestrator-side), falling back to a manual Agent-per-batch loop otherwise.
- **Inline path** (`.claude/skills/incremental-implementation/SKILL.md`) — for everything below threshold. Smaller features stay in the main context.

Always also follow:

- `.claude/skills/test-driven-development/SKILL.md`
- `.claude/skills/source-driven-development/SKILL.md` when framework or SDK behavior is uncertain
- `.claude/skills/research-context/SKILL.md` when a choice is version-sensitive or depends on current external best-practice (returns a cited brief; does not edit code)
- `.claude/skills/security-and-hardening/SKILL.md` when the scope touches auth, financial state, secrets, or infra

Whichever path runs, every batch must:

1. implement only in-manifest files
2. add or update tests in the same batch
3. run the batch checkpoint using the build/test commands from the active tech stack skill
4. run the pre-commit review list if present
5. check the batch off in `tasks/todo.md`

After all batches:

- run the full test command from the active tech stack skill
- write an explicit behavioral diff
- emit the final `phase_exit_gate pass` (or `fail` and stop) on the workflow artifact (per-batch gate decisions are already recorded by the implementation skill)

Record per-batch progress:
`scripts/workflow-artifact.sh set "$MTK_WF_UUID" results.batches_completed=<n>`

## Phase 3.5: Spec-Drift Check

Before review, follow `.claude/skills/spec-drift-detection/SKILL.md`.

Compare the implementation against the spec's JSON sidecar at
`docs/specs/<date>-<slug>.json`:

- Files touched vs `change_manifest`
- Public contracts vs `public_contracts`
- `security_impact` vs actually-touched security-surface files
- `out_of_scope` items vs what was delivered

If critical drift is found:

1. Decide: is the implementation wrong, or was the spec incomplete?
2. If implementation wrong → fix within the manifest and re-run drift check.
3. If spec incomplete → amend the spec + JSON sidecar via
   `spec-driven-development`, re-open the Phase 2.5 approval gate for the
   scope change, then re-run drift check.
4. Do NOT proceed to review until drift is clean.

Silent drift repair is forbidden — every change to scope goes through the
approval gate.

## Phase 4: Review (Two-Stage)

Follow `.claude/skills/code-review-and-quality/SKILL.md`.
Follow `.claude/skills/verification-before-completion/SKILL.md` before starting review.

Stage 1 runs first (spec compliance) because if the implementation doesn't match the spec, code quality review is wasted effort. Within Stage 2, reviewers run in parallel.

### Stage 1: Spec Compliance

Run `compliance-reviewer` with:

- `git diff HEAD`
- the behavioral diff
- the scope classification
- the change manifest summary

The compliance reviewer checks: does the implementation match the approved spec? Are security, architecture, and coding standards met? If **Critical** issues are found, fix them before proceeding to Stage 2.

### Stage 2: Quality and Coverage

Only after Stage 1 passes (no Critical issues). When both reviewers apply, run them **in parallel** — dispatch in a single message with multiple `Agent` tool calls so reviews run concurrently. See `docs/parallelism-patterns.md` for the canonical spawn pattern.

- `test-reviewer` — when the change introduces or changes public behavior
- `architecture-reviewer` — when the change introduces new slices, boundaries, handlers, or cross-project interactions

At rigor MAX, run **both** reviewers regardless of the conditions above, plus `silent-failure-hunter` (empty catches, swallowed errors, masking fallbacks). At rigor HIGH, always run `test-reviewer`, but run `architecture-reviewer` only when the boundary/slice condition above holds — a change that adds or moves no modules and crosses no boundary (e.g. a pure rename or frontmatter-only batch) skips it. At LIGHT/STANDARD, the conditions above decide.

Provide all reviewers with the same diff and behavioral diff.

## Phase 5: Fix Review Findings

Fix every critical issue and every warning unless you record a one-line waiver with a reason, then:

- run the build and test commands from the active tech stack skill
- run the pre-commit review list if present
- re-run the necessary reviewer(s)

Maximum 3 review iterations.

## Phase 6: Cleanup

Follow `.claude/skills/code-simplification/SKILL.md`.

If cleanup changes code, re-run the build and test commands from the active tech stack skill.

## Phase 7: Compound (Learn And Strengthen)

This phase is not optional cleanup — it is how the toolkit gets smarter over time.

1. **What was learned?** Answer explicitly:
   - Did any assumption from the spec turn out to be wrong?
   - Did any framework/SDK behavior surprise you?
   - Did any review finding reveal a gap in the standards?
   - Did you receive any corrections from the engineer during this session?

2. **Capture lessons.** For each learning, append to `tasks/lessons.md`:
   - What happened
   - The rule to follow next time
   - Why it matters
   - When it applies

3. **Check for promotion.** If a lesson matches an existing pattern in `tasks/lessons.md` (3+ similar entries), propose adding it as a rule in `CLAUDE.md`.

4. **Check CLAUDE.md for drift.** If the work added new stable patterns (naming, structure, conventions), propose updates to `CLAUDE.md`. Do not silently modify it.

5. **Update pre-commit-review-list.** If a security or compliance issue was found during review, add it to `.claude/references/pre-commit-review-list.md` so it's caught earlier next time.

6. **State the compound.** In the final report, include a "What compounded" section listing what future sessions will benefit from.

## Phase 7.5: Archive (Delta Sync-Back)

If the spec sidecar declares a `baseline_area`, sync the delta back into its
baseline now — but **only** if Phase 3.5 drift returned a clean PASS and Phase 4
review found no open Critical issues. This produces the auditable
specified-vs-built trail (see `.claude/references/delta-spec-model.md`).

```bash
bash scripts/spec-archive.sh docs/specs/<date>-<slug>.json --verdict PASS
```

- Merges the change manifest / public contracts (or explicit `delta`) into
  `docs/specs/baseline/<area>.json`, regenerates `<area>.md`, and appends one
  record to `<area>.audit.jsonl`.
- If `CODE_INDEX.md` exists at the repo root, the archive also appends newly
  shipped public contracts to its auto-generated "Recently Shipped" section —
  the capability index stays current without a separate audit pass.
- Idempotent — safe to re-run on resume.
- Skip (with a one-line note) when the spec has no `baseline_area`, or when drift
  did not pass. Never archive drifted work.

## Final Report

Close the workflow artifact:
```bash
scripts/workflow-artifact.sh gate "$MTK_WF_UUID" memory_sync_gate pass --reason "lessons captured"
scripts/workflow-artifact.sh set "$MTK_WF_UUID" status=completed
scripts/workflow-artifact.sh event "$MTK_WF_UUID" workflow_completed --data '{"summary":"<short>"}'
```

Report:

- scope
- files changed
- tests added or updated
- review agents used and stage (1 or 2)
- review iterations
- cleanup summary
- **what compounded** — lessons captured, rules promoted, pre-commit-review items added
- whether `CLAUDE.md` changed

## Red Flags

- Code started before the spec existed
- Spec or plan not written to `docs/specs/` and `docs/plans/`
- Phase 2.5 approval gate skipped or merged into Phase 3
- Phase 3 started without an explicit approval answer from the engineer
- Approval gate answered by prose prompt instead of `AskUserQuestion`
- Spec drafted with material ambiguity unresolved (open questions deferred to "Open questions" section instead of asked via `AskUserQuestion` before drafting)
- Files touched outside the change manifest
- Checkpoints skipped
- No behavioral diff before review
- Review omitted for substantial work

## Critical Rules

1. Never skip planning for substantial work.
2. Skills are the workflow source of truth; do not silently replace them with ad hoc behavior.
3. Every touched file must appear in the plan.
4. New public behavior must be tested.
5. Review is mandatory for substantial work.
6. **The Phase 2.5 approval gate is always mandatory.** Spec, plan, and todo all written to disk before the gate. Ask via `AskUserQuestion` (load with `ToolSearch` if deferred; stop and say so if the harness doesn't expose it). Never assume or infer approval from the original request. The engineer chooses interactive vs autonomous at the gate, not via a flag.
