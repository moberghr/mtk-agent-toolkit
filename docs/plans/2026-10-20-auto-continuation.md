# Auto-continuation ("MTK Relay") — session analysis and proposal — 2026-10-20

Status: **approved 2026-10-20. Start with PR-1, then PR-2, then PR-3 (dashboard), then stop and report.** PR-4 and later need a separate go.

Decisions (Mirko, 2026-10-20):
1. Compaction window is **300k**.
2. Relay legs run with `--permission-mode auto --permission-prompts none`. Push and draft PRs are opt-in at the gate; merge and deploy are never allowed.
3. Start with PR-1 and PR-2.
4. Make `implement`, `fix` and `batch-fix` typable. This was my recommendation and Mirko deferred to it: whoever types `/mtk:implement` has already made the routing decision, so a rejection only costs a turn. The router stays for natural language.
5. **The dashboard moves into MTK** (R5, shipped as PR-3). It shows status, context and cost, and replaces the personal `dashboard-builder` agent and the "Progress Dashboard" rule in `~/.claude/CLAUDE.md`.

Baseline: `origin/main` @ 1523a72 (9.2.0). It already ships handoff frontmatter (`state` open/accepted/expired, `branch`, `worktree`, `expires`), `scripts/handoff-state.sh` (list/accept/expire), a session-start offer at **startup only** for branch-scoped handoffs, `hooks/lib/active_workflow.py`, and `hooks/subagent-context.sh`. Build on these; do not recreate them. The analysis below was done against 9.0.0.

## 1. What the sessions show

Scope: 272 Claude Code sessions across `~/Dev/*` in the last 45 days. That is 252 active hours, 7.0B main-thread input tokens and 14.3B subagent input tokens. Metrics were extracted by script from the transcripts. Four Sonnet lanes read them qualitatively: the beacon loop, manual handoff chains, a sweep of all prompts, and a check of what Claude Code supports.

| # | Finding | Evidence |
|---|---|---|
| F1 | **Context runs to the 1M wall.** Auto-compact fires at about 967k on 1M models, so in practice it never fires. | Peak context: p50 177k, p75 339k, p90 470k. 26 sessions passed 500k. All 6 compactions were manual, at 937k–987k. 20 "Prompt is too long" errors occurred, two of which wedged the beacon loop for 6h and 11h. |
| F2 | **Most of the spend is re-reading large contexts.** | 62% of main-thread input was spent in turns already above 300k, and 34% in turns above 500k. Only 3% was under 100k. |
| F3 | **Implementer subagents blow up too.** | 70% of subagent input went to Opus general-purpose agents (473 runs, average 21M tokens each). Beacon batch implementers ran 250–380 turns and reached 600–900k context. 81% of their tokens came from agents that passed 300k. |
| F4 | **Every handoff is manual, and they are written to scattered paths.** | Handoffs were written to `docs/handoffs/`, `HANDOFF.md`, `PROGRESS.md`, `PLAN.md`, memory and scratchpad. The `handoff` skill was invoked once. 22 of 93 first prompts after `/clear` point at a file by hand; one beacon prompt was typed 5 times verbatim. Three sessions ran `/mtk handoff` *as a resume command*, which regenerated a new handoff. |
| F5 | **Handoffs go stale and contradict each other.** | A Resume step told the next session to build B6 after B6 was done. One unanswered question was copied through 3 handoffs. A handoff could disagree with `state.json` and the runbook queue. "Ask to push" stayed after the PR had merged. No handoff was revalidated against git or `gh`. |
| F6 | **Re-orientation after `/clear` costs 11–32k tokens and 1.5–3 minutes.** Every fresh session also starts at 63–74k. | Lane B |
| F7 | **The biggest job ran outside MTK, and it used a trigger that cannot work.** | The beacon hardening loop used `/loop` + ScheduleWakeup with a hand-written `runbook.md` + `state.json`. It ran 23 active hours in one session, 717M tokens (10% of all usage) and 144 subagents. Each wakeup re-entered the *same* growing context. 143 subagent hand-backs alone added about 400k tokens. |
| F8 | **Fresh sessions from on-disk state already work.** | After that loop was retired, successor fresh sessions resumed from `HANDOFF.md` and finished 10 more units at under 230k context. |
| F9 | **Interruptions need a human to type "continue".** | A bare "continue" was typed 77 times. The causes were `/login` (35), sleep (21), spend limits (about 19) and notifications. There were 98 spend- or session-limit messages and about 52 sleep or network errors. |
| F10 | **MTK is bypassed for long work.** | Only 29 of 82 sessions over 60 minutes used any MTK skill. 37 of the 63 sessions with 5 or more subagents used none. The user re-implements implement + review lanes + fix rounds by hand. |
| F11 | **Standing end-of-unit requests are retyped.** | "push and PR" came up in about 45 prompts across about 30 sessions. "Run codex to review" appeared in 10 sessions, and "3-4 fresh reviewers" was also asked for by hand. Stacked PRs were restacked by hand in 8 sessions, and one PR was merged into the wrong base. |
| F12 | **Smaller frictions** | Typing `/mtk:implement` is rejected ("can only be invoked by Claude"), seen in 3 sessions. Review lanes copied the repo until the disk was full (17 GB). A deleted worktree lost verified, uncommitted work, costing about a day of redo. |

### What Claude Code allows (verified against the docs, 2026-10-20)

- The model and hooks **cannot** trigger `/clear` or `/compact`. Any "fresh session" must come from compaction, the user, or an external process.
- The auto-compact window **is** configurable through `autoCompactWindow` in settings, `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, or `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`. The PCT override also covers subagents. **Plugins cannot set it**, so it has to go in project or user settings.
- `PostCompact` receives the generated `compact_summary`. `PreCompact` can only block, not steer.
- `SessionStart` reports `source` ∈ startup/resume/clear/compact/fork and injects up to 10k chars.
- Stop hooks can force continuation, capped at 8 consecutive blocks.
- Unattended runs work with `claude -p --permission-mode auto --permission-prompts none --max-budget-usd N`. One process per leg means one fresh context per leg.
- A plugin `bin/` directory is on the Bash tool's PATH.
- `/loop`, CronCreate and `/goal` **accumulate** context in one session. Cloud routines start a fresh session each time.

### Root causes

1. The **trigger** for the next step lives inside the context that is dying.
2. MTK owns **no canonical checkpoint**, so each project invents one and the copies drift apart.
3. There is **no context budget** at either level: orchestrator or implementer.
4. Interruptions such as limits, sleep and login have **no automatic recovery**.

## 2. Simulated payoff

The simulation replays each session's real context growth. It rolls over to a fresh 80k base (50k for subagents) whenever context passes the cap. Tokens are cache-weighted: read ×0.1, write ×1.25.

| Cap | Main-thread input | Subagent input | Rollovers (45 days) |
|---|---|---|---|
| 150k | −53% | −45% | 606 + 1217 |
| **250k** | **−46%** | **−33%** | 191 + 365 |
| 350k | −38% | −23% | 91 + 168 |

The simulation leaves out the quality cost of compaction and the re-orientation reads beyond the 80k base. A realistic target is roughly **30–40% less input spend**, plus no more 6–11h wedges and no more manual "continue".

## 3. Proposal

The unit of autonomous work becomes a **leg**: one fresh context that performs one or more transitions, writes a **checkpoint**, and ends. Context never carries over between legs; the workflow artifact does. There are three ways to start the next leg, in increasing autonomy:

1. **Compaction:** in-process and automatic, once the window is lowered.
2. **`/clear` + any message:** attended, with nothing to paste.
3. **The relay runner:** unattended, a fresh `claude -p` per leg.

### R0 — Quick wins (no new concepts)

- **R0.1 Compaction window.** `mtk-setup` proposes `"autoCompactWindow": 300000` (a value to tune; see the decisions) in the project `.claude/settings.json`, with approval. `mtk-doctor` WARNs when a 1M model has no window set.
- **R0.2 PostCompact persist.** A new `PostCompact` hook writes `compact_summary` to `.mtk/workflows/<uuid>/compact-<n>.md`, or to `.mtk/sessions/<sid>/` when no workflow is active. A wedge or crash then never loses the summary.
- **R0.3 Session-start pickup.** 9.1.0 already picks the newest *open*, branch-scoped note through `handoff-state.sh`, and offers it at `startup`. Extend that offer to `source=clear`, which is the strongest "I'm continuing" signal and is offered nothing today. Keep "offer, never claim". After `/clear` the user types "go" and the model reads the offered note.
- **R0.4 Bounded implementers.** Add a turn and context budget to the implementer prompt: stop at about 120 tool calls, or when not converging, and return `status: partial` with a resume note. The orchestrator respawns fresh from disk, reusing the existing killed/RESUME path. Implementers and reviewers write full reports to a file and return a digest of 10 lines or fewer; the 143 hand-backs added about 400k to one orchestrator.
- **R0.5 Typable skills.** Set `implement`, `fix` and `batch-fix` to `user-invocable: true`, and give each `argument-hint` and `allowed-tools` (C0.3). Update the AGENTS.md "Five skills are user-invocable" text and `docs/agent-routing-guide.md`.

### R1 — Canonical checkpoint (this is the automatic handoff)

- **`workflow-artifact.sh checkpoint <uuid>`** renders the workflow's handoff note at `docs/handoffs/<workflow-slug>.md`. That keeps it inside the 9.1.0 `handoff-state.sh` lifecycle, with the existing frontmatter plus `workflow: <uuid>`. It is updated in place, never as dated copies.
  - **Front-matter:** `state` (open/closed), `branch`, `sha`, `pushed`, `ahead/behind`, `next_command`, `needs_user[]`, `limits.wait_until`, `expires`.
  - **Sections the script fills:** git facts, open PRs and CI via `gh`, the unit/batch table with status, last verify (command, counts, sha), traps, open questions with their defaults.
  - **Sections the model fills:** goal, decisions with a one-line reason, next-step notes.
  - **Validator:** rejects completed items that reappear under Resume.
- **The checkpoint rides along.** It is appended to the existing batch-close `"$WFA" batch …` call, so it costs no extra turns. It also runs on PR open, before a limit wait, and when the context guard (R2) fires.
- **`workflow-artifact.sh resume <uuid>`** prints a drift block (sha moved, PR merged, branch or worktree gone) followed by `next_command`. The session-start hook calls it.
- **The `handoff` skill becomes a thin wrapper** around `checkpoint`. With no active workflow, it opens a lightweight `TASK` workflow so every handoff resumes the same way. It also catches "/mtk handoff" used as a resume and routes it to `resume` instead.
- **Checkpoint snapshots.** Snapshot the working tree, including untracked non-ignored files, into `refs/mtk/checkpoints/<uuid>` using a temporary index, `write-tree` and `commit-tree`. The branch and the index are never touched. The refs live in the shared git dir, so a deleted worktree costs minutes instead of a day, and branch history stays clean.

### R2 — Context guard (attended mode)

- Promote the personal `~/.claude/hooks/context-guard.py` into MTK as the template. It is a UserPromptSubmit hook that reads the tail of the transcript and fires once per 150k band from 300k up. Add a PostToolUse trigger, because autonomous runs have no user prompts. Each read also writes **telemetry** to `.mtk/sessions/<sid>/telemetry.json`: context tokens, window, %, model and timestamp. The dashboard (R5) reads it. Once this ships, remove the personal hook so the nudges aren't doubled.
- The hook reads the latest `usage` from the tail of `transcript_path`, nudging only while an MTK workflow is active. Without a workflow it falls back to a generic nudge at 300k.
- At `MTK_CTX_SOFT` (default 200k) it injects one model-visible line, once per workflow step: "finish the current transition, checkpoint, then tell the engineer to `/clear` — the next session resumes automatically."
- At `MTK_CTX_HARD` it repeats the line; if compaction comes first, R0.2 and R0.3 cover it.

### R3 — Relay runner (unattended mode)

- **`bin/mtk-relay <uuid>`** is started by `/mtk relay`, either in the background or by printing a `! …` line for the user to run in a terminal. The loop:
  ```text
  while workflow.status == active:
    stop + notify   if needs_user (irreversible step, or a question with no safe default)
    sleep until     limits.wait_until   (parsed from "resets 7:10pm"; bounded by MTK_RELAY_MAX_WAIT)
    claude -p "<resume prompt>" --permission-mode auto --permission-prompts none \
           --max-budget-usd $LEG_BUDGET --output-format stream-json > legs/<n>.jsonl
    classify the exit: done-step | limit (set wait_until, loop) | error (retry once, then stop)
    stop after MTK_RELAY_MAX_UNITS (default 3, which matches the "2–3 PRs then stop" rule) or MAX_LEGS
  ```
- `caffeinate -i` runs for the duration of the relay, against the sleep errors (21 sleeps and about 52 sleep/network errors).
- A row goes into `costs.jsonl` per leg, and a macOS notification fires on stop.
- **Authorizations are fixed at the approval gate.** "Approve & run until done" gains explicit choices: push branches, open draft PRs, run the codex review, and *never* merge or deploy. Anything outside that list sets `needs_user` and the relay stops. This mirrors the CLAUDE.md rule: no default ever applies to an irreversible step.

### R4 — PROGRAM workflows (multi-PR, stacked)

- A new workflow type, `PROGRAM`. It holds `units[]`, each with `depends_on`, `branch`, `base`, `pr`, `status`, `step_cursor`, `fix_round`, `verify{cmd,counts,sha}` and `worktree`. That is the beacon `state.json`, made first-class.
- **Per-unit pipeline:** the one the user wrote by hand. Spec → implement (subagent per batch) → verify → review lanes → fix rounds → PR → optional codex review → triage.
- **Restack after merge:** detect the merged base with `gh`, then retarget or rebase. This answers F11.
- **Finish policy** comes from the approval gate (open PR, codex, reviewer count), so it is not retyped per unit.
- Entry point: `/mtk program <plan.md>`. The relay drives it one leg per unit step.

### R5 — MTK dashboard (replaces the personal dashboard-builder)

What exists today:
- **Personal (`~/.claude/agents/dashboard-builder.md` + a CLAUDE.md rule).** An LLM agent edits a JSON state block inside `.dashboard/index.html`. It has four panels (Tasks, Waiting for you, Latest deliverables, Stuck), refreshes every 10s, and warns when stale. About 190 spawns in 45 days; 94 of them ran on Opus before 10-14.
- **MTK (`scripts/workflow-dashboard.sh`).** A script renders `.mtk/workflows/*` with phases, gates and an event timeline. It has no tasks, questions or context view.

The design merges them **with no LLM calls**:
- **State is the workflow artifact.** The orchestrator already writes it through ride-along `"$WFA"` calls. New batchable subcommands:
  - `step <id> start|done|blocked|skipped [--note]`
  - `question add --q … --default …` and `question answer <id> …`
  - `deliverable add --title … --path …`
- **Stuck is computed,** not hand-written. A step counts as stuck when it stays `doing` past a threshold (shown on the page), a gate fails repeatedly, or the 9.2.0 open-finding stall fires.
- **Live telemetry:**
  - a context gauge for the current session and leg, with marks at the 200k soft limit and the 300k compaction window, from R2's `telemetry.json`
  - session cost from `.mtk/metrics/costs.jsonl`
  - checkpoint age and `next_command`
  - relay legs and `wait_until`, from PR-4
- **Rendering.** `workflow-dashboard.sh` writes `.mtk/dashboard/index.html`, with an index of every active workflow plus one page per workflow, so concurrent tasks never overwrite each other. It re-renders, debounced, after each `"$WFA"` mutation and from the R2 hook. The page is self-contained and works offline over `file://`, with meta refresh, preserved scroll and a stale warning.
- **Style.** Default to your saved style, which is the Moberg brand: dark, dense, `#430cda` used as fill and borders, never as text on dark. A light variant follows `prefers-color-scheme`, and `MTK_DASHBOARD_THEME` overrides it. There is no NEEDS_STYLE round-trip.
- **Trigger for "a bigger task started".**
  - `implement` already opens a BUILD workflow.
  - `batch-fix` will open a FIX workflow, a type the helper already supports.
  - Ad-hoc tasks with more than 5 steps or over 30 minutes get `"$WFA" init TASK --goal … --steps "a|b|c"`, a rule that moves from `~/.claude/CLAUDE.md` into `context-engineering`.
  - The first render opens the page once in interactive sessions (`MTK_DASHBOARD_OPEN=0` disables this) and prints a `file://` link.
- **Retire** (your own files, edited only with your OK once PR-3 ships): the "Progress Dashboard" section of `~/.claude/CLAUDE.md`, the `dashboard-builder` agent with its guard hook, and `context-guard.py` (after PR-2).

## 4. Rollout

Ceremony is HIGH, not MAX: Sonnet reviewers, at most 2 review rounds, a fresh session per PR. Branch from `origin/main` (9.2.0, which includes #125 and #126). Do 3 PRs, then stop and report.

| PR | Version | Contents | Batches |
|---|---|---|---|
| **PR-1** | 9.3.0 | R0.1–R0.5 | **B1** R0.1: `mtk-doctor.sh` WARN, setup/refresh proposes `autoCompactWindow: 300000`, `env-knobs.md`. **B2** R0.2 + R0.3: `hooks/compact-archive.sh` + `hooks.json` + test, `session-start` offer on `clear` + test. **B3** R0.4: implementer prompt budget, `status: partial` + `resume_note` in the schema, partial handled like RESUME in `subagent-implementation`, report-to-file + digest. **B4** R0.5: 3 skill frontmatters, AGENTS.md, routing guide, router fixtures. **B5** release: 3 manifests, CHANGELOG, manifest entries, checksums. |
| **PR-2** | 9.4.0 | R1 + R2 | `checkpoint` / `resume` / `TASK` type in `workflow-artifact.sh` + tests; frontmatter extension in `handoff-state.sh`; handoff skill rewrite; checkpoint ride-along in incremental- and subagent-implementation; snapshot refs; context-guard hook + telemetry + test |
| **PR-3** | 9.5.0 | R5 dashboard | `step` / `question` / `deliverable` subcommands; renderer rewrite; re-render trigger; FIX workflow in batch-fix; TASK rule in context-engineering |
| PR-4 | — | R3 relay runner + gate authorizations | needs its own spec and a go |
| PR-5 | — | R4 PROGRAM workflows + restack | needs its own spec, a brainstorm and a go |

PR-1 + PR-2 deliver "`/clear` → type anything → it continues", with 300k compaction as the automatic fallback. PR-3 makes progress, context and cost visible without LLM calls. PR-4 delivers fully unattended runs.

## 5. Decisions

All answered; see the top of this document.

## 6. Not proved

- Whether `autoCompactWindow` (the settings key, not the PCT env var) also applies to subagents. Test this in PR-1.
- Whether lowering the compaction window degrades multi-batch quality. Compare one run before and after.
- The resume time parsed from limit messages ("resets 7:10pm (Europe/Zagreb)"). The message format is not a stable contract.
- The 30–40% saving is a simulation. Measure it with `session-cost.sh window` after PR-1.

Raw data, for this session only: the scratchpad `out/sessions.jsonl`, `out/prompts/`, and `findings/A-beacon-loop.md`, `B-handoff-chains.md`, `C-sweep.md`.
