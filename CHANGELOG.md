# Changelog

All notable changes to MTK are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/).

## [7.30.0] - 2026-08-11

Polyglot-monorepo support and a class of silent guard failures, both driven by field use of MTK in a mixed-stack repo (.NET root with a Vite/TypeScript subtree owning its own `docs/specs/` and `CLAUDE.md`).

### Fixed — guards failed open under a path-spelling mismatch (security relevant)

`scope-guard.sh`, `read-guard.sh`, `spec-approval-trigger.sh` and `rule-trigger.sh` each derived a repo-relative path with a plain `"${FILE_PATH#"$REPO_ROOT"/}"` string strip. `REPO_ROOT` comes from `git rev-parse --show-toplevel` (canonical case), while the payload path is spelled however the session was launched — and a case-insensitive filesystem serves the same checkout as both `/Users/x/Dev/repo` and `/Users/x/dev/repo` (`pwd -P` resolves symlinks but not case). The strip then silently no-opped, `REL_PATH` stayed absolute, every `case ... in docs/specs/*)` match missed, and the hook exited 0. **`scope-guard` treats a still-absolute path as "outside the repo", so it failed open on every edit.** New shared helper `mtk_repo_relative_path` compares by device+inode, so the result never depends on spelling; it also supersedes the ad-hoc lowercase retry that had been applied to `rule-trigger.sh` alone. Recorded as S1.17.

### Fixed — `.claude/tech-stack.map` globs never matched under a symlinked root

`resolve-tech-stack.sh` built its target directory with a logical `pwd` while the repo root came from git as a physical path. Under any symlinked root the prefix strip no-opped and **every `tech-stack.map` glob silently failed to match**, degrading to the root default with no diagnostic. Resolved with `pwd -P`.

### Added — artifact-root resolution for polyglot repos

`scripts/resolve-artifact-root.sh` resolves where `docs/specs/` and `docs/plans/` live for a given path: `$MTK_ARTIFACT_ROOT` → nearest `<dir>/.claude/artifact-root` marker → nearest directory strictly below the repo root holding **both** `CLAUDE.md` and `docs/specs/` → repo root. Closest declaration wins, and both signals are required so neither a stray `docs/specs/` nor a stray nested `CLAUDE.md` can hijack resolution. A repo with no qualifying subtree resolves to the repo root, so single-project repos are unaffected. Wired into `scope-guard`, `spec-approval-trigger`, `post-compact`, `verify-behavioral-diff`, `session-analytics`, `spec-archive.sh` and `repo-health-score.sh`, plus `spec-driven-development` and `batch-fix`. Recorded as S1.16.

### Changed — polyglot tech-stack resolution is now actually wired up

`resolve-tech-stack.sh` existed but had only two callers. Six sites still inlined a repo-root-only read and would hand `dotnet build` to a Vite subtree: `api-compat-check.sh`, `pre-commit-linters.sh`, `parse-build-diagnostics.sh`, `generate-tool-configs.sh`, `generate-agents-md.sh`, `repo-health-score.sh`. All now resolve through it (explicit `--stack` overrides still win), and seven skills carry the polyglot wording. `repo-health-score.sh` check 3 now scores whether a stack *resolves* rather than whether the root file exists — a correctly per-subtree-pinned repo previously scored "missing".

### Added — `resolve-tech-stack.sh --check`

Warns when the resolved stack disagrees with the extensions of the files being touched (resolves `dotnet`, but the targets are `.tsx`). Advisory only: never blocks, never changes the resolved value or exit code. Non-stack-bearing extensions (`.md`, `.json`, `.sh`) are ignored.

### Fixed — analytics scattered across subtrees

`session-analytics.sh` wrote to a bare `.claude/analytics.json`, so running commands with a subtree CWD minted a second analytics file; its spec and lesson counts were cwd-relative too. Now anchored to the project root (`analytics-report.sh` likewise), with spec counting anchored to the resolved artifact root.

### Changed — batch-fix grouping and gate staleness

- Batches past ~5 findings now group into labelled clusters with a checkpoint per group, and a budget stop must land on a group boundary rather than mid-group. Previously the skill only offered "checkpoint with `handoff`".
- The approval gate now explicitly goes stale on a **material** change to the enumeration — a finding escalating out, narrowing, merging, or appearing — even when the original directive was explicit. Cosmetic changes (renumbering, sub-step splits) do not re-open it.
- Dirty-tree overlap between the working-tree baseline and the batch's target files must be surfaced *at the gate*, with the choice to proceed, stash, or drop the overlapping findings.

## [7.29.0] - 2026-07-21

Maintenance driven by field use of MTK across kvika/moberghr repos.

### Removed — MTK Staleness Check CI action

The `templates/ci/mtk-staleness-check.yml` GitHub Actions workflow and the `setup-bootstrap` STEP 4 offer to install it are gone. The workflow ran `setup-refresh-plan.sh --check` on every PR and failed the build when MTK-generated docs drifted from source; teams did not want it as a blocking gate on their repos. The local check is unchanged — `/mtk-setup --check` (and `scripts/setup-refresh-plan.sh --check`) still run the same staleness plan on demand. The `pr-lint.yml` / `pr-review.yml` copy-install templates are unaffected.

### Changed — context-budget & compress-monitor calibration (field feedback)

- `context-budget.sh` now scales its file/mod/op nudges with the declared context window. `MTK_CONTEXT_WINDOW_TOKENS` (default 200000) rescales all four thresholds so a large-context (e.g. 1M) model is no longer nudged to checkpoint or hand off mid-task; per-threshold `MTK_CTX_FILES_WARN` / `MTK_CTX_MODS_WARN` / `MTK_CTX_OPS_WARN` overrides win outright. Defaults reproduce the historical 30/40/120 at a 200k window.
- `compress-monitor.sh` no longer nags on read-only inspection commands (git diff/show/log/status/blame, grep/rg/ag, find, ls, tree) whose value is verbatim output and have no matching compress mode — cutting noise on review-heavy sessions.

### Changed — batch-fix guardrails (field feedback)

- The single approval gate is now explicitly *satisfied* (not skipped) when the engineer has already given an unambiguous go-ahead on the exact enumerated findings list — distinct from inferring approval from a vague request (Critical Rule 1 clarified).
- The `.mtk/scope-guard-skip` pointer documents a Write-tool fallback for when a shell-permission classifier blocks the `>` redirect.
- Proportional review is scoped to the batch's own changed files against a Phase-2 working-tree baseline, so pre-existing dirty-tree changes are not misattributed to the batch (no more false "missing test" findings for code the batch never touched).

### Fixed — `learnings.sh` migrate title-hash dedup on quoted titles

`jl_field` extracted JSON string values with a `"key":"([^"]*)"` regex that stopped at the first quote inside an escaped value and never reversed `json_escape`, so a lesson title containing `"` (e.g. `… trusting a "borrow" …`) round-tripped lossily. `migrate`'s title-hash dedup then re-added such a lesson on every marker-less re-feed, failing the `tests/hooks/test-learnings.sh` D regression (11 → 12). `jl_field` now walks the value honoring `\"` / `\\` / `\n` / `\r` / `\t` and stops only at an unescaped closing quote.

## [7.28.2] - 2026-07-20

### Fixed — `session-analytics.sh` cross-invocation temp-file collision

Several copies of the analytics Stop hook fire per session (plugin-cache versions plus the dev-checkout settings wiring), and all wrote through one fixed temp path `.claude/analytics.json.tmp`. The first copy's `mv` consumed the file a later copy was about to `mv`, so every session surfaced a non-blocking `mv: .claude/analytics.json.tmp: No such file or directory` / `[mtk-hook:session-analytics.sh] exit 1`. Analytics were still written (the winning copy), but the error was constant noise.

- `session-analytics.sh` now writes to a per-invocation `mktemp "${ANALYTICS}.XXXXXX"` instead of a shared `.tmp`, so concurrent copies race harmlessly on the final rename (last writer wins) rather than erroring. The deeper cause — multiple hook copies registered by a multi-version plugin cache — is tracked separately.

## [7.28.1] - 2026-07-20

Script-plumbing fixes from a field run of the full workflow against a repo where MTK ran from a *separate* checkout with `$CLAUDE_PLUGIN_ROOT` unset. The decision layer (routing, rigor scaling, gates, drift, review) behaved well; these fixes address the plumbing that assumed the toolkit runs from within the target repo.

### Fixed — silent cross-repo write in `spec-archive.sh`

- **`spec-archive.sh` wrote baseline artifacts into the wrong repo.** It resolved its output root from the *script's own* location (`dirname "$0"/..`) and `cd`'d there, so when MTK ran from a separate checkout it created `docs/specs/baseline/*` and appended to `CODE_INDEX.md` inside the **toolkit clone** — while printing a success banner naming the target's paths. It now resolves the **target** repo root via `${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}` (mirroring `workflow-artifact.sh` / `learnings.sh`), so output always lands in the project being archived. This also fixes the sibling symptom where a valid repo-relative spec path 404'd (the arg was checked *after* the wrong `cd`).
- **`lint-ears.sh` broke on repo-relative spec paths.** It set a script-derived `ROOT_DIR` and `cd`'d there — but never used `ROOT_DIR` again; the `cd` only served to make repo-relative file args resolve against the toolkit instead of the target. Removed; the linter now resolves its args against the caller's CWD.

### Added — `MTK_HELPER_ROOT` for running from a separate checkout

- **`MTK_HELPER_ROOT` env var** pins skill script-path resolvers (`workflow-artifact.sh`, `learnings.sh`) to a chosen checkout **first**, before the project copy and the plugin cache. This makes dogfooding MTK from a separate clone deterministic when `$CLAUDE_PLUGIN_ROOT` is unset, and lets you pin one version out of a multi-version plugin cache. Documented in `CLAUDE.md`; the resolvers in `workflow-artifacts`, `implement`, and `spec-driven-development` gained the three-tier idiom.

### Fixed — `implement` docs mis-showed the `phase_started` event call

- **`implement/SKILL.md` documented `phase_started phase-0` as a positional**, but `workflow-artifact.sh event` takes the phase in `--data` (`event <uuid> phase_started --data '{"phase":"phase-0"}'`) — following the doc literally produced `unknown flag: phase-0`. Both spots now show the `--data` form the canonical `workflow-artifacts` skill already uses.

## [7.28.0] - 2026-07-16

A batch of `implement`-workflow hardening from a field run of the full build loop. Two themes plus four localized fixes: the workflow now treats *supplied inputs and parallel-session activity* as first-class, and the approval seal + scope-guard stop conflating an artifact's expected mutation/temp state with real drift.

### Added — supplied plan/spec ingestion, worktree collision gate, plan↔code reconciliation

The build loop assumed it authored everything, so a pre-written plan collided with the path the workflow writes to, a stale supplied plan got re-implemented, and a parallel session editing in-scope files was only caught *after* an implementer had started.

- **First-class plan/spec ingestion (new Phase 0.7).** When the engineer supplies a spec or plan as the input — a path they hand you, or an existing `docs/specs|plans/*.md` the run is meant to execute — `implement` now *adopts* it as the source of truth instead of authoring a new one. No path collision, no `-impl`/`-v2` suffix workaround, never an overwrite of the engineer's file. `spec-driven-development` and `planning-and-task-breakdown` gained matching "adopt, don't recreate" branches.
- **Plan↔code reconciliation (`prior-work-check` existing-plan mode).** A supplied plan may be stale — batches already implemented since it was written. Phase 0.7 runs `prior-work-check` in a new read-only reconciliation mode that classifies each batch `already-satisfied` / `partially-done` / `not-started` with `file:line` evidence; satisfied batches are marked done and ticked before the approval gate instead of being re-run.
- **Worktree collision gate (Phase 0 pre-flight capture + new Phase 2.9).** Phase 0 snapshots the pre-existing dirty set; before the first batch, Phase 2.9 intersects the current `git status` against the change manifest and halts (interactive `AskUserQuestion`, or stop-and-report in autonomous mode) when an **in-scope** file is already modified by other work. The prior dirty-worktree step only flagged *out-of-manifest* paths as advisory risk; the in-scope parallel-session collision now gates before any edit.

### Changed — approval seal binds spec + plan only (todo is progress state)

The Phase 2.5 seal bound spec **+ plan + todo**, but `tasks/todo.md` is designed to mutate as batches complete — so the seal flipped STALE on the first checkbox tick, and `verification-before-completion` (fail-closed on STALE) then refused the completion. The seal cried wolf on expected progress.

- `seal` now derives its default set from `results.spec_path` + `results.plan_path` only; `results.todo_path` is excluded (`scripts/workflow-artifact.sh`). `hooks/spec-approval-trigger.sh` no longer watches `tasks/todo.md`. Scope lives in spec + plan; progress lives in todo — a moved success-criterion goalpost is still caught (seal on the spec .md, plus the frozen-criteria diff). Existing seals recorded before this release still verify against whatever they sealed (back-compatible). Wording synced across `implement`, `spec-driven-development`, `verification-before-completion`, and the `approval-seal` pressure test, which gains a scenario asserting a checkbox tick must **not** trip the seal.

### Changed — rigor score distinguishes external from internal-tooling contracts

"Public contract" was a single external/internal axis, so an internal CLI flag or a handful of IaC/CDK config props scored +1 each just like a public HTTP endpoint — a ±4 swing that could flip HIGH↔MAX and change the reviewer set.

- `public_contracts[]` gains an optional `surface: external | internal-tooling` field (`handoff.schema.json`, default `external` for back-compat). The `implement` Rigor Score now weights **external/wire contracts** +1 each (cap +4) but **internal-tooling contracts** (build/IaC/CLI knobs with no external consumer) +1 total regardless of count. `spec-driven-development` defines the two classes with CDK-props / internal-CLI-flag as the canonical internal example; when unsure, default to external.

### Fixed — four localized implement-loop gaps

- **Autonomous vs "ask which model" contradiction.** `subagent-implementation` said "ask once" for the implementer model; autonomous mode said "never ask in Phases 3-7". Resolved explicitly: the model ask is **interactive-only** — autonomous mode skips it and applies the Sonnet policy default (Opus for plan-flagged novel/tricky batches). Stated in `subagent-implementation`, `implement`, and `model-routing.md`.
- **Script path resolution.** `implement` and `workflow-artifacts` now resolve `workflow-artifact.sh` once into `$WFA` (project-first, `${CLAUDE_PLUGIN_ROOT:-.}` fallback — the same idiom already used for `learnings.sh`) and call `"$WFA"` at every site, so a plugin-cache install with `$CLAUDE_PLUGIN_ROOT` unset no longer fails on a bare `scripts/…` path.
- **scope-guard false positive on temp writes.** `hooks/scope-guard.sh` now exits early for out-of-repo paths (a still-absolute `REL_PATH` — session scratchpad, `/tmp`) and `.mtk/` workflow state, which can never be scope violations; it was warning on a scratchpad review artifact.
- **`gate` help lists the valid set.** The `workflow-artifact.sh` usage/`--help` header now enumerates the five valid gate names (the runtime error already did as of 7.27.0).

## [7.27.0] - 2026-07-16

### Added — rigor re-scales when scope shrinks mid-run

`implement`'s Rigor Score was computed once at Phase 2 and never revisited. A six-batch spec that scored MAX kept the MAX apparatus — subagent path, both reviewers plus `silent-failure-hunter` — even when the biggest batches were deferred mid-run and the work that actually shipped was LIGHT/STANDARD. Field feedback flagged the mismatch: engineers were right-sizing the review by hand.

- **Recompute on scope reduction.** When the approved batch set shrinks at a phase boundary (a batch deferred during Phase 3, or the Phase 3.5 drift check — never mid-batch), the score and level are recomputed from the batches that remain, and the Phase 4 reviewer set + `MTK_AUTO_PROCEED` eligibility follow the recomputed level.
- **Relax-only, floor-respecting.** A recompute never drops below the hard-trigger floor of the *remaining* work (≥ 3 batches, ≥ 6 non-mechanical files, or any surviving `security_impact` still hold the floor). A scope *increase* is never a silent recompute — it re-opens the Phase 2.5 gate as before; only a reduction auto-relaxes, because the engineer already approved the larger scope. The transition is logged to the workflow artifact (`results.rigor_recomputed`) and surfaced in one line. New `evals/rigor/eval-02` + grader coverage.

### Added — per-directory tech-stack resolution for polyglot monorepos

Closes the per-directory half of the 7.26.0 follow-up (1): `.claude/tech-stack` resolved repo-root-only, so a TypeScript subproject under a .NET root loaded the wrong stack's build/test commands until the engineer overrode it by hand.

- **New `scripts/resolve-tech-stack.sh`** resolves the active stack for a given path — `MTK_STACK` env → nearest subproject `.claude/tech-stack` (closest-declaration-wins) → root `.claude/tech-stack.map` glob → repo-root `.claude/tech-stack` default. Coreutils + git only; empty output means "unconfigured", same as a missing file.
- **Wiring.** `implement`'s *load the active tech stack* step and `context-engineering`'s Active Stack panel resolve through it (pass a subtree path from the change manifest to load the stack for the files being touched); `check-prerequisites.sh` and `repomap.sh` prefer it with a graceful fallback to the old root read. `setup-bootstrap` documents the `.claude/tech-stack.map` convention. Repo-wide generators (AGENTS.md, tool configs, repo-health) still use the primary stack — multi-stack *merged* command sets for a single repo-wide operation remain the open half of the follow-up.

### Changed — a mechanical batch runs inline even under HIGH/MAX

The subagent path was binary on rigor level: at HIGH/MAX every batch drew a fresh implementer subagent. A pure config/rename/formatting batch has no logic or contract to isolate, so the isolation bought only cold-load latency.

- An **all-mechanical batch** (every entry mechanical per the existing Rigor Score definition; an entry touching any public contract is never mechanical) is now implemented **inline** by the orchestrator even inside an otherwise-HIGH/MAX run, with the drift micro-check, result persistence, and churn check still applied. Non-mechanical batches take the full dispatch path unchanged. The "orchestrator never edits source" invariant gains an explicit carve-out for this one case, and a new pressure-test scenario guards against *over*-applying it to a logic batch wearing a "mechanical" label.

### Fixed — workflow-artifact gate error lists the valid set

`workflow-artifact.sh gate` rejected an unknown gate name with only a pointer to a doc. It now lists the valid gate names inline (`must be one of: plan_trust_gate phase_exit_gate failure_stop_gate memory_sync_gate skill_precedence_gate`), mirroring the existing `criteria` status-validation idiom and giving the valid set a single source of truth in the function.

## [7.26.0] - 2026-07-14

### Added — `batch-fix` lane for corrective batches

A new routed workflow skill sits between `fix` (1–3 files, one coherent change) and `implement` (new behavior/contract/architecture). It handles a corrective batch of multiple small **independent** fixes — applying review findings, several unrelated one-liners across more than three files — with no new public contract and no architectural re-planning. Previously such work fell into `implement` and inherited the full spec+plan+approval apparatus; `batch-fix` gives it proportional ceremony.

- **Lightweight front-end.** Enumerate findings → short findings-list spec stub + `tasks/todo.md` → a **single** approval gate → per-finding TDD (mechanical findings skip) → **inline** implementation (no subagent-per-batch) → proportional review (pre-commit-review always; specialized reviewers only when a finding crosses a boundary) → verification. `MTK_AUTO_PROCEED`-eligible.
- **Router wiring.** `/mtk` gains the lane across the decision graph, route table, disambiguation rows, the clarifying question, and help output. `fix`'s Scope Guard now reroutes *multiple independent trivial fixes* to `batch-fix` (marker `escalated from fix (batch)`) while genuine new-slice/contract/re-planning growth still escalates to `implement`. Marker matching is most-specific-first so `escalated from fix (batch)` never mis-binds to the generic `escalated from fix`.
- **Escape hatch.** A single finding that turns out to need a new contract/slice escalates to `implement` via `escalated from batch-fix`. New router fixture, pressure test, and eval cover the lane.
- **Resumed vs. new batch.** Phase 2 now reconciles the batch slug against any existing `*-batch.md` stub and the SessionStart recovery pointer before writing: matching findings resume the prior stub, differing findings mint a distinct slug (`-batch-2`) instead of overwriting. Field feedback hit this — a stale recovery pointer and an existing stub both pointed at a prior batch on the same feature, forcing a hand-minted slug.
- **Proportionality + concurrency guidance.** A `When To Use` note steers a mostly-mechanical batch toward plain `fix` (the stub + gate ceremony earns its keep on behavioral/boundary findings, not cosmetic sweeps), and Phase 4 now tells the loop to re-read each target file immediately before editing rather than assuming a frozen tree (concurrent human edits, or an earlier finding touching the same file).

### Changed — rigor ceremony no longer over-escalates on mechanical edits

The `implement` rigor floor and size score now count only **non-mechanical** `change_manifest` entries. A mechanical entry changes no logic and no public contract (rename-only, formatting-only, generated, no-behavioral-change — the TDD `skip_when` vocabulary); an entry touching any public contract is never mechanical. A batch of pure renames no longer gets force-floored to HIGH (subagent fleet + both reviewers) purely on file count.

- The hard-trigger floor (`>= 6` files), the size score (`+1 per 3 files`), the Phase 3 subagent-path fork, `subagent-implementation`'s trigger, and the dynamic-workflow decision node all count non-mechanical entries consistently. Mechanical entries are still implemented and verified — they just don't inflate ceremony.
- The Phase 2.5 gate rendering surfaces the split (e.g. `Rigor: STANDARD (score 4 — 8 files, 6 mechanical)`) so the engineer can veto the discount. The optional per-entry `mechanical` boolean is documented in the spec JSON sidecar schema.
- At rigor HIGH, `architecture-reviewer` now runs only when the boundary/slice condition holds (a pure rename / frontmatter-only batch skips it); `test-reviewer` still always runs, and MAX still runs both plus `silent-failure-hunter`.

### Fixed — resolution robustness for split installs and cached versions

- **Graceful degrade on missing tech stack.** `implement` Phase 0 no longer hard-stops when `.claude/tech-stack` is absent: it infers the stack via `scripts/setup-detect.sh --json` (read-only), loading the matching `tech-stack-{stack}` skill, and otherwise warns and proceeds with `CLAUDE.md`-only context. A partial setup no longer blocks a straightforward change.
- **Project-anchored workflow state.** `workflow-artifact.sh`, `workflow-artifact-md.sh`, and `workflow-dashboard.sh` now resolve `.mtk/workflows/` under `$CLAUDE_PROJECT_DIR` (falling back to the git top-level, then cwd) instead of bare `$(pwd)`, so state lands in the target project when MTK skills live in a separate checkout. `.mtk/` is added to the File Resolution "always project-relative" allow-list.
- **Deterministic version binding.** The File Resolution plugin-cache fallback uses `sort -V | tail -1` instead of `head -1`, so it binds the newest cached MTK version rather than whichever `find` happened to emit first.
- **Split-brain caveat.** The File Resolution block now warns that skills and scripts must resolve from the same root; a split (skills from a local dev checkout, scripts from the plugin cache) risks version drift.

- **Batch-fix scope-guard false positives + graceful degrade.** `scope-guard.sh` anchors to the most-recently-modified spec sidecar, so a manifest-less workflow like batch-fix had every edit checked against a *stale* spec's manifest (a real run hit 18 false "not in the approved spec" warnings). batch-fix now drops a freshness-windowed skip pointer (`.mtk/scope-guard-skip`, 4h TTL) and `scope-guard.sh` checks that pointer **before** any mtime-based spec selection and no-ops — batch-fix scopes by its findings list, not a file manifest. This replaces an interim "write a freshest JSON sidecar" marker that still mis-fired: a concurrent feature spec touched in the same session is legitimately newer than the batch stub, so the guard anchored to the wrong spec and warned on every edit anyway. The pointer is race-immune (it is not selected by timestamp), self-expiring (a crashed run's pointer ages out instead of disabling the guard forever), and anchored under `$CLAUDE_PROJECT_DIR` → git top-level → cwd so writer and hook agree on its location from a worktree or sub-dir cwd. batch-fix's Phase 0 also degrades on missing setup (infer stack via `setup-detect`, resolve references from the plugin cache, announce degraded mode), and it flags that batches beyond ~5 findings may warrant a `handoff` checkpoint.
- **Workflow artifact `phase_cursor` now advances.** `phase_cursor` was written only at init (`phase-0`) and never moved — the skill emits `phase_started` as an event, but nothing updated the cursor field, so a resume driven off `phase_cursor` alone restarted at phase-0 even after reaching a later phase. `workflow-artifact.sh event` now derives the cursor from the event log: a `phase_started` event carrying a `phase` advances `phase_cursor` to it. No skill change is required (the `phase_started` emission already exists), and existing callers are fixed retroactively. Non-phase events leave the cursor untouched.
- **Workflow artifact `set`/`event` confirm on success.** Both were silent on success, so state changes could only be confirmed by re-reading the JSON. They now print a one-line confirmation to stdout; internal callers (which already redirect stdout to `/dev/null`) stay quiet, so only top-level invocations surface it.
- **Stop hooks aborted (exit 1) on absent optional fields.** `workflow-continuation.sh` and `capture-learnings.sh` extract fields with `VAR="$(grep … | … | head -1)"` under `set -euo pipefail`. A legitimate no-match makes `grep` exit 1, and `pipefail` propagated that through the assignment, aborting the hook **before** the guard written to handle the absent value (`[ -n "$TOTAL" ] || exit 0`; `[ -n "$REPEATED" ]`) — turning an intended silent no-op into a visible `Stop hook error … exit 1`. It surfaced specifically in `mtk:implement` sessions because that is the only scenario reaching those extractions: an active workflow whose batch accounting is not recorded yet (`workflow-artifact.sh` init writes no `batches_total`/`batches_completed`), and a substantial session whose `tasks/lessons.md` has ≥3 lessons but no `Rule:` lines. Both extractions now terminate in `|| true`, so a no-match yields empty output and exit 0 and the guards run as designed. Other hooks were scanned for the same shape; the remaining `$(…)` extractions use `awk`/`sed`, which exit 0 on no-match, so they are unaffected.

> Known follow-ups (tracked separately): (1) per-directory resolution shipped in 7.27.0 (a subproject loads its own stack via `.claude/tech-stack.map` or a nested `.claude/tech-stack`); the open remainder is multi-stack *merged* command sets for a single repo-wide operation; (2) `learnings.sh query` returning zero matches silently — needs an explicit "0 matches" vs "error" signal and a `tasks/lessons.md` fallback; (3) `MTK_AUTO_PROCEED` keying off an explicit "fix all / just do it" in the invoking message when there are zero open decisions.

## [7.25.1] - 2026-07-14

### Added — Publish workflow outputs as a Claude Artifact

Workflow skills persist their human-facing outputs (spec, plan, handoff, health report) to disk, and disk stays the source of truth — the machine pipeline (drift detection, approval seal, EARS lint, plan-gap review, session recovery, baseline archive) reads local files and cannot read a hosted page. This release **additively** publishes those outputs as one browsable Claude Artifact per workflow run, updated in place across phases, so the engineer gets a single always-current URL rendered for review outside the terminal.

- **One artifact per workflow run.** Keyed to the existing `workflow_uuid`: `spec-driven-development` creates it (Spec section), then `planning-and-task-breakdown` (Plan), `handoff` (Handoff), and `repo-health` (Health report) re-publish the same file in place — reusing the recorded `results.artifact_url` rather than minting a new link — so one URL fills in as the workflow progresses.
- **Additive and capability-gated.** Disk is written first and unconditionally; publishing never gates or replaces it. It happens only when the harness exposes the `Artifact` tool (Claude Code / claude.ai) and `MTK_ARTIFACT_PUBLISH` != `0`. On cursor/codex, or with the opt-out set, every skill behaves exactly as before — disk only, no error, no stall.
- **Data-egress opt-out.** Because publishing transmits internal spec/plan content to claude.ai, `MTK_ARTIFACT_PUBLISH=0` disables it repo-wide for regulated contexts (documented in the CLAUDE.md skill-routing env table).
- **New pieces.** `scripts/workflow-artifact-md.sh` deterministically assembles the rollup (`.mtk/workflows/<uuid>.artifact.md`) from whichever recorded source docs exist, skipping missing ones; `.claude/references/artifact-publishing.md` is the single canonical procedure the skills link to (thin navigation layer, S2.26); the workflow-artifact schema documents `results.artifact_url` and the source-path fields. `code-review-and-quality` publishing is deliberately deferred (forked subagent — the orchestrator writes artifacts, not the fork).

## [7.25.0] - 2026-07-07

### Added — Approval seal + executable lesson contracts

Two borrows from a survey of trending AI-coding-agent tooling against MTK's existing machinery, both making a soft state *checkable* rather than asserted.

- **Approval seal.** On Phase 2.5 approval, `implement` now records a SHA-256 **approval seal** over the approved spec/plan/todo bodies via new `scripts/workflow-artifact.sh seal` / `verify-seal` subcommands. The seal binds the exact approved bytes, so editing an approved artifact afterward is caught deterministically: `hooks/spec-approval-trigger.sh` re-queues the approval step (advisory), and `verification-before-completion` refuses a completion claim while the seal is STALE (blocking). The seal is derived from disk by the script and created only on the engineer's approval answer — it cannot be presented for a body other than the one on disk, and any re-seal is recorded as an `approval_sealed` event ("approve a state, not an intention"). `verify-seal` exits 0 (match) / 1 (stale, prints both hashes + the changed file) / 3 (no seal — older workflows fall back to the git-diff criteria tamper check). Backward-compatible.
- **Executable lesson contract.** Lessons may now carry four OPTIONAL fields — `output_contract`, `prefinal_verification_checklist`, `confidence`, `source_evidence_refs` — that turn a prose lesson into a checkable one. `scripts/learnings.sh add` accepts `--output-contract` / `--prefinal-checklist` / `--confidence` / `--source-evidence-refs` (the JSON values are validated and compacted to a single line so a malformed contract can't corrupt the store), `regen-markdown` renders a Contract line only when present, and `mtk-doctor` gains a `LESSONS` category that WARNs on malformed contracts (never FAIL — the feature is optional). `golden-path-capture` and `promote-lesson` document when to attach one; `promote-lesson` reserves `confidence: high` for a verified path. Prose lessons are unchanged.

## [7.24.0] - 2026-07-06

### Added — Context-efficiency: `.claudeignore` at setup + doctor baseline

Two low-friction token/context wins, drawn from a survey of context-saving tooling against MTK's existing machinery (output compression, on-demand loading, model routing were already covered). Complements the 7.23.0 token-optimization wave.

- **Stack-aware `.claudeignore` at setup.** `setup-bootstrap` now generates a `.claudeignore` at the repo root (idempotent, never overwrites, committed) so Claude Code natively keeps dependency/build directories out of search and read results. The floor mirrors the built-in scan defaults in `hooks/lib/mtkignore.sh`; per-stack caches/outputs are appended for dotnet (`TestResults/`, `*.user`), python (`.pytest_cache/`, `.mypy_cache/`, `.ruff_cache/`, `*.egg-info/`), and typescript (`.next/`, `build/`, `coverage/`, `.turbo/`). Distinct from `.mtkignore`, which only MTK's own scans consume.
- **`CONTEXT` baseline in `mtk-doctor`.** New report-only category surfacing the always-on install cost: the always-on context baseline (CLAUDE.md + `rules/INDEX.md` + `alwaysApply` references, in tokens/bytes), the MCP tool-schema count from `.mcp.json`, and the `ENABLE_TOOL_SEARCH` state. All checks stay PASS on a clean repo; the numbers live in the detail field. Appears in both human and `--json` output.

## [7.23.0] - 2026-07-06

### Added — Token optimization wave

Five measures to lower MTK's context footprint and make its (largely already-real) savings visible to users. Baseline before this release: ~3.7K always-on tokens/session, ~86K tokens kept out of context by progressive disclosure.

- **Skill-description budget enforced.** `validate-toolkit.sh` now caps each MTK skill `description` at 200 chars and the aggregate at 7000 chars (~1750 tokens), and prints the running total every run. Descriptions load into *every* session against Claude Code's ~1%-of-context skill-listing budget, so this protects routing quality on smaller-context models and stops the always-on floor drifting as skills are added (S2.6a). The 7 longest descriptions were trimmed to fit (6643 -> 6407 chars) with keywords preserved.
- **`security-checklist.md` no longer always-on.** Its frontmatter (`alwaysApply: true`, glob `**/*`) was aligned to the security-scoped `applyTo` the manifest already carried, closing a split-brain where the MCP resolver treated it as path-scoped but the frontmatter/index/bash-fallback treated it as always-on. Every consumer already loads it explicitly and conditionally (`security-and-hardening` reads it unconditionally), so behaviour is unchanged; it just stops loading on non-security work in the fallback path.
- **`mtk-savings.sh` - context footprint & savings report.** New script (`bash scripts/mtk-savings.sh`) reports the always-on floor, tokens deferred by progressive disclosure, review-agent bodies offloaded to isolated context, and real output-compression totals read from `.claude/observability/compression.jsonl`. Surfaced from `analytics-report.sh` and the `context-report` skill. Every figure is derived from installed files or the on-disk log - nothing fabricated.
- **Prompt-cache-stable CLAUDE.md prefix.** The stale, per-release version banner in `CLAUDE.md` was replaced with a stable pointer to `CHANGELOG.md`, so the always-loaded prefix no longer changes every release (keeps prompt caching warm).
- **Progressive disclosure of the fattest skill body (S2.26).** The literal Root CLAUDE.md template moved out of `setup-bootstrap` (924 -> 815 lines) into on-demand `references/root-claude-md-template.md`, read by STEP 3 only when generating. Deeper restructuring of the other large workflow skills, and the tech-stack scan-recipe split (cross-consumed by `setup-audit`), are deferred to their own reviewed change to avoid destabilizing skills changed in the recent 7.19-7.22 waves.

## [7.22.0] - 2026-07-06

### Added — Borrow wave 3: routing, memory & context

Final borrow wave from the agent-cortex triage (`docs/plans/2026-07-03-agent-cortex-borrow-triage.md`). The batch-3 sources were research/reading lists with no vendorable code, so this wave takes file-implementable ideas and vocabulary only.

- **Conflict-superseding lesson writes.** `learnings.sh add` gains `--supersedes <id>`; `learnings.sh query` derives the superseded set from those forward refs and drops any entry a newer one supersedes — so a reversed rule stops surfacing without deleting the audit trail (no line rewriting). `correction-capture` now captures a contradicting lesson with `--supersedes` instead of appending a second conflicting rule. (Borrow: IAAR-Shanghai conflict-driven forgetting.)
- **Memory content-type tag.** New optional `memory_type` (`episodic | semantic | procedural`) on the learnings schema and `learnings.sh add --memory-type`, orthogonal to `source` provenance, to improve recall relevance. (Borrow: IAAR-Shanghai content-type taxonomy.)
- **Named context operations.** `context-engineering` now opens with the **Write / Select / Compress / Isolate** taxonomy and a one-line definition of context, each mapped to the MTK machinery that already implements it. (Borrow: jihoo-kim / LangChain taxonomy.)
- **Negative-example route disambiguation.** `/mtk` gained a "Route Disambiguation (negative boundaries)" table encoding the contested pairs (fix vs implement, research-context vs implement, pre-commit-review vs full review, context-report vs toolkit-health, capture vs handoff, promote-lesson vs lesson-mining, setup always → `/mtk-setup`). (Borrow: awesome-harness-engineering negative-example routing.)
- **MCP shortlist additions.** `docs/recommended-tooling/shared.md` adds Sentry and a read-only Postgres MCP (with a read-only-role caveat) and strengthens the security note to prefer read-only roles / scoped tokens; `dotnet.md` adds Azure DevOps for ADO shops. (Borrow: wong2/awesome-mcp-servers, security-gated.)
- **Competitor positioning.** README FAQ now distinguishes MTK from other AI setup/config-generator tools by its claim-verification loop (verified rules/commands, re-runnable refresh/converge/check), not just generation.



### Added — Borrow wave 2: guardrails & generation

Second borrow wave from the agent-cortex triage (`docs/plans/2026-07-03-agent-cortex-borrow-triage.md`). Focus: guardrails that travel with the capability, and cleaner generated output.

- **Per-tool guardrails + no-delete fence in the implementer dispatch contract.** `subagent-implementation` now states each granted tool's boundary inline (Edit/Write: only `batch.files`; Bash: build/test/format/read-git only, no network or destructive commands) and forbids deletion (no `rm`/`git rm`; removals become a `deviation` for the orchestrator). Directly targets the out-of-scope-edit (v7.14) and destructive-deletion (v7.10.3) failure modes. (Borrow: dontriskit + EliFuzz — guardrails baked into the capability.)
- **Terminology / LLM-tic lint is now enforced.** `verify-claims.sh` implements the previously documentation-only audit-grounding §4 denylist: tagged lines carrying LLM prose tics ("Additionally", "Furthermore", "Moreover", "Delve", "worth noting", "plays a crucial role") get a `terminology-needs-review` weak-claim entry with the matched term. Advisory, never auto-rewritten. (Borrow: yzhao062/agent-style field-observed tics.)
- **Output-style section in generated CLAUDE.md.** `setup-bootstrap`'s CLAUDE.md template now emits an `## Output Style` block (no em-dash-as-punctuation, no filler transitions, no bullet inflation, no per-paragraph summary, back claims with file:line) so bootstrapped repos steer agent prose from day one. (Borrow: agent-style anti-patterns.)
- **`paths` axis in the rule wake-up index.** `build-rule-index.sh` now surfaces each rule's `paths:` globs as a column in `.claude/rules/INDEX.md`, giving machine-scoped auto-attach (a rule whose glob matches a touched file is always relevant) alongside the decision/topic/scope axes; `git-workflow.md` gained the `paths:` it was missing. (Borrow: instructa/ai-prompts + awesome-copilot `applyTo` globs.)

### Deferred

- Idempotent import-marker merge in `generate-tool-configs.sh` (batch-2 #12): the copilot/windsurf/cursor generators are overwrite-guarded but not marker-merged. Deferred — it needs careful surgery across five output formats plus smoke tests; tracked in the triage doc.



### Added — Borrow wave 1: skill & subagent authoring hardening

First of three minor releases mining the `awesome-agent-cortex` neighborhood (triage in `docs/plans/2026-07-03-agent-cortex-borrow-triage.md`). Batch-1 finding: the ecosystem's *content* (persona agents, thin skills) is behind MTK, so this wave takes only conventions and validator capability — the reusable parts.

- **Navigation-only SKILL.md rule (S2.26).** New rule states a SKILL.md is a navigation layer, not a payload — it holds decision logic and links to `.claude/references/**` rather than inlining detail. Mirrored into `writing-skills` Phase 2. (Borrow: wshobson/agents progressive-disclosure contract.)
- **Least-privilege agent lint.** `validate-toolkit.sh` now advises (WARN, non-blocking) when a `.claude/agents/*.md` declares neither `required-toolsets` nor `allowed-tools`, or grants a mutating tool (`Edit`/`Write`/`MultiEdit`/`NotebookEdit`) to a read-only reviewer. (Borrow: VoltAgent tool-matrix-by-role.)
- **Frontmatter enum sanity.** `validate-toolkit.sh` advises on unexpected `model:` (expected `opus|sonnet|haiku|inherit`) and `effort:` (`low|medium|high|max`) tiers in agent frontmatter, catching typo'd tiers early. (Borrow: awesome-copilot schema-validated frontmatter, adapted to bash/advisory.)
- **Self quality-checklists in reviewer agents.** `compliance-reviewer`, `test-reviewer`, `architecture-reviewer`, and `silent-failure-hunter` each gained a `## Quality Checklist` the agent runs against its *own* output before returning (every finding cites file:line, no FP-class findings, verdict matches scores). (Borrow: 0xfurai embedded `## Quality Checklist`.)

### Deferred

- CLAUDE.md archetype seed skeletons (batch-1 #7): setup-bootstrap already generates bespoke CLAUDE.md from the audit; archetype fallback is low value and would inflate an already-large skill. Left as a note in the triage doc.

## [7.19.0] - 2026-07-03

### Added — Setup improvements wave

A competitive analysis of the setup/bootstrap landscape plus a same-session local review surfaced 11 items: three local fixes, four Tier-2 borrows, and four Tier-3 borrows. This release ships all 11.

- **`--update-guidelines` works from marketplace installs.** `mtk-setup` now resolves the coding-guidelines pin against `$CLAUDE_PLUGIN_ROOT` when present, and writes the updated pin to the repo-local `.claude/mtk-version.json` instead of the plugin cache; the report line states which file carries the update.
- **Mechanized detection (`scripts/setup-detect.sh --json`).** Read-only script consolidating stack markers, package-manager lockfile priority, React Native/Expo markers, and monorepo classification (workspace globs, package counts, 20-package cap) into one tested entry point; `setup-bootstrap`/`setup-audit` shrink accordingly, reporting all detected stacks instead of just the first.
- **Eval coverage for the setup family.** New `evals/setup-bootstrap/` (grader + clean-bootstrap and rerun-preservation scenarios), discoverable via `scripts/run-evals.sh`.
- **`/mtk-setup --converge`.** New read-only `setup-converge` skill — the inverse of `--refresh` — treats `architecture-principles.md`/`conventions.md` as normative and reports where the codebase drifted as graded work items (blocking/flag/note), never auto-fixing; writes stay under `.claude/.mtk-cache/` unless the engineer explicitly approves a `tasks/todo.md` append.
- **Adaptive interview from `[AMBIGUOUS]` findings.** `setup-audit` emits `.claude/.mtk-cache/ambiguities.json`; `setup-bootstrap` STEP 2.5 asks up to 3 additional questions ranked by hit count, persists resolutions under `resolved_ambiguities` in `setup-answers.json`, and never re-asks a resolved anchor.
- **Migration-aware bootstrap.** New STEP 2.7 ingests existing `.cursorrules`/`.cursor/rules`/Copilot/Windsurf/Cline/Gemini/`AGENTS.md`/`CLAUDE.md` configs as interview-grade rule candidates anchored to their source path, deduped against scan findings with contradictions routed to Needs review.
- **Verified-commands stamp.** New `scripts/verify-commands.sh` runs the build/test/format commands bootstrap is about to publish (timeboxed, list/collect-only test mode, check-mode formatting) and stamps CLAUDE.md's Tech Stack section verified/unverified; `--no-verify-commands` opts out and non-interactive runs never block on a failing command.
- **Live file references over restated facts.** Generation rules now point at canonical machine-readable files (`package.json`, lockfiles, `Directory.Packages.props`) instead of restating version/dependency facts inline, shrinking the dependency-rescan staleness surface.
- **Product-context artifacts.** New `.claude/references/product-context.md` plus bootstrap STEP 3.8 generate `product.md` (purpose/users/key flows/non-goals, ≤40 lines) and seed `decisions.md` (ADR-lite, append-only); both join the never-overwrite preservation set.
- **CI staleness gate template.** New `templates/ci/mtk-staleness-check.yml` pins the toolkit checkout to the installed version and fails the job on drift; `setup-bootstrap` STEP 4 offers to install it on GitHub-hosted repos.
- **Minimal mixed-stack support.** `secondary_stacks` recorded in `detected-tools.json`; bootstrap runs secondary-stack scan recipes for conventions and reference pruning, with the primary-stack-only workflow-skill limitation documented in both skills.

### Tests

- New `tests/hooks/test-setup-detect.sh` and `tests/hooks/test-verify-commands.sh` — fixture coverage for the new detection and command-verification scripts.
- New `tests/pressure-tests/setup-converge.md` — adversarial scenarios pressing converge to rewrite docs, auto-append todos, or claim unanchored violations.

### Hardened (dogfood findings from two production bootstrap runs)
- secret-scan.sh detects URL-embedded credentials (`scheme://user:pass@host`) with placeholder exemptions + dedicated test
- generate-agents-md.sh enforces its 60–120-line budget (headings + distillation + pointers; 140-line hard ceiling) + dedicated test
- Cross-agent config generation is now opt-in: interactive question, AGENTS.md-only default under --non-interactive
- Settings Merge defines the fresh-bootstrap path ($CLAUDE_PLUGIN_ROOT-relative hook paths) and a permission-blocked fallback (settings.json.mtk-proposed, Needs review)
- tech-stack-dotnet: dotnet publish deny-only (was contradictorily allowed+denied); dotnet test --list-tests documented for command verification
- verify-references.sh exempts known-optional boilerplate paths (settings.local.json etc.)
- setup-audit/repomap: defer-to-mcp documented as per-file enrichment; unreachable LSP treated as fallback with Provenance disclosure

### Hardened (wave 2)
- verify-claims.sh: DOC_SLUG now derives from the repo-root-relative path (falling back to basename outside the repo) so same-basename docs in different directories — e.g. per-package CLAUDE.md files — no longer clobber each other's weak-claims cache; dedicated regression test
- command-verification.md: new Tree-mutation guard — commands that mutate the tree as a side effect (e.g. a lockfile touched by `dotnet build`) are restored via `git checkout --` and reported in STEP 5
- setup-detect.sh: RN/Expo detection now also scans monorepo package dirs and first-level sibling package.json files (maxdepth 2, excluding node_modules), not just the root package.json; dedicated regression fixture
- tech-stack-dotnet: `dotnet test --list-tests` documentation is now conditional on `.sln` vs `.slnx`/Microsoft.Testing.Platform, matching the `--solution` flag Microsoft.Testing.Platform requires

## [7.18.0] - 2026-07-03

### Added — Setup refresh loop

`/mtk-setup` was strong on first run but had no coherent re-run story: `--audit` refreshed only two docs, drift detection (`audit-drift-check.sh`) had no consumer, the re-run merge could silently blend engineer edits, interview answers dissolved into generated prose, and long scans didn't survive a crash. This release closes the loop — detect → preview → scoped regen → propose diffs → gate in CI — and hardens the first run.

- **`/mtk-setup --refresh` (+ `--dry-run`).** New `setup-refresh` workflow skill: consults a per-artifact staleness plan, regenerates only what drifted (drift-scoped re-reads with a ~30% full-re-audit threshold), regenerates deterministic artifacts (AGENTS.md, tool configs, indexes), and routes every engineer-edited file through the diff-proposal contract. `--dry-run` prints the invalidation plan and writes nothing.
- **`/mtk-setup --check` + `scripts/setup-refresh-plan.sh`.** Read-only CI staleness gate: per-artifact plan (stamped-doc drift, CLAUDE.md version + dependency rescan, detected-tools TTL, AGENTS.md regenerate-and-diff, dead path references) with `--json` output; `--check` exits 1 when anything is stale, making "are the generated docs still accurate?" a one-line CI job.
- **Diff-proposal contract replaces union merge.** New `.claude/references/regen-diff-contract.md`: engineer-edited generated files are never overwritten or union-merged — the toolkit's own delta (cached ancestor template vs fresh template) is proposed hunk-by-hunk with a one-line reason each, applied only on approval; hunks that no longer apply land under Needs review with the conflicting region quoted. `setup-audit` STEP -1 and `setup-bootstrap` merge mode both delegate to it; `git merge-file --union` is gone.
- **Persisted interview (`.claude/setup-answers.json`).** Bootstrap's post-scan interview now persists answers to a committed steering file (new question 6: definition of done). Re-runs reuse prior answers and only ask new gaps; rules sourced from answers cite the file as their evidence anchor, so the verify-claims pass never auto-downgrades engineer-stated rules; scan findings that contradict an answer become Needs review items instead of silent overrides.
- **Resumable scan ledger.** `setup-audit` and `setup-bootstrap` record per-step progress (outputs + concrete summary) through `workflow-artifact.sh` (which now accepts `setup-audit`/`setup-bootstrap` types); an interrupted run under 24h old offers Resume/Start fresh/Cancel, older ones auto-archive. Large repos (>1000 tracked files) write findings to the ledger per scan category and keep only summaries in context.
- **Verify-claims retry loop + Sync Impact stamp.** Downgraded claims get exactly one re-derivation attempt (fix the evidence anchor or delete the claim) before downgrades are accepted; every re-run/refresh stamp now records `previous-stamp`, `sections-changed`, and `claims-delta: +N ~M -K` — a machine-parsable audit trail of what the refresh actually changed.

### Tests

- New `tests/hooks/test-setup-refresh-plan.sh` — fixture-repo coverage for the staleness plan: all-fresh exit 0, drift flips `--check` to exit 1, `--json` shape, dependency-rescan detection.
- New `tests/pressure-tests/setup-refresh-preservation.md` — adversarial scenarios pressing refresh to delete hand-authored files, silently overwrite engineer edits, or force-apply under non-interactive pressure.

## [7.17.0] - 2026-07-01

### Added — Borrowed capabilities, wave 3

A third competitive scan of trending (last-30-day) Claude Code toolkits surfaced 6 candidates. Two — cross-platform config export and pre-execution visual review of agent loops — turned out to already exist (`scripts/generate-agents-md.sh`/`generate-tool-configs.sh`, and `implement`'s Phase 2.5 batch rendering) once checked against the codebase; the real gaps found on inspection are what shipped for those two. The other four are net-new deltas on existing infrastructure.

- **Critical Rules in generated cross-tool configs.** `generate-agents-md.sh` and `generate-tool-configs.sh` (AGENTS.md, `.cursor/rules`, Copilot, Windsurf, Gemini, Cline) now extract the project's `CLAUDE.md` `## Critical Rules` section and lead every generated config with it — the highest-value content for a tool with no hook enforcement, previously dropped entirely.
- **`browser` evidence channel gets a capture procedure.** New `.claude/references/evidence-capture.md` documents persisting screenshots/console logs/network requests (via Playwright MCP) under `docs/specs/<slug>.evidence/<criterion-id>/` for behavior verified in a browser, with an explicit textual-fallback path when Playwright MCP is unavailable. `verification-before-completion` cross-references it and requires the evidence path be cited in the completion table.
- **`golden-path-capture` — live, in-session lesson harvesting.** New skill, distinct from `correction-capture` (engineer-issued corrections) and `lesson-mining` (after-the-fact transcript sweeps): fires when the agent itself fails the same sub-problem 2+ times and then finds a working approach, capturing the attempt immediately via the existing `learnings.sh`/`.claude/lessons/personal.md` path using the `wrong_turns`/`time_cost` fields that already existed for exactly this case.
- **Optional cryptographic release signing.** `generate-checksums.sh --sign` signs `checksums.sha256` with an Ed25519 key (`MTK_RELEASE_SIGNING_KEY`) via `openssl pkeyutl`, producing `checksums.sha256.sig`; `mtk-doctor.sh` verifies it against `MTK_RELEASE_PUBLIC_KEY` when both are configured. Fully opt-in — an unsigned release remains valid, and an unconfigured signing setup is an informational PASS, never a FAIL.
- **Gate-sequence preview at Phase 2.5.** `implement`'s approval-gate rendering now prints the full pipeline that will run against the approved batches (drift check → Stage 1 → Stage 2 reviewer set for the computed rigor level → cleanup → compound), not just the batch list.
- **`query-code-index.sh` — grep-friendly CODE_INDEX companion.** New `find <keyword>` (searches CODE_INDEX.md rows with domain context) and `callers <symbol>` (textual `git grep` reference search, explicitly not a semantic call-graph) subcommands; `prior-work-check` and `code-simplification --audit-duplicates` now use it instead of ad hoc grepping.

### Tests

- New `tests/hooks/test-query-code-index.sh` — fixture-based coverage for `find` and `callers` modes, including regression guards for fixed-string (not regex) matching and the header-row-skip anchor.
- New `tests/hooks/test-release-signing.sh` — Ed25519 sign/verify round-trip, tamper detection, and mismatched-key detection for the `--sign` opt-in.

## [7.16.0] - 2026-06-29

### Added — Borrowed capabilities, wave 2 (catalogue, dispatch, gates, context economy)

Nine capabilities surfaced by a competitive scan of trending (last-30-day) Claude Code toolkits, each a delta on existing MTK infrastructure. Two strategic items (cross-vendor judge, proxy-fidelity eval gate) were deferred to a future release as they require eval-correlation infrastructure.

- **Failure-modes catalogue extended to F1–F16.** New `F15 — Frozen-Replay / Non-Varying Evidence` (evidence that cannot fail, plus the read-only ground-truth instrument rule) and `F16 — Unverified Prose Claims` (README/changelog/sample claims, the prose-claim slice F12's doc-comment drift does not cover). Citations strengthened: F3 → USENIX'25 package-hallucination/slopsquatting, F4 → GitClear duplication data. `code-review-and-quality` reference updated F1–F14 → F1–F16.
- **Subagent dispatch hardening.** `subagent-implementation` now writes large context bundles to a file and passes the path (never argv), binds `args` as real JSON (fixes the v7.14 args-unbound crash/stall), and compresses handoffs before dispatch. Prior-batch summaries emit a dense, line-counted block so a truncated handoff is detectable.
- **Per-subagent usage envelope.** Optional `usage: {tokens, error_code}` on the batch result schema, rolled up to `results.usage` on the workflow artifact — a cost / loop-safety signal, never a gate input.
- **Frozen success criteria + tamper check.** `success_criteria[]` (`id`/`observable`/`evidence_channel`) are frozen at Phase 2.5; `verification-before-completion` runs a `git diff` tamper check before any completion claim — a moved goalpost is fail-closed and re-opens Phase 2.5 (or trips `failure_stop_gate`). Reflected in `spec-driven-development` and `orchestration-gates.md`.
- **Completion evidence table + first-verified-output baseline.** Completion is stated as a binary `criterion | verdict | evidence` table; criteria without automated tests persist a golden baseline under `docs/specs/<slug>.baselines/`.
- **Less-code ladder + safety carve-outs.** `code-simplification` gains the YAGNI ladder and a never-simplify-away list (auth, secrets, validation, migrations, delete-guards, audit logging); mirrored as a never-compress carve-out in `output-compression.md`.
- **Proactive context reset.** `context-engineering` adds a deliberate ~40%-boundary reset with a rot-symptom override (2+ of: re-reading, re-asking, contradicting a prior decision → reset now), complementing the existing 60% hard floor.
- **Post-ship Retro mode.** `lesson-mining` gains a deliberate plan-vs-actual retro that classifies each miss to its durable surface (wrong premise → context file; blind spot → plan template) and routes survivors through the reject-by-default/suggest-only discipline.
- **Provider tier slots.** `model-routing.md` adds `fast`/`default`/`strong` role slots over the concrete `haiku`/`sonnet`/`opus` tiers, so a model rename or backend swap is a one-line re-bind rather than a per-row edit.

### Tests

- New `tests/pressure-tests/verification-frozen-criteria.md` — adversarial scenarios for frozen criteria, the tamper check, and the binary completion table.

## [7.15.0] - 2026-06-25

### Added — Seven capabilities (cost discipline, context safety, loop safety, guard packs)

Seven capabilities, each a delta on existing infrastructure. Disjoint from the v7.13/v7.14 work.

- **Per-phase model routing.** New `.claude/references/model-routing.md` is the canonical tier policy — `opus` reserved for code that writes real logic and adversarial review; `sonnet`/`haiku` for discovery, planning, and structured comparison. `subagent-implementation` frames its model question with the policy default (Sonnet unless the batch is flagged novel); `context-engineering`, `planning-and-task-breakdown`, `code-review-and-quality`, and `research-context` cite it.
- **Context-budget checkpoint.** `hooks/context-budget.sh` now nudges a deliberate reset/handoff once estimated consumption (read-bytes floor) passes `MTK_CONTEXT_BUDGET_PCT`% (default 60) of `MTK_CONTEXT_WINDOW_TOKENS` (default 200000). Documented in `handoff` and `context-engineering`. Advisory, fires once.
- **Remediation circuit-breaker.** `scripts/workflow-artifact.sh remediation <uuid> <trigger> [--score N]` records fix-loop iterations and prints `ESCALATE` at `MTK_MAX_REMEDIATION_ITERS` (default 3) or on score plateau, else `CONTINUE`. Wired into `failure_stop_gate`, `code-review-and-quality`'s iteration cap, and `verification-before-completion`; new `results.remediation` artifact field and `remediation_escalated` event.
- **`smoke-boot` evidence channel.** New strongest real-execution surface ("the artifact/service boots and responds live") added to the v7.14 evidence-channel taxonomy in `verification-before-completion` and `spec-driven-development`.
- **Doc-drift linter pack.** New `hooks/linter-patterns/core/docdrift.txt` — heuristic, warning-level smells (absolute reliability claims, empty `<see cref="" />`, placeholders, empty/placeholder links, `[Obsolete]` without a message). Cross-referenced from `ai-failure-modes.md` F12/F3.
- **Phase-locked tool limits.** `brainstorming` is now `required-toolsets: [read-only]`; `research-context`, `spec-driven-development`, and `planning-and-task-breakdown` carry a written Tool-discipline note (artifacts/web only, never source code — `scope-guard` backs it). S2.20 extended.
- **Stack/domain guard packs.** Enriched `domain-finance` (anonymous endpoints, audited-record deletes, sensitive-data logging) and `stack-dotnet` (`new HttpClient`, weak hashes) packs; new `.claude/references/guard-packs.md` documents the guard-pack model as a shippable unit.

### Tests

- `tests/hooks/test-context-estimator.sh` extended with the 60%-checkpoint scenarios (SC8).
- New `tests/hooks/test-remediation-tracker.sh` and `tests/hooks/test-docdrift-pack.sh`.

## [7.14.0] - 2026-06-12

### Added — Evidence and the closed loop (14 competitive-analysis borrows, 8 batches)

- **Evidence contract.** Success criteria carry an `evidence_channel` + a binary `observable`, verified criterion-by-criterion. Any edit after verification **re-arms** all criteria (the `verify-completion` Stop hook emits a re-arm notice); behavior-shaped changes require a real execution surface, not tests alone. Named channels recorded on the workflow artifact (`criteria_status`).
- **Input hygiene.** New `read-guard` PreToolUse hook blocks secret-file reads (exit 2) with an out-of-band human approval path (no agent-runnable self-approval) and a `MTK_READ_GUARD=advisory` rollout knob; noise-directory reads advise only.
- **Claim provenance.** `[VERIFIED]`/`[ASSUMED]`/`[CITED]` tags on spec/research claims; an `[ASSUMED]` claim blocks `MTK_AUTO_PROCEED`.
- **Package-legitimacy gate.** Dependency-intake criterion 0 verifies new deps against their registry with a human checkpoint before install; dirty-worktree paths recorded as risk and `plan-gap-reviewer` rejects overlaps.
- **AI failure-modes catalogue.** F1–F14 (cited) wired into `code-review-and-quality` and `silent-failure-hunter`; new read-only `context-miner` review lane (git history, PR/issue threads, lessons) at HIGH/MAX rigor.
- **Hardened subagent dispatch contract.** TASK/DELIVERABLE/SCOPE/VERIFY; an inconclusive result never counts as pass; respawn once.
- **Closed-loop lessons.** Richer lesson template (`wrong_turns`/`time_cost`/`evolution_actions`); `learnings.sh add` optional write flags; `promote-lesson` offers a validated contribute-back PR (`validate-lesson-pr.yml` checks path/size/secret/injection and labels — humans merge, never auto-merge); new `lesson-mining` skill (reject-by-default transcript sweep, suggest-only).
- **Workflow + brainstorming.** `workflow-continuation` Stop hook nudges on unfinished workflows (advisory); brainstorming divergence mode runs isolated parallel branches under distinct cognitive frames (incl. fintech) with a critic pass and a mandatory trap register.

## [7.13.1] - 2026-06-10

### Fixed — Skill-audit remediation (full-toolkit consistency pass)

A five-reviewer audit of all 39 skills surfaced ~50 verified findings; this release fixes all of them.

- **Routing contract:** `subagent-implementation` now also dispatches on rigor score ≥ 8 (HIGH/MAX), eliminating the dispatch ping-pong with `implement` Phase 3. AUTO_PROCEED plan-trust decisions are recorded via the `gate` subcommand so `gates.plan_trust_gate` no longer sticks at `pending`.
- **`/mtk` router:** graph and route table now agree on precedence ("audit CLAUDE.md" → `claude-md-audit`); new routes for `mtk-doctor`, `promote-lesson`, `handoff`, and `pr-review-mining` (previously orphaned); `toolkit-health` keywords narrowed to usage/stats/analytics/adoption.
- **Embedded bash:** fixed the brace-glob grep in `prior-work-check` (its core duplicate-detection query silently matched nothing), a `$PATH`-clobbering loop variable in `mtk-setup`, dead code and an incomplete hook-event grep in `context-report`, and 30 `find -o` precedence bugs across setup-audit and the three tech-stack skills.
- **Spec model:** `docs/specs/baseline/` is now committed (gitignore covers working deltas only), matching the delta-spec model and repo-health asset #5; `handoff.schema.json` gains `baseline_area`/`delta`; EARS lint moved after spec persistence; spec verification checklist gains the Constitution/Claude-Ready/prior-work gates.
- **Marketplace installs:** `setup-audit` and `setup-bootstrap` resolve the manifest via `${CLAUDE_PLUGIN_ROOT}` (with `mtk-version.json` fallback) instead of project-relative reads that broke re-run detection on client installs; setup-audit's re-run example no longer shows CLAUDE.md being overwritten; mining now precedes the verify-claims pass.
- **`pre-commit-review`:** clean-pass template counts all 8 rules; check source points at generated `security.md`/`pre-commit-review-list.md` with the hardcoded items as labeled fallback; new pressure test (S2.7 gap closed).
- **Stale meta-layer:** `writing-skills` and `docs/skill-anatomy.md` caught up with S2 (type field, triggers index rebuild, toolsets, S2.13 pointer, reciprocal-reference check); S2.2 now codifies the phase-structured anatomy the validator already accepted; new S2.25 documents advisory `trigger:`/`skip_when:` keys; CLAUDE.md and AGENTS.md routing brought current.
- **Misc:** CLAUDE.md line-budget unified at 120 (context-engineering said 200), `feat/` branch prefix in using-git-worktrees, CSO single-sentence descriptions across six skills, false cross-skill integration claims corrected (research-context consumers, planning↔drift governing-constraints, prior-work-check "Phase 1.5"), residual third-party attributions removed, `analyzer-config.md` added to all three tech-stack Reference Files lists.

### Added

- **`scripts/lint-skill-bash.sh`** — lints fenced bash inside skills for three deterministic bug classes (grep brace-globs, `PATH` clobbering, ungrouped `find -o`); wired into `validate-toolkit.sh` as a fatal gate, plus a non-fatal multi-sentence-description WARN.
- **`tests/pressure-tests/pre-commit-review-pressure.md`** — adversarial scenarios for the pre-commit security gate.

## [7.13.0] - 2026-06-09

### Added — Pre-implementation consistency, scaled ceremony, release integrity

- **Cross-artifact consistency check in `plan-gap-reviewer`.** When the orchestrator passes the spec JSON sidecar and `tasks/todo.md` alongside the plan, the agent maps spec ↔ plan ↔ todo against each other in both directions: every manifest entry has a batch, every batch file is in the manifest, every success criterion maps to a batch and a test, no batch implements an out-of-scope item, and the todo matches the plan's batches. New `cross_artifact_inconsistencies` finding category — file-level mismatches, out-of-scope hits, and todo/plan divergence are BLOCKING. `planning-and-task-breakdown` step 11 now passes all three artifacts at dispatch. Pressure-test scenario 6 ("the artifacts quietly disagree") covers it.
- **Interview mode at the spec ambiguity gate.** With three or more ambiguities — or a one-to-two-sentence request for clearly multi-file scope — `spec-driven-development` switches from batched questions to a Socratic interview: one question per round, highest-leverage ambiguity first, probing intent before offering options, re-deriving the remaining ambiguities after each answer, capped at 5 rounds with explicit defaulted assumptions for anything left open. Batched mode remains the default for one or two independent ambiguities.
- **Rigor score — continuous ceremony scaling in `implement`.** A score computed from the JSON sidecar (batches, manifest size, security impact, public contracts, breaking-change scope) maps to LIGHT / STANDARD / HIGH / MAX and dials the Phase 3 path, the Stage 2 reviewer set (HIGH always runs `test-reviewer` + `architecture-reviewer`; MAX adds `silent-failure-hunter`), and `MTK_AUTO_PROCEED` eligibility (LIGHT/STANDARD only). The long-standing subagent hard triggers remain as a floor forcing at least HIGH — nothing got more lenient. The score and level are stated in the Phase 2.5 gate header so the engineer sees why the ceremony is sized the way it is.
- **Archive folds shipped contracts into `CODE_INDEX.md`.** `scripts/spec-archive.sh` now appends newly shipped public contracts to an auto-generated "Recently Shipped" section of the capability index (append-only, idempotent per slug, only when `CODE_INDEX.md` exists) — completed delta specs become living documentation instead of just an audit trail, and the next prior-work check sees them.
- **Release checksum manifest.** New `scripts/generate-checksums.sh` writes `checksums.sha256` — SHA-256 of every manifest-listed file — at release time; `--verify` recomputes and reports mismatches. `mtk-doctor.sh` verifies it when present (WARN-level: local dev changes legitimately drift; on a clean install a mismatch means the bytes are not the released bytes). New rule **S4.11** adds regeneration to the release checklist.

## [7.10.3] - 2026-05-29

### Fixed — setup-bootstrap non-destructive contract

A bootstrap run under an aggressive "replace" wrapper deleted hand-authored files it did not generate (nested per-package `CLAUDE.md`, custom `.claude/commands/*`, a custom rule file) because the skill documented intent to *preserve* hand-authored files but had no explicit *deletion* protection, and the preservation note was scoped to the monorepo path only.

- `setup-bootstrap` — added a prominent **File Preservation Policy (non-destructive contract)** at the top of the workflow: bootstrap is additive/merge-only, never `git rm`s a file it did not generate, and has no "replace mode" regardless of how it was invoked. Only MTK-owned files (provenance-stamped or known generated paths) may be overwritten in place; everything else — nested/`.claude/CLAUDE.md`, custom commands/rules/references, lockfiles, source, adopted AI configs — is preserved untouched.
- Retiring a prior MTK-owned file is the one exception and must be reported loudly under "Retired prior MTK files" in the STEP 5 report — never silent.
- Strengthened the STEP 4.5 "Not a monorepo" branch and the IMPORTANT bullet to forbid deletion (not just overwrite) of nested `CLAUDE.md` whether or not the repo is a monorepo.
- Commit hygiene: stage only declared output (never `git add -A`); scratch/run-report/review artifacts must live outside the repo tree or be git-ignored, so eval artifacts can't leak into a commit.
- STEP 5 report gains "Preserved hand-authored files" and "Retired prior MTK files" lines.

## [7.10.2] - 2026-05-29

### Changed — Opus 4.8 currency pass

Verified MTK against Opus 4.8 and current Claude Code: no breakage. Agents pin model aliases (`opus`/`sonnet`), which resolve to Opus 4.8 automatically on the Anthropic API; `effort:` and `context: fork` frontmatter remain honored keys; the deprecated-model list is still accurate. Two stale items fixed plus the one real provider gap documented.

- `docs/parallelism-patterns.md` — refreshed the example model list ("Opus 4.7, Sonnet 4.6" → "Opus 4.8, Sonnet 4.6 and later").
- `scripts/mtk-doctor.sh` — the model-ID check now notes that `model:` aliases resolve to the latest model on the Anthropic API but to **older** versions on Bedrock/Vertex/Foundry, where `ANTHROPIC_DEFAULT_OPUS_MODEL` / `_SONNET_MODEL` / `_HAIKU_MODEL` should be pinned to a full model ID. No detection-logic change; advisory only.
- `docs/specs/2026-05-29-opus-48-currency.md` — records the verification result and a forward-looking assessment of native Claude Code features MTK predates (Workflow tool, native `EnterWorktree`, `effort: xhigh`, background sessions / `/loop` / `/schedule`) for a later, deliberate adoption decision.

## [7.10.1] - 2026-05-29

### Fixed

- `scripts/verify-references.sh` — the Check-1 path scan now strips a trailing `path:line` / `path:Symbol` citation suffix before resolving, so `architecture-principles.md` line citations and `CODE_INDEX.md` `path:Symbol` entries no longer false-positive as stale. Advisory-only check; no impact on committed docs.

## [7.10.0] - 2026-05-29

### Fixed — setup bootstrap/audit grounding (9-repo evaluation)

Driven by a 9-repo bootstrap evaluation (6 C#, 3 TS) with per-repo adversarial fact-checking. The audit/bootstrap now grounds claims against code instead of asserting from thin or dead evidence:

- **Counter-example gate before absolute rules** — `setup-bootstrap` and `setup-audit` must grep for counter-examples before emitting any `NEVER`/`ALWAYS`/`all`/`every`/`must` rule; if any exist, soften to `[CONVENTION]` rather than `[ENFORCED]`.
- **Capability requires a usage site** — `setup-audit` must find an instantiation/call/registration, not a bare `using`/import/package ref, before asserting a capability or integration.
- **Security-claim grounding** — never assert a sanitization/validation/audit/secret path *exists* unless imported AND called; absence is a GAP, not a convention.
- **Reproducible counts + majority-verified conventions** — numeric claims carry the command that produced them; convention claims report the dominant form with its proportion (or `[AMBIGUOUS]`), never a cherry-picked minority.
- **Versions verbatim from manifests**, including nested/secondary `package.json`.
- **Confidence-tag grading** — directly-observable facts with a file:line citation are `[EXTRACTED]`, not under-tagged `[INFERRED]`; absence claims are `[EXTRACTED]` only with a cited zero-result command.
- `scripts/verify-claims.sh` — skips the confidence-legend block (no longer corrupts its own tag definitions), tests all anchors on a line, resolves bare filenames / `a|b` alternations / dotted paths, preserves absence claims, and writes per-doc reports.
- `scripts/repomap.sh` — scans the target repo (no longer `cd`s into its own plugin dir) and emits a stub JSON on fallback so downstream `json.load` never throws.
- `CODE_INDEX.md` seeding — template example rows marked illustrative; bootstrap populates from the audit (every `path:Symbol` verified) or writes an explicitly-empty index, never ships ghost rows.
- **React Native / Expo support** — detected in `setup-bootstrap`/`setup-audit`; `framework-patterns.md` and `performance-supplement.md` no longer pruned for RN/Expo repos and now carry RN-specific guidance; `tech-stack-typescript` covers RN/Expo markers and patterns.
- `setup-bootstrap` — AGENTS.md size budget + `git check-ignore` warning; git pre-commit hook resolves an absolute `$CLAUDE_PLUGIN_ROOT` source and guards against dangling symlinks.
- `.claude/manifest.json` — removed a duplicate `tests/hooks/test-context-estimator.sh` key.

## [7.9.0] - 2026-05-29

### Added — Session-learnings capture for CLAUDE.md

- **`claude-md-capture` skill.** A session-end reflection loop that captures context `CLAUDE.md` was missing — discovered commands, gotchas, env/config quirks, and non-obvious codebase patterns — and proposes them as minimal, append-only additions. It shows each candidate as a diff with a one-line rationale, stops for approval before any edit, and uses `Edit` (never `Write`) to honor the S1.5 protected-file rule. It is distinct from `claude-md-audit` (which re-grades existing content against a rubric) and `correction-capture` (which records engineer corrections as lessons in `lessons.md`): capture adds *new project facts* to the prompt every session loads. Routed via `/mtk` ("save what we learned to CLAUDE.md", "update CLAUDE.md with this session"). Ships with `tests/pressure-tests/claude-md-capture-pressure.md` covering anti-manufacture, the approval gate, personal-vs-team routing, append-not-rewrite, the 120-line budget, and the no-CLAUDE.md redirect.
- **`.claude.local.md` support in `setup-bootstrap`.** Bootstrap now adds the personal, opt-in `CLAUDE.md` companion to `.gitignore` (idempotent; never auto-created) so per-engineer preferences and machine-specific notes stay out of git. `claude-md-capture` writes personal learnings here.
- **Bootstrap completion tip.** The setup completion summary now surfaces the `#` mid-session shortcut (append a learning to `CLAUDE.md` instantly) and `claude-md-capture`, so teams know how to keep project memory current over time.

### Changed

- `/mtk` router — new route-table row and decision-graph node for `claude-md-capture`; the "no" branch of the CLAUDE.md-audit diamond now flows to the capture diamond before falling through to help.
- `setup-bootstrap/SKILL.md` — `.gitignore` step covers `.claude.local.md`; STEP 5 completion summary adds the keep-CLAUDE.md-fresh tip.
- **`setup-bootstrap/SKILL.md` slimmed 1000 → 831 lines** via progressive disclosure (S2.10). Extracted the monorepo per-package template, generation rules, and root Monorepo Layout block to `.claude/references/monorepo-bootstrap.md` (read on-demand only when a monorepo is confirmed), and the three per-stack reference-customization tables to `.claude/references/bootstrap-customization.md`. Compressed the dotnet-claude-kit companion note, deduped the repeated 60–80/120-line budget rule, and removed the duplicate `mkdir`/`.claude/tech-stack` warning. Moved the per-stack pre-commit-review item lists into each tech-stack skill's new `## Pre-Commit Review Items` section (bootstrap now reads and filters by detected tool); the three stack-agnostic always-include items stay inline. Extracted STEP 3.5a's inline reference-existence checks (directory `test -d`, `.csproj` existence, framework dump, `.sln` membership-vs-disk) into the new `scripts/verify-references.sh` — STEP 3.5a now calls it and keeps the stale-handling policy and the "never infer disk presence" rule inline. No capability change — detection logic, gates, and grounding all stay inline.

### Added — Bootstrap reference companions

- `.claude/references/monorepo-bootstrap.md` and `.claude/references/bootstrap-customization.md` — on-demand companions for `setup-bootstrap`, registered in the manifest and distributed to target repos.
- `scripts/verify-references.sh` — read-only checker that flags directories, `.csproj` projects, and `.sln` members referenced in generated docs that don't exist on disk (exit 3 if any stale). Distinct from `verify-claims.sh` (which downgrades zero-hit rule tags). The directory scan only considers path-like tokens inside backtick code spans (resolved against root, `src/`, and the git index), so prose tokens like `REST/`, `I/O`, or npm scopes don't false-positive.

## [7.7.0] - 2026-05-18

### Added — Decision provenance and end-to-end wiring verification

- **Decision-origin tagging.** Every entry in the structured learnings store and every reviewer finding carries a `decision_origin` field with one of five values: `user-directed`, `claude-recommended-approved`, `claude-recommended-modified`, `claude-recommended-rejected`, `system-inferred`. The schema for learnings (`.claude/references/learnings-schema.md`) and the review finding schema (`.claude/references/review-finding-schema.md`) are both extended. Tagging is mandatory at capture time — entries without `decision_origin` are rejected by `scripts/learnings.sh add` and by the review-output validator.
- **Sycophancy index (π).** New `scripts/learnings.sh metrics` computes `π = approved / (approved + modified + rejected)` over the last 30 days. A value ≥ 0.70 raises a warning that the model's recommendations are being accepted without enough pushback. Threshold is tunable via `.claude/review-config.json`. Surfaced in `toolkit-health` and in the weekly analytics report.
- **Wiring check as Definition of Done.** `verification-before-completion` adds a `wiring` step that runs `bash scripts/validate-toolkit.sh --task-scoped <files>` and treats any unwired file as a hard fail. The new task-scoped mode verifies, for each touched skill / hook / agent / reference: frontmatter `name:` matches the directory; the file is registered in `manifest.json`; hooks are `chmod +x` and referenced from `settings.json`; agent files appear in `.claude-plugin/plugin.json`; reference files are in `.claude/references.index`. Authoring without wiring no longer counts as "done".

### Changed

- `verification-before-completion/SKILL.md` — adds the `wiring` step and a Red Flags entry for "authored but not wired".
- `validate-toolkit.sh` — new `--task-scoped <file1,file2,...>` mode and `--strict-decision-origin` flag for learnings/review outputs.
- `scripts/learnings.sh` — new `metrics` subcommand; `add` rejects entries missing `decision_origin`.
- `.claude/review-config.json` — new `sycophancy_index.warn_threshold` (default `0.70`) and `decision_origin.required` (default `true`).
- `toolkit-health/SKILL.md` — reports π alongside existing usage stats; warns at threshold.

## [7.6.0] - 2026-05-18

### Added — Claude-Ready spec gate, prior-work check, drift breadth

- **INVEST+C Claude-Ready checklist.** New 16-item gate at `.claude/references/claude-ready-checklist.md` covers the classic INVEST story-quality dimensions plus a "+C" Claude-Ready dimension (concrete file paths, named pattern references, runnable verification commands, explicit out-of-scope, declared dependency intake, public-contract enumeration, etc.). `spec-driven-development` Phase 1 (step 8b) scores the draft against the list before the approval prompt; specs scoring ≤13/16 are sent back to draft and reviewers cite failing item numbers so revisions are targeted.
- **`prior-work-check` skill.** Three deterministic queries — `search_prior_work`, `get_constraints`, `get_risk_profile` — run before spec approval and again at planning if the spec is stale. The skill greps source (and `CODE_INDEX.md` when present) for the capability under multiple keywords, reads `tasks/lessons.md` and `architecture-principles.md` for governing constraints, and classifies every path in the change manifest by risk category (`regulated`, `boundary`, `shared`, `isolated`). A mis-classified `security_impact` becomes a BLOCK finding rather than passing silently into review.
- **Context fatigue signals.** Four lightweight signals added to `context-engineering`: token utilization (40%), scope scatter (25%), re-read ratio (20%), error density (15%). When two or more signals are elevated the skill prescribes a prune-then-re-summarize, or an escalation to `handoff`. The handoff template gains a `## Fatigue Signals` block so the next session knows which parts of the half-done state to mistrust.
- **Drift breadth — three new axes in `spec-drift-detection`.** Ownership (cross-slice creep — warning, escalates to critical when the crossed slice is regulated), dependency-shift (undeclared package adds in lockfile / project file — critical), usage (renamed or removed public contract with surviving call-sites — critical). The dependency-shift axis cross-checks against the Claude-Ready +C #6 intake declaration.
- **`CODE_INDEX.md`.** Capability-oriented index of the codebase, organized by what the code does rather than where it lives. Template at `.claude/references/code-index-template.md`. Seeded by `setup-bootstrap` from the audit scan and consumed by a new `code-simplification --audit-duplicates` mode that clusters near-duplicate entries for consolidation.

### Changed

- `spec-driven-development/SKILL.md` — adds steps 8b (Claude-Ready scoring) and 8c (prior-work invocation); spec output gains a `## Prior Work Check` section.
- `planning-and-task-breakdown/SKILL.md` — step 1a re-runs `prior-work-check` if the spec's check is stale (different branch HEAD or different day).
- `spec-drift-detection/SKILL.md` — adds ownership / dependency-shift / usage rows to the findings table, severity mappings, and verification checklist items.
- `context-engineering/SKILL.md` — new `## Context Fatigue Signals` section above the budget tracker.
- `handoff/SKILL.md` — step 1a reads fatigue signals; output template gains a `## Fatigue Signals` block.
- `code-simplification/SKILL.md` — new `## Mode: --audit-duplicates` section consuming `CODE_INDEX.md`.
- `setup-bootstrap/SKILL.md` — STEP 4.95 seeds `CODE_INDEX.md` from the audit scan.

## [7.5.0] - 2026-05-08

### Added — EARS+ANT requirements, scored review, dependency gate, structured learnings

- **EARS notation + ANT test in spec authoring.** `spec-driven-development` now requires every requirement-bearing bullet under `## Requirements` to use EARS phrasing (Ubiquitous / Event-driven / State-driven / Optional / Unwanted) and pass the Anti-Null-Tautology check (a requirement that cannot be falsified carries no information). New `scripts/lint-ears.sh` runs as part of spec authoring and `spec-drift-detection` — flags non-EARS bullets and tautological phrasing ("be reliable", "follow best practices", "as needed").
- **Scored adversarial evaluator in code review.** `compliance-reviewer` and `code-review-and-quality` now emit per-dimension 1–10 scores across `correctness`, `security`, `test_coverage`, `architecture_fit`, and `simplicity` with mandatory `file:line` evidence quotes. Auto-fail rules: any dimension < 7 → `NEEDS_CHANGES`; uniform scores → rejected as `non-discriminating`; missing evidence → score treated as 0. Remediation capped at 2 iterations on the same blocking dimension; third escalates to a human. Schema extended in `.claude/references/review-finding-schema.md` with a new `scores` block. Workflow artifact gains optional `results.review_scores.<dim>` and `results.review_iteration` fields.
- **Dependency-introduction gate.** New `.claude/references/dependency-intake-checklist.md` defines a 5-criteria rubric — scope, maintenance, size, security, license — each scored Good / Acceptable / Poor with required evidence (CVE id, last-release date, license SPDX). Two `Poor` ratings on a single new dependency block; one `Poor` requires explicit override. Wired into `pre-commit-review` (detects `package.json`, `*.csproj`, `requirements.txt`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `Gemfile`, `composer.json` changes) and `security-and-hardening` (supply-chain step).
- **Spec-linked structured learnings.** New `.mtk/learnings.jsonl` (gitignored, JSON Lines for pure-bash tooling per S3.3) is the machine-readable mirror of `tasks/lessons.md`. Schema in `.claude/references/learnings-schema.md`: `{id, spec_id, workflow_uuid, scope, source, captured_at, files, directories, phase, severity, validity, recurrence, title, body, rule, applies_when}`. New `scripts/learnings.sh` provides `add | query | regen-markdown | migrate | list`. The `query` subcommand applies a 5-layer retrieval filter (proximity / recurrence / severity / validity / phase) used at the start of `spec-driven-development` and `fix`. `correction-capture` and `promote-lesson` now write through `learnings.sh add` first, then regenerate the markdown view. The committed `tasks/lessons.md` remains the team-canonical store; manual edits are preserved across regen.

### Changed

- `spec-driven-development/SKILL.md` — added `## Requirements Format (EARS)` section, ANT self-check step, lessons retrieval via `learnings.sh query`, EARS lint verification line.
- `spec-drift-detection/SKILL.md` — runs `lint-ears.sh` against the spec markdown; EARS / ANT violations emitted as `severity: warning`, `confidence: 100`, `source: "drift"` findings.
- `code-review-and-quality/SKILL.md` and `compliance-reviewer.md` — new "Score the Five Dimensions" step with rubric, auto-fail rules, iteration cap, and workflow-artifact integration.
- `pre-commit-review/SKILL.md` — new dependency-intake step (4.7) with manifest-file detection.
- `security-and-hardening/SKILL.md` — new supply-chain step referencing the dependency-intake checklist.
- `correction-capture/SKILL.md` — captures structured + markdown forms; structured form drives 5-layer retrieval.
- `promote-lesson/SKILL.md` — appends through `learnings.sh add --scope team --source promotion`, regenerates markdown.
- `fix/SKILL.md` — calls `learnings.sh query --phase implement` instead of flat lessons scan.
- `tasks/lessons.md` — added mirror note pointing at `.mtk/learnings.jsonl`; existing entries preserved verbatim and seeded into the structured store.

## [7.4.0] - 2026-05-07

### Added — Durable orchestration and anti-anchored review

- **Durable workflow artifacts.** New `workflow-artifacts` skill plus `scripts/workflow-artifact.sh` helper persist orchestration state under `.mtk/workflows/{uuid}.json` (overwritten in place) and `{uuid}.events.jsonl` (append-only). Schema in `.claude/references/workflow-artifact-schema.md`. State lives outside `.claude/` to escape Claude Code's sensitive-file gate. `.mtk/` added to `.gitignore`. Wired into `implement` Phase 0 (init/resume), spec/plan persistence (`results.spec_path`, `results.plan_path`), Phase 2.5 (`plan_trust_gate`), Phase 3 (`phase_exit_gate` + per-batch progress), and Phase 7 (`memory_sync_gate` + `status=completed`).
- **Five named orchestration gates.** `.claude/references/orchestration-gates.md` defines `plan_trust_gate`, `phase_exit_gate`, `failure_stop_gate`, `memory_sync_gate`, `skill_precedence_gate` as fail-closed contracts the implement workflow records before advancing. Skipping a gate is treated the same as advancing on `fail`. Cited from `incremental-implementation`, `planning-and-task-breakdown`, `spec-drift-detection`.
- **Anti-anchored plan reviewer.** New `plan-gap-reviewer` agent (`.claude/agents/plan-gap-reviewer.md`) is forbidden from loading `tasks/lessons.md`, prior reviewer output, or the workflow artifact — bias sources. Six finding categories (`repo_mismatches`, `missing_surfaces`, `execution_order_issues`, `hidden_assumptions`, `under_scoped_integrations`, `open_decisions_presented_as_settled`) with `BLOCKING` / `ADVISORY` severity. Wired into `planning-and-task-breakdown` step 11 before the Phase 2.5 gate. Pressure test covers persuasive prose, conflicting lessons, phase-order bugs, missing route registries, and tone contamination.
- **Claim extraction in verification.** `verification-before-completion` now requires extracting every factual claim from upstream agents (builders, reviewers, integration verifiers), marking each `UNVERIFIED`, and reconciling to `VERIFIED` / `CONTRADICTED` / `UNVERIFIABLE` before completion. A claim that affects the verdict and stays `UNVERIFIED` is a stop condition. New pressure test scenario 5b exercises the rubber-stamp failure mode.
- **JSON router-decision fixtures.** Six fixtures under `tests/fixtures/` (`build-happy-path`, `build-phase-blocked`, `plan-gap-found`, `failure-stop-triggered`, `auto-proceed-respects-decisions`, `resume-active-workflow`) exercise the orchestrator's documented decisions. `scripts/run-fixtures.sh` structurally validates each fixture: gate names must come from `orchestration-gates.md`, `next_action` must be one of six documented actions, `abort` requires `failure_stop_gate: fail`, every fixture needs a non-trivial rationale. Wired into `validate-toolkit.sh`.
- **`MTK_AUTO_PROCEED` env knob.** Opt-in (off by default) lets the orchestrator default the recommended option on the Phase 2.5 approval gate only when ALL hold: spec has zero open decisions, no plan-gap-reviewer `BLOCKING` findings, `skill_precedence_gate` is `pass`, scope is not breaking change or high `security_impact`. Otherwise falls back to `AskUserQuestion`. Never overrides explicit user standards, open plan decisions, or `failure_stop_gate`. Documented in `setup-bootstrap`, root `CLAUDE.md` routing table, and the gates reference.

### Changed

- `implement/SKILL.md` Phase 0 inits or resumes a workflow artifact; Phase 1 records `results.spec_path`; Phase 2 records plan/todo paths; Phase 2.5 records `plan_trust_gate` decision and supports `MTK_AUTO_PROCEED`; Phase 3 records per-batch `phase_exit_gate`; Final Report closes `memory_sync_gate` and emits `workflow_completed`.
- `validate-toolkit.sh` runs `scripts/run-fixtures.sh` whenever fixtures exist.
- README "What's New" and "Skills" counts updated for the new skill and agent (32 skills, 4 reviewer agents).

## [7.3.0] - 2026-05-07

### Added — Subagent-driven implementation and decision graphs

- **GraphViz `dot` decision graphs** added inside `mtk/`, `fix/`, and `spec-driven-development/` SKILL.md. Each graph encodes the exact branch points where models most often misroute (router ambiguity, fix scope-guard escalation, spec skip-vs-write + `security_impact` honesty), accompanied by a Red Flags rationalization table. Models follow visual decision flow more reliably than equivalent prose. Anatomy preserved per S2.2 — graphs live inside existing `## Workflow` / Route Table sections.
- **`subagent-implementation` skill.** New per-batch implementer-subagent path for large features. Phase 3 of `implement` now forks: above the threshold (≥3 batches OR ≥6 files OR non-none `security_impact`) it dispatches the new skill; below threshold it stays on inline `incremental-implementation`. The new skill asks once via `AskUserQuestion` for implementer model (Sonnet/Opus), then loops one fresh subagent per batch with a structured JSON contract (`actual_files`, `build`, `tests`, `behavioral_diff`, `deviations`). Drift micro-check is orchestrator-side and synchronous: in-package extra files auto-amend the sidecar, cross-package or new-public-contract drift re-opens Phase 2.5. Phase 3.5 spec-drift and Phase 4 two-stage review run unchanged. Pressure test covers 10 adversarial scenarios.

### Changed

- `implement/SKILL.md` Phase 1 explicitly delegates ambiguity resolution to the spec skill's pre-draft gate — Phase 2.5 is a go/no-go on a fully-informed plan, not the place to surface new questions for the first time.
- `spec-driven-development/SKILL.md` decision graph includes an explicit `ambig?` diamond before drafting; clarifying questions go through `AskUserQuestion` upfront.

## [7.2.0] - 2026-04-27

### Added — Ignore syntax, confidence-tagged audit, MCP expansion

- **`.mtkignore`** at repo root — single source of truth for paths excluded from MTK scans. Same syntax as `.gitignore`. Loader at `hooks/lib/mtkignore.sh`; tree-sitter walker reads it directly. `setup-bootstrap` generates a starter file. New rule **S1.14**.
- **Confidence-tagged audit principles.** `setup-audit` emits `[EXTRACTED]`, `[INFERRED:0.0–1.0]`, or `[AMBIGUOUS]` tags plus evidence pointers. `spec-drift-detection` uses tags as a severity gradient: EXTRACTED blocks, INFERRED ≥0.7 flags, INFERRED <0.7 / AMBIGUOUS notes. Merge mode downgrades on disagreement. Pressure test in `tests/pressure-tests/spec-drift-tags.md`. New rule **S1.15**.
- **Shrink-guarded writes.** `hooks/lib/shrink-guard.sh` refuses rewrites that shrink targets >50% bytes or >20% lines (override: `MTK_SHRINK_GUARD_OVERRIDE=1`). Wired into `build-references-index.sh`, `setup-audit`, `correction-capture`. 17-case fixture test. New rule **S3.16**.
- **MCP server expanded** to 7 tools (was 2). Added read-only `mtk_manifest`, `mtk_analytics`, `mtk_audit` (parses tagged principles), `mtk_references_index`, `mtk_active_stack`. Read-only enforced by validator grep gate. Server bumped to 0.2.0. `hooks/session-start` rebuild trigger now fires on `mcp/src/**` mtime change. Bash fallbacks documented in `docs/integrations/mtk-mcp.md` (S3.12).
- **Post-commit auto-refresh.** `hooks/git-hooks/post-commit-refresh.sh` (opt-in) rebuilds derived artifacts via `scripts/refresh-derived.sh` when their inputs change. Silent on no-op, never blocks.

### Added — Review schema hardening, silent-failure hunter, skill eval harness

- **False-Positive Exclusion List** added to `.claude/references/review-finding-schema.md`. Seven explicit categories (pre-existing issues, linter-catchable items, unjustified style nits, justified silences, plausibly-intentional behavior shifts, generic concerns, unloaded-context guesses) that are dropped before confidence scoring rather than scored low. Wired into `code-review-and-quality` and `compliance-reviewer`. The 0–100 confidence rubric, threshold filtering, anti-inflation, and anti-sandbagging machinery already shipped in 7.0.x — this completes the picture.
- **`silent-failure-hunter` reviewer agent.** New `.claude/agents/silent-failure-hunter.md` with explicit pattern catalogue (catch/promise/fallback/silenced-diagnostic/test-erosion), severity-by-path mapping (audited paths → Critical), and single-lens FP discipline. Dispatched conditionally from `code-review-and-quality` when the diff matches error-handling tokens (`catch`, `except`, `?.`, `??`, `eslint-disable`, `Skip =`, `it.skip`, etc.) — runs in parallel with `compliance-reviewer`. Pressure test ships with 7 adversarial scenarios.
- **Skill eval harness** at `scripts/skill-eval/`. Pure-bash runner (`run-eval.sh`) invokes Claude Code non-interactively per prompt, then grades each response with a Haiku sub-agent against per-prompt assertions. `aggregate.sh` runs N iterations and reports pass-rate plus standard deviation. Starter eval set ships for `code-review-and-quality` (7 prompts covering FP discipline, confidence threshold, output schema, dispatch triggers). Results written to `evals/results/<skill>/` (gitignored).
- **`claude-md-audit` skill.** New re-grade loop for existing `CLAUDE.md` files — six-criterion rubric (commands, architecture, gotchas, conciseness, currency, actionability), phase-2 currency cross-checks (broken commands and stale paths), append-only diffs gated on user approval. Distinct from `setup-bootstrap` (one-time creation) and `setup-audit` (architecture principles). Honors S1.5 — never `Write`-overwrites CLAUDE.md, never auto-deletes content, never produces wholesale rewrites. Routed via `/mtk` (`audit claude.md`, `is claude.md still good`, `memory rot`). Pressure test covers 7 scenarios including anti-sandbagging and refuse-rewrite.

### Fixed

- **`scripts/generate-agents-md.sh` no longer clobbers hand-curated `AGENTS.md`.** The generator now refuses to overwrite a file that does not carry its own `Auto-generated by MTK` marker, falls back to writing `AGENTS.generated.md` instead, and prints a warning. The toolkit's own root `AGENTS.md` is a curated routing guide (Mermaid tree, two-stage review model) that the generator was destroying on every run. New `--force` flag escapes the safety check.

## [7.1.0] - 2026-04-23

### Added — Versioned specs, context budget, footprint reporting

- **Versioned specs.** `spec-driven-development` now detects existing specs with the same date+slug and writes `-v2`, `-v3`, etc. instead of overwriting. JSON sidecars, plan files, and handoff artifacts use the same version suffix. `context-report` lists all versions grouped by slug.
- **Context load estimator.** `context-budget.sh` accumulates `bytes_read` for unique files read per session (capped at 100k/file). `session-analytics.sh` computes `estimated_context_tokens = bytes_read / 4` and persists both fields to `analytics.json`. `analytics-report.sh` surfaces estimated context tokens in its output.
- **Context footprint reporting.** `context-engineering` now emits a per-phase footprint block after reference loading (lines + estimated tokens per file, totals row). Engineers can see the cost of what was loaded each phase.

## [7.0.0] - 2026-04-23

### Breaking

- **`--audit` re-run contract changed.** Re-runs now perform a 3-way merge (`git merge-file --union`) between the previous template (cached in `.claude/.mtk-cache/v<version>/`), the freshly generated template, and the on-disk file. Scripts that relied on `--audit` clobbering local edits need to update. First v7.0.0 run on a pre-v7 repo prompts the engineer to classify existing files as `hand-edited` or `stock` before merging.
- **Reference file frontmatter normalized.** Every `.claude/references/**/*.md` now requires `description` / `globs` / `alwaysApply` fields. Legacy `paths:` lists have been renamed to `globs:`. Any tooling that reads raw reference files needs to strip frontmatter or skip it.
- **Manifest schema extended** with a top-level `coding-guidelines` object (`repo`, `sha`, `files`) pinning the `moberghr/coding-guidelines` revision. `setup-bootstrap` no longer fetches from `main` — it reads the pinned SHA from the manifest and verifies sha256 after download.

### Added — reproducibility (G1)

- **Pinned coding-guidelines SHA** in `.claude/manifest.json`. `setup-bootstrap` verifies sha256 and aborts on mismatch. CLAUDE.md emits a mandatory HTML-comment footer recording version, pinned SHA, and generation timestamp — consumed by the re-run merge logic.
- **`/mtk-setup --update-guidelines`** — bumps the pinned SHA to current HEAD, refreshes sha256 hashes, prints a diff summary; does not auto-apply.

### Added — output quality guards (G2, G3)

- **`scripts/secret-scan.sh`** — pre-write grep-based detector with 10 patterns (AWS, Azure, GitHub, Slack, Anthropic, OpenAI, private keys, password assignments, IBAN, JWT). `setup-bootstrap` STEP 3.5c blocks any `Write` on match. `--self-test` asserts patterns against `tests/fixtures/known-secrets.txt`. Escape hatch: `MTK_SECRET_SCAN_SKIP=1`.
- **`scripts/count-tokens.sh`** + preview table — preview shows per-file `LINES / ~TOKENS / STATUS` before writing. The 120-line CLAUDE.md hard cap is now enforced (previously documented-only) by both the skill and the validator.

### Added — reference routing (G4)

- **Reference frontmatter** — all 28 files under `.claude/references/` now carry `description`, `globs`, `alwaysApply`.
- **`.claude/references.index`** — tab-separated index generated by `scripts/build-references-index.sh`; gitignored. `--check` mode validates sync.

### Added — versioned re-runs (G5)

- **`.claude/.mtk-cache/v<version>/`** — template snapshot layer seeded by `setup-bootstrap` STEP 4.8. Retention: last 2 versions.
- **Versioned 3-way merge in `setup-audit`** STEP -1 — classifies runs, prompts on pre-v7 migration, merges per file, leaves conflict markers on conflicting paths (no silent overwrite). Protected files always skipped.

### Added — deterministic audit input (G6)

- **`scripts/repomap.sh`** + **`scripts/repomap-tree-sitter.py`** — symbol graph extractor with three-tier degradation (.NET csharp-lsp MCP → tree-sitter → LLM-only fallback). Rank by in-edge count; binary-search to fit a configurable token budget.
- **Audit prompt changed** — instructs the LLM to cite at least one symbol per principle. Mandatory `## Provenance` section in `architecture-principles.md` records repomap fit tier, symbol count, and symbol-to-principle evidence table. When repomap falls back, provenance explicitly discloses the audit degraded to scan-recipes-only.

### Added — pressure tests

- **`tests/pressure-tests/mtk-setup-rerun.md`** — 8 adversarial scenarios covering re-run semantics and cache handling.

### Changed

- `scripts/validate-toolkit.sh` — new assertions: CLAUDE.md ≤120 lines, every reference has required frontmatter, `.claude/references.index` in sync.
- `.gitignore` — adds `.claude/references.index` and `.claude/.mtk-cache/`.

## [6.5.0] - 2026-04-22

### Added — Toolset scoping, keyword triggers, typed handoffs

- **Task-class toolset scoping** — new `.claude/toolsets/*.yaml` registry (`read-only`, `git-safe`, `code-edit`) with `extends:` inheritance. Skills and agents may declare `required-toolsets:` / `forbidden-toolsets:` in frontmatter; `/mtk` router expands them into `allowed-tools` on dispatch. `scripts/resolve-toolsets.sh` flattens the DAG (bash 3.2 compatible, no jq). Seeded on `compliance-reviewer`, `architecture-reviewer`, `test-reviewer`, and `spec-drift-detection`. New rules S2.19–21.
- **Keyword-triggered skill hints** — skills may declare `triggers: [kw1, kw2]` in frontmatter. `scripts/build-triggers-index.sh` generates `.claude/triggers.index`; `hooks/lib/trigger-hints.sh` (sourced by the existing UserPromptSubmit dispatcher) grep-scans the prompt and surfaces `💡 consider skill: X (matched: kw)` nudges. Seeded on `security-and-hardening`, `debugging-and-error-recovery`, `test-driven-development`. New rules S2.22–24.
- **Typed handoff artifacts** — new `.claude/schemas/handoff.schema.json` codifies the shared spec→plan→implement contract. `spec-driven-development` already emitted the spec sidecar; `planning-and-task-breakdown` and `incremental-implementation` now append typed `plan` and `implement` sections to the same `docs/specs/<date>-<slug>.json`. `scripts/validate-handoff.sh` performs deterministic file-level and security-impact drift detection (no jq, no git hard-dependency). `spec-drift-detection` now prefers this path over judgment-based diffs.

### Changed

- Validator (`scripts/validate-toolkit.sh`) now enforces: every `required-toolsets` / `forbidden-toolsets` reference resolves to a real `.claude/toolsets/*.yaml`, `.claude/triggers.index` is in sync with skill frontmatter, and all new scripts/hooks are present and executable.

## [6.3.3] - 2026-04-23

### Fixed
- **Plugin manifest duplicate hooks entry** — removed `"hooks": "./hooks/hooks.json"` from `.claude-plugin/plugin.json`. Claude Code auto-loads `hooks/hooks.json` from the plugin root, so the explicit reference produced a `Duplicate hooks file detected` error on `/reload-plugins`. `manifest.hooks` is reserved for *additional* hook files only.

## [6.3.1] - 2026-04-20

### Added
- **Recommended Tooling references** — new `.claude/references/recommended-tooling.md` (stack-agnostic) plus `{dotnet,python,typescript}/recommended-tooling.md`. Curated list of MCP servers (context7, playwright, csharp-lsp, microsoft-learn, github, atlassian, jetbrains, gitnexus), plugins (claude-mem, dotnet-claude-kit, pr-review-toolkit, visual-explainer, frontend-design), and editor integrations (Claude for Chrome, Claude Code IDE extensions, Pyright/Ruff/TS/Biome LSPs) that noticeably boost Claude Code productivity.
- **`setup-bootstrap` prints recommended tooling** — new "Recommended Tooling" sub-block in STEP 4 prints the shared + stack-specific references verbatim during bootstrap. **Recommend-only** — MTK never auto-installs MCPs or plugins on behalf of the engineer.
- **Tech-stack skills link to recommended tooling** — `tech-stack-dotnet`, `tech-stack-python`, and `tech-stack-typescript` each gain a `## Recommended Tooling` section pointing at their stack-specific reference.

## [6.3.0] - 2026-04-17

### Added (Opus 4.7 modernization)
- **Parallelism patterns** — new `docs/parallelism-patterns.md` reference documenting parallel reference loading, reviewer fan-out, and deferred-tool batch hydration. `implement`, `fix`, and `context-engineering` skills now explicitly direct parallel loading in their load-context phases.
- **Parallel Stage 2 review** — `/mtk implement` Phase 4 Stage 2 now spawns `test-reviewer` and `architecture-reviewer` in a single message, halving wall-clock review time.
- **`fix` self-escalation** — `fix` Scope Guard now self-invokes `/mtk implement` when scope grows beyond 3 files (via escalation marker), instead of stopping silently. Router recognizes `escalated from fix` as a fast-path to `implement`.
- **Cache-stable prefixes** — new `## Cache-Stable Prefixes` section in `writing-skills` documents invariants-first ordering for prompt caching. The three reviewer agents (`compliance`, `test`, `architecture`) now declare `context: fork` and carry a stable preface comment, for consistent isolation and higher cache hit rate across sessions.
- **`toolkit-health` skill** — new read-only diagnostic that reads `.claude/analytics.json` and reports session trends, specs/lessons ratios, and anomaly flags with suggested actions. Includes pressure test (`tests/pressure-tests/toolkit-health-pressure.md`) covering corrupt analytics, stale data, empty state, and noise-to-anomaly pressure. Routed via `/mtk health` / `/mtk usage stats`.
- **Route priority** — `/mtk` router now routes unambiguous inputs silently (no disambiguation question), with a new row for `toolkit-health` and a fast-path row for fix→implement escalations.
- **Manifest version sync** — `.claude/manifest.json` bumped 6.2.0 → 6.3.0 to match `plugin.json` and `marketplace.json` (fixes pre-existing drift that `validate-toolkit.sh` now catches consistently).

### Changed (breaking for muscle memory, not for functionality)
- **Consolidated to two user-invocable entry points:** `/mtk` (natural-language router) and `/mtk-setup` (bootstrap + audit dispatcher). Previous slash commands (`/mtk:implement`, `/mtk:fix`, `/mtk:pre-commit-review`, `/mtk:setup-bootstrap`, `/mtk:setup-audit`) are now workflow skills reached through the `/mtk` router — e.g., `/mtk fix the null check`, `/mtk review before commit`.
- `setup-bootstrap` and `setup-audit` merged behind the new `/mtk-setup` entry point (`--audit` flag re-runs audit, `--merge` unifies multi-repo audits).
- Pre-commit git hook still works unchanged — it invokes the linter directly, not the skill.

### Removed
- **`/mtk:setup-update` skill** — updates now flow through the Claude Code plugin manager, not an in-repo command. Removed associated pressure test.

### Migration
- Old: `/mtk:setup-bootstrap` → new: `/mtk-setup`
- Old: `/mtk:setup-audit [--merge]` → new: `/mtk-setup --audit [--merge]`
- Old: `/mtk:implement <feature>` → new: `/mtk <feature>`
- Old: `/mtk:fix <description>` → new: `/mtk fix <description>`
- Old: `/mtk:pre-commit-review` → new: `/mtk review before commit`
- Old: `/mtk:setup-update` → use the plugin marketplace to upgrade

## [Unreleased]

### Added
- **Deterministic analysis layer** (Wave 4): Roslyn/ruff/tsc analyzer configuration references, build output parser (`hooks/parse-build-diagnostics.sh`), severity mapping files. Four finding sources now merge uniformly: linter, analyzer, ai, drift.
- **Distribution & updates** (Wave 5): Version stamps (`.claude/mtk-version.json`), settings.json merge script, version drift detection in session-start.
- **MCP codebase intelligence** (Wave 6): Optional MCP server for deterministic reference resolution and solution structure awareness. Bash fallbacks for all MCP tools.
- **Cross-agent portability** (Wave 2): `scripts/generate-agents-md.sh` generates portable AGENTS.md for Cursor, Copilot, Gemini, Codex.
- **CI pipeline** (Wave 3): GitHub Actions workflow for automated validation on PRs.
- **Strengthened reviewers** (Wave 1): test-reviewer and architecture-reviewer now have confidence scoring, anti-rationalization tables, and anti-inflation rules matching compliance-reviewer rigor.
- Stale evidence threshold in verification-before-completion (timestamp-based, not gut feel)
- Behavioral diff advisory hook
- Pressure tests for test-reviewer and architecture-reviewer

## [6.1.3] - 2026-04-14

### Fixed
- Use user-invocable frontmatter to control skill visibility
- Improve setup-bootstrap precision and limit user-invocable skills to 6
- Remove duplicate hooks key from plugin.json

## [6.1.0] - 2026-04-13

### Changed
- Commands merged into skills per Claude Code v2.1.101
- All entry points now live in `.claude/skills/`
