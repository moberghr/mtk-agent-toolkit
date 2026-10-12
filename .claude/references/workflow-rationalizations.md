---
description: Shared MTK rationalization table plus the per-skill rationalization and red-flag rows moved out of workflow skills — one Read away when a skill's inline excerpt is not enough, loaded by implement at rigor MAX
globs: ["**/*"]
alwaysApply: false
---

# Workflow Rationalizations and Red Flags

Skills keep at most three skill-specific rows inline and point here for the rest. Read the
shared table first; then the `## Per-skill traps` entry for the skill you are running.
`implement` loads this file at rigor MAX or when Phase 7 records a repeated ceremony reduction.

## Shared table (all MTK skills)

If you catch yourself thinking one of these, stop and re-read what the current skill actually requires.

| Rationalization | Reality |
|---|---|
| "I'll just start coding and adjust later" | Early wrong assumptions produce the most expensive rework. Read before writing. |
| "More context is always better" | No. Irrelevant context crowds out the rules that actually matter. |
| "I already read a similar file in another project" | Local codebase patterns win over generic memory. |
| "This change is trivial, it obviously works" | Trivial changes cause production incidents. Verify anyway. |
| "I'll verify / test / document it later" | Later rarely happens. Do it now or it won't happen. |
| "I know where the bug / issue is without reproducing it" | You have a hunch, not evidence. Reproduce first. |
| "It's only one more file" | Hidden scope creep is how quick fixes become feature work. Escalate instead. |
| "Probably works / should work / the framework handles it" | Probably is not a control. Verify the actual behavior. |
| "The tests pass, so this is fine" | Passing tests do not clear architecture, security, or performance risks. |
| "I'll remember this for next time" | You won't — no persistent memory without explicit capture. Write it down. |
| "The approach is obvious — skip planning / approval / alternatives" | Obvious to whom? Planning and approval exist to catch the mis-framings that feel obvious. |
| "The spec is outdated; the implementation is right" | Then amend the spec and re-approve. Drift checks run against the current spec, not a hypothetical one. |

## Per-skill traps

Rows below were moved verbatim out of the named skill's `## Common Rationalizations` / `## Red Flags` sections; the skill keeps its three most specific rows inline.

### research-context

#### Common Rationalizations

| Rationalization | Reality |
|---|---|
| "I already know the best practice for this library" | Your memory has a training cutoff; the library shipped versions since. If the decision is version-sensitive, verify it for the installed version. |
| "Let me just implement while I research" | This skill produces a brief and stops. Implementing mid-research means acting on unverified findings. |
| "One quick web search is enough for this architecture call" | High-stakes, multi-answer questions go through `/deep-research` so claims get cross-checked and voted, not taken from a single page. |

### subagent-implementation

#### Common Rationalizations

| Rationalization | Reality |
|---|---|
| "Let me ask the engineer between batches whether to keep going" | Phase 2.5 already answered. Per-batch confirmation = approval fatigue. Only halt on structural conditions (build fail / non-auto drift). |
| "The implementer touched one extra file, I'll quietly amend the manifest" | Auto-fix is allowed only inside the package, with no new public contract and no security_impact change. Anything else re-opens 2.5. |
| "I'll let the implementer subagent do the spec-drift review too" | No. Drift is orchestrator-side. The subagent is too close to its own diff to judge it. |
| "Let me reuse the same subagent across batches to save tokens" | Then it's not subagent-driven. Use `incremental-implementation` instead. |
| "Build failed, I'll skip this batch and continue" | No. A failing batch poisons every later batch's assumptions. Retry, then halt. |
| "The subagent said 'done' but returned no JSON — close enough, mark it passed" | No. Ack-only / unparseable / missing-evidence results are `inconclusive`, not `completed`. Respawn once with narrowed scope; a second inconclusive halts. |
| "Opus was rate-limited on B1, it's probably fine again for B2" | No. Once the tier is unavailable, the loop runs on `default` to the end. Probing the limit again costs another dead batch and another unrecorded gap. |
| "The workflow runtime validated the structured output, so I can skip the drift check" | No. Schema validation ≠ scope/drift judgment. The runtime confirms the JSON shape; it does not know `batch.files` or `out_of_scope`. Run the orchestrator-side drift micro-check on every returned result. |
| "The native plan-approval gate already approved it, so I can skip MTK Phase 2.5 / Phase 4" | No. The runtime gate approves running the *script*; it is not a spec approval or a code review. Phase 2.5 precedes the workflow; Phase 4 follows it. |
| "pipeline()/parallel() is faster, I'll run all batches at once" | Only same-level batches run together, and only up to the wave cap. Concurrency across a dependency edge produces a half-built, racy feature. |

#### Red Flags

- Implementer subagent receiving the prior batch's full diff (should be summary only)
- Implementer subagent calling `Agent` (recursion)
- Drift detected but loop continued without sidecar amendment
- `AskUserQuestion` called more than once per loop (model pick excluded)
- Per-batch review agent dispatched (was deferred to v2; if you need this, talk to maintainers first)
- Phase 4 skipped because "every batch was already reviewed"
- Dynamic-workflow path: orchestrator-side drift check skipped because "the workflow validated the output"
- Dynamic-workflow path: Phase 2.5 or Phase 4 skipped because the native plan-approval gate fired
- Dependent batches run with `parallel()`/`pipeline()` despite an ordering edge in `depends`
- A wave wider than `MTK_BATCH_WAVE_MAX`
- Drift detection or sidecar amendment logic placed *inside* the generated workflow script
- An `inconclusive` / ack-only / unparseable batch result counted as a pass or built upon by a later batch
- A kill or tier switch that appears in the final report but not in `results.dispatch_incidents[]`

### verification-before-completion

#### Red Flags

- "Should work" or "probably fixed" in a completion report
- Partial test run used to claim full verification
- Stale evidence from before the latest edit
- Success claimed despite warnings or skipped tests in the output
- New skill / hook / agent / reference authored but not wired (no manifest entry, hook not chmod +x or not referenced from settings, agent missing from plugin.json) — files exist on disk but nothing dispatches them
- Verifying at the batch level instead of criterion-by-criterion
- Using `test-run` or `build-output` alone for a behavior-shaped change (missing real execution surface)
- A `success_criteria` `observable` was edited mid-run to match the code (goalpost moved — tamper check skipped)
- Completion claimed while the workflow's `approval_seal` is STALE (approved spec/plan edited after approval, gate not re-opened)

### repo-health

#### Red Flags

| Rationalization | Reality |
|---|---|
| "The scorecard medal is 🥉 — I'll skip the report and just fix things." | The report IS the next action. Don't suppress the artifact. |
| "Repo-health and toolkit-health are basically the same — I'll merge them." | They're different: repo-health = readiness of this repo as an AI work surface; toolkit-health = how the team uses MTK. Keep them separate. |
