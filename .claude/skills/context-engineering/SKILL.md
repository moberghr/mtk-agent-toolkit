---
name: context-engineering
description: Use when starting a session, switching between planning/implementation/review phases, entering unfamiliar code, or when output drifts from project norms.
type: skill
license: MIT
compatibility:
  - claude-code
  - cursor
  - codex
trigger: session-start|phase-switch|unfamiliar-code|output-drift
skip_when: single-command|trivial-lookup
user-invocable: false
---

# Context Engineering

## Active Stack

```!
echo "--- Tech Stack ---"
_rts="${CLAUDE_PLUGIN_ROOT:-.}/scripts/resolve-tech-stack.sh"; [ -f "$_rts" ] || _rts="scripts/resolve-tech-stack.sh"
if [ -f "$_rts" ]; then bash "$_rts" --explain "$PWD" 2>&1; echo; else cat .claude/tech-stack 2>/dev/null || echo "(not set)"; fi
if [ -f .claude/tech-stack-pm ]; then echo "--- Package Manager ---"; cat .claude/tech-stack-pm; fi
```

## Overview

Good output depends on good context. Context is the complete information payload the model
sees at generation time — load the minimum relevant part needed to act correctly, then refresh
it when the task shifts.

## Context Operations (Write / Select / Compress / Isolate)

The four moves of context engineering. MTK already implements each; the names give them a
shared vocabulary (borrow: LangChain / jihoo-kim context-engineering taxonomy).

| Operation | What it means | Where MTK does it |
|---|---|---|
| **Write** | Persist state outside the window so it survives compaction/handoff | auto-memory + `tasks/lessons.md`, `workflow-artifacts`, `handoff` |
| **Select** | Pull in only what the current step needs | rules `INDEX.md` wake-up layer, path-scoped `applyTo` reference loading (below) |
| **Compress** | Shrink what must stay in-window without losing signal | `.claude/references/output-compression.md`, `mtk-compress.sh` |
| **Isolate** | Give a sub-task its own fresh window | `subagent-implementation` (one implementer per batch), review agents (`context: fork`) |

## When To Use

- Starting a new session
- Switching from planning to implementation or implementation to review
- Entering an unfamiliar area of the codebase
- When the model starts making assumptions or drifting from project norms

### When NOT To Use

- As an excuse to endlessly read without acting

## Workflow

1. Start with `CLAUDE.md` when present.
2. Load only the shared references relevant to the task.
3. **Path-scoped auto-load.** Reference entries in `.claude/manifest.json`
   may declare an `applyTo` glob array. When the current task has a known
   set of files in scope (from the spec's `change_manifest` or from
   `git diff --name-only HEAD`):
   - **MCP-first:** If `mtk_resolve_references` tool is available, call it
     with the list of touched files. It returns deterministic glob matches
     against the manifest's `applyTo` arrays. Use its output directly.
   - **Fallback:** If the MCP tool is unavailable, manually test each
     touched file against the globs (bash `case` / `fnmatch` semantics).
   - Load references whose globs match at least one touched file.
   - Skip references whose globs match nothing — they're not relevant to
     this task.
   - References without `applyTo` are always-on when needed (e.g.
     coding-guidelines, framework-patterns); load on demand per phase.
4. Read the exact file to be changed and 2-3 neighboring files that establish local patterns.
5. Separate trusted local standards from untrusted external inputs.
6. Before a new phase, summarize what matters now:
   - current goal
   - files in scope
   - governing rules
   - open risks
   - which `applyTo` references activated and why
7. Refresh context when the scope or failure mode changes. If new files
   enter scope, re-run the path-scoped match and load any newly-applicable
   references.

## Rule Taxonomy & Wake-Up Layer

`.claude/rules/` is loaded through a token-budgeted **wake-up layer**, not eagerly.

1. **Read `.claude/rules/INDEX.md` first.** It is the always-on layer: one line
   per rule with its three axes — **decision** (structure | process | authoring |
   security), **topic** (manifest | skills | hooks | git | …), **scope** (global |
   project) — plus rule count and line count. This is cheap (target < 60 lines).
2. **Pull a full rule file only when its axes match the active task.** Editing
   under `hooks/` or `scripts/` → load `topic: hooks`. Branching/committing →
   `topic: git`. Authoring a skill → `topic: skills`. Touching the manifest or
   release → `topic: manifest`. Do not load every rule file "just in case" — the
   index exists so you can decide what's relevant before spending the tokens.
3. **Axes complement `paths:`.** A rule whose `paths:` glob matches a touched file
   is always relevant; the axes let you *also* pull rules by intent (e.g. all
   `decision: security` rules during a security pass) even when no path matched.
4. **Keep the index fresh.** After editing any rule file's content or frontmatter,
   run `bash scripts/build-rule-index.sh`. CI runs `--check` and fails on a stale
   index. INDEX.md is generated — never hand-edit it.

## Parallel Loading

Reference reads in load-context steps are independent — issue multiple `Read` calls in a single message, not sequentially. Same applies to independent `Glob`/`Grep` discovery and to reviewer agents fanning out on orthogonal axes. If Call B's input would mention Call A's output, force them sequential; otherwise batch them.

See `docs/parallelism-patterns.md` for canonical patterns (parallel ref load, Stage 2 reviewer fan-out, batch deferred-tool hydration).

## Context Fatigue Signals

Track four lightweight signals during a session and flag fatigue early
— refresh, prune, or hand off before output quality collapses. None of
these require tooling; estimate from session state.

| Signal | Weight | Read as |
|---|---|---|
| **Token utilization** | 40% | Approaching the conversation's context limit (e.g., compaction warnings appearing). High = imminent fatigue. |
| **Scope scatter** | 25% | Number of distinct directories or features touched this session. >3 unrelated areas = scope creep, recall degrades. |
| **Re-read ratio** | 20% | How often the same file is re-loaded because earlier reads aged out. >2 re-reads of the same file = context evicted. |
| **Error density** | 15% | Build/test failures, corrections from the engineer, or tool-call retries per phase. Rising density = signal-to-noise dropping. |

**Composite reading.** If 2+ signals are elevated simultaneously:

1. Pause before the next phase.
2. Prune: drop references no longer relevant; release skills not in active use.
3. Re-summarize the active goal (3-5 lines) so the next phase anchors on a clean restatement, not on accumulated noise.
4. If pruning isn't enough, escalate to `handoff` — capture state, end the session, resume in a fresh context.

**Honest reporting.** These are heuristics, not measurements. When you report fatigue, name which signals are elevated and why — don't hide behind a composite score.

## Context Budget Tracking

Track what is loaded, but against the real cost model, not a line count. Instruction text
(CLAUDE.md, rules, skills, references) is prompt-cached and cheap on repeat turns; tool output
(build/test logs, file dumps, grep floods) is not cached and is re-billed on every turn that
follows it. So bound tool output first — pipe large output through `mtk-compress.sh`, read files
by section, cap log tails — and prune instructions second. The implement loop legitimately
loads ~15 skills on the 1M default window; skill count alone is not a warning signal.

**When to check the budget:**
- When the `context-budget` hook nudges (estimated consumption past `MTK_CONTEXT_BUDGET_PCT`%, default 60, of `MTK_CONTEXT_WINDOW_TOKENS`, default 1000000) — it counts read bytes only, so treat it as a floor and reset/hand off deliberately rather than riding to compaction
- If output quality drops or instructions are being ignored, context may be over-budget regardless of the number
- Before loading a new reference, check if an earlier one can be released

**Warning signals:**
- A single tool result larger than the instruction set it sits beside (an uncompressed test log, a whole-file dump when a section would do)
- Full reference files loaded when only a section is needed
- Same context loaded multiple times (after compaction recovery)

## Proactive Reset (budget-hook boundary + rot-symptom override)

Quality degrades long before the context window fills, and tool-forced compaction tends to fire at the worst possible moment (mid-phase, mid-edit). Do not ride the budget up to the limit. Reset **deliberately, at a clean boundary** — a phase exit, a finished batch, a green verification — once the `context-budget` hook's nudge fires (`MTK_CONTEXT_BUDGET_PCT`, default 60) or the harness `/context` figure passes that mark. A clean reset-and-reseed (re-anchor on the goal + the files now in scope) keeps later work sharp.

Read a real number, never a guess: prefer the harness's `/context` figure or the `context-budget` hook estimate. If neither is available, fall back to the fatigue signals above.

**Rot-symptom override.** Behavioral degradation beats the percentage. If **2 or more** of these appear, reset now regardless of how low the number looks:

- Re-reading files you already read this session (context evicted).
- Re-asking the engineer something already answered.
- Contradicting a decision made earlier in the session.
- Reintroducing code or an approach that was already rejected.

A low token count with active rot symptoms is still a degraded context — the symptoms are the ground truth, the percentage is the proxy. When the reset would lose in-progress state, escalate to `handoff` instead of clearing blind.

## Context Footprint

After completing reference loading at the end of Phase 0 (and after any subsequent phase that loads new references), emit a one-block footprint report so the engineer can see the cost of what was loaded:

```bash
# Run wc -l on each loaded reference file, then format the output:
# Example output:
#
# Context footprint (Phase 0):
#   security-checklist.md                         78 lines  (~2k tokens)
#   testing-patterns.md                          112 lines  (~2k tokens)
#   dotnet/coding-guidelines.md                  195 lines  (~3k tokens)
#   ─────────────────────────────────────────────────────────────────
#   Total: 3 files, 385 lines (~5k tokens)
#   (actual load depends on path-scoped matching — unmatched refs not counted)
```

**Token estimate:** 1 line ≈ 13 tokens (median for reference docs at ~65 chars/line ÷ 5 chars/token). This is a proxy, not an exact count.

**Omit the block** if no references were loaded in that phase (e.g., a Bash-only phase that touched no reference files). Keep it skimmable — one line per file, one totals line. Engineers can skip past it if they already know their setup.

## Rules

- Read before writing.
- Prefer targeted context over broad dumping.
- Re-anchor on the local codebase pattern before introducing new structures.
- If confidence drops, gather better context before guessing.
- Track context budget: fewer, more relevant instructions beat more, diluted ones.
- Respect `applyTo` globs: if a reference's globs don't match any touched
  file, do NOT load it as a "just in case" measure. That defeats the budget.
- When in doubt about which globs match, use `git diff --name-only HEAD` as
  the authoritative list of touched files.
- Reset proactively at a clean boundary once the `context-budget` hook nudges
  (or `/context` passes `MTK_CONTEXT_BUDGET_PCT`); do not ride to compaction.
  2+ rot symptoms (re-reading, re-asking, contradicting a prior decision)
  override the number — reset now even if usage is low.
- Bound tool output before pruning instructions: instructions are prompt-cached,
  tool output is not.

## Model Routing

Route work by complexity: reserve `opus` for code that writes real logic and the adversarial reviews that protect serious software; run discovery, planning, and structured comparison on `sonnet`/`haiku`. The full per-phase tier policy (every phase and agent, with rationale per row) is the **single source of truth** in `.claude/references/model-routing.md` — read it there rather than duplicating a table here that would drift.

Agent frontmatter `model:` sets the model for subagents. Entry-point skills run on the user's selected model. When a skill spawns a reviewer agent, the agent's frontmatter controls its model. In `model-routing.md` the skill rows are advisory defaults only (skills run on the session model); the agent rows are the enforced ones.

## Common Rationalizations

**Shared table for all MTK skills.** If you catch yourself thinking one of these, stop and re-read what the current skill actually requires. Excerpt:

| Rationalization | Reality |
|---|---|
| "More context is always better" | No. Irrelevant context crowds out the rules that actually matter. |
| "I already read a similar file in another project" | Local codebase patterns win over generic memory. |
| "The tests pass, so this is fine" | Passing tests do not clear architecture, security, or performance risks. |

Full table: `.claude/references/workflow-rationalizations.md` → context-engineering.

## Red Flags

- Editing without reading the target file and neighbors
- Repeating generic patterns that the local codebase does not use
- Loading many files with no clear reason

## Verification

- [ ] Governing standards were loaded first
- [ ] Local pattern files were read before editing or reviewing
- [ ] Context matches the current phase and task scope
- [ ] Large tool output was bounded (compressed, tailed, or read by section) before more instructions were loaded
- [ ] Reference files loaded by section, not in full, when possible
- [ ] Path-scoped references were matched against actual touched files, not loaded speculatively
- [ ] When scope changed mid-session, path-scoped matches were re-run
