# claude-helpers — MTK Standards

> Canonical instructions for every AI coding agent working in this repo — Claude Code, Codex CLI,
> Cursor, Copilot, Windsurf, OpenCode and anything else that reads `AGENTS.md`. `CLAUDE.md` is a
> shim that imports this file; the tool-specific mirrors under `.github/` and `.windsurf/` point here.
>
> Version history and per-release notes: see CHANGELOG.md. (Kept out of this file so the always-loaded prefix stays prompt-cache-stable across releases.)
>
> This file + `.claude/rules/` are the source of truth for AI agents.
> Detailed standards live in `.claude/rules/`. Reference docs live in `.claude/references/` (shared) and per-stack subdirectories of it.

---

## Skill Routing

| What you need | Command | When |
|---|---|---|
| First-time repo setup | `/mtk-setup` | Bootstrap — detects tech stack, pulls guidelines, generates AGENTS.md (plus the CLAUDE.md shim) and the architecture-principles reference |
| Re-run audit | `/mtk-setup --audit` | Refresh the generated architecture-principles reference after architectural change |
| Merge multi-repo audits | `/mtk-setup --merge` | Unify per-repo audits in `.claude/references/audits/` into a team-wide doc |
| Everything else | `/mtk <description>` | Natural language — routes to fix / implement / pre-commit-review / repo-health / context-report |
| Periodic readiness check | `/mtk repo-health` or `bash scripts/repo-health-score.sh` | 12-asset scorecard + PR review mining (last 10 merged PRs) |
| Validate toolkit | `bash scripts/validate-toolkit.sh` | Before every commit — structural check of manifest, plugin.json, and skill anatomy |
| Install health check | `/mtk-doctor` | PASS/WARN/FAIL diagnostics across core files, components, hooks, and environment fit; `--json` for CI, `--fix` for safe auto-repairs |
| Promote a lesson | `/promote-lesson` | Promote a personal lesson from the personal lessons store **or Claude Code native memory** to team-wide `tasks/lessons.md`; optionally open a validated contribute-back PR to the toolkit |
| Mine lessons from past sessions | `/mtk mine lessons` | Sweep recent session transcripts for durable lesson/memory candidates (reject-by-default rubric, suggest-only) |
| Disable tier-2 hooks | `MTK_HOOKS_TIER2=0` in the local settings override | Silences skill-invoking hooks (queue + drain) without touching shared settings |
| Enforce spec scope (hard deny) | `MTK_SCOPE_GUARD_ENFORCE=1` | Upgrades `hooks/scope-guard.sh` from advisory to a hard PreToolUse deny (exit 2) when an Edit/Write targets a file outside the approved spec's `change_manifest`/`test_manifest`. Default (unset) stays advisory |
| Auto-approve safe plans | `MTK_AUTO_PROCEED=1` | Skips Phase 2.5 prompt only when spec has no open decisions and no plan-gap BLOCKING findings |
| Disable artifact publishing | `MTK_ARTIFACT_PUBLISH=0` | Stops workflow skills publishing spec/plan/handoff/health to a claude.ai Artifact (data-egress opt-out for regulated repos); disk output is unaffected. See `.claude/references/artifact-publishing.md` |
| Enable compaction snapshots (plugin installs) | `MTK_COMPACT_SNAPSHOT=1` | Opts a plugin-installed repo into pre-compaction git-stash snapshots; always on in this dev checkout |
| Pin MTK to a checkout | `MTK_HELPER_ROOT=/path/to/claude-helpers` | Makes MTK resolve from that checkout **first**, before the project copy and the plugin cache — covering both the `## MTK File Resolution` block every entry-point skill opens with and the inline script resolvers (`scripts/workflow-artifact.sh`, `scripts/learnings.sh`). Target-repo scripts resolve the *project* root from `$CLAUDE_PROJECT_DIR`/git, so their output always lands in the target |
| Tune the mtk-compress nag | `MTK_COMPRESS_MAX_NAGS=N` | Per-session budget for `hooks/compress-monitor.sh`'s "pipe this through mtk-compress" tip (default `1`). `0` silences it while leaving the hook wired; `MTK_COMPRESS_MONITOR_DISABLED=1` disables it outright, and `MTK_COMPRESS_WARN_CHARS` moves the 5,000-char trigger |
| Allow interactive-prone shell commands | `MTK_INTERACTIVE_GUARD=0` | Disables `hooks/interactive-guard.sh`, the PreToolUse hard deny on Bash commands that can block on a prompt (S4.12) — `gh pr merge` with no `--delete-branch`/`--no-delete-branch` decision, and prompt-capable commands piped through `tail`/`head`. Read-only pipes are never blocked |
| Declare that subagent dispatch is unavailable | `MTK_SUBAGENT_DISPATCH=0` | Tells `implement`'s Phase 2.9 pre-flight that this session cannot dispatch implementer subagents. HIGH/MAX then runs the **inline-MAX profile** (compensations C1–C3). It does **not** lower the rigor level. Default (unset) probes per run |
| Force or skip the pre-flight baseline | `MTK_BASELINE_CAPTURE=1` / `=0` | `implement` Phase 2.9 captures build/test/typecheck state at the base commit before the first edit. On by default at rigor HIGH/MAX; `=1` forces it at any level, `=0` opts out — and then every later checkpoint must state that no baseline exists |
| Tune or disable the host-load probe | `MTK_HOST_LOAD_MAX=N` / `MTK_HOST_LOAD_PROBE=0` | `scripts/host-load-probe.sh` reports the 1-minute load per core and says `overloaded` above `MTK_HOST_LOAD_MAX` (default `2.0`). An overloaded host routes the run to inline-MAX instead of dispatching implementers the harness watchdog will kill. `=0` skips the probe on shared CI runners |
| Cap parallel implementer waves | `MTK_BATCH_WAVE_MAX=N` | Phase 3 on the subagent path runs batches at the same `depends` level concurrently; this caps how many implementers one wave dispatches (default `3`). `1` restores fully sequential batches |
| Tune the mid-run churn review thresholds | `MTK_CHURN_REVIEW_LINES` / `MTK_CHURN_HALT_LINES` | Net non-generated lines changed since the last review before an early review (default 300) or a halt for `compliance-reviewer` (default 500). Defaults double at rigor HIGH/MAX. Generated files never count |
| Tune the collateral-churn thresholds | `MTK_COLLATERAL_*` (see `hooks/collateral-guard.sh`) | Thresholds for the guard that flags churn that is not the change you made: whitespace/EOL-only rewrites, generated artifacts riding along undeclared, asset directories regenerated wholesale, and structured files re-serialized around a small real edit |
| Write a tracked run receipt | `MTK_RUN_RECEIPT=1` | `implement` Phase 7.5 writes a **tracked** receipt beside the spec in `docs/specs/` holding the run's evidence (baseline vs final figures, gates, dispatch path, drift/coverage/collateral verdicts, reviewer lane outcomes). Fields never recorded are written as `not recorded` |
| Calibrate context-budget nags to your window | `MTK_CONTEXT_WINDOW_TOKENS=200000` | Rescales `hooks/context-budget.sh`'s file/mod/op nudges from the 1M default to your model's real context window. Per-threshold overrides: `MTK_CTX_FILES_WARN` / `MTK_CTX_MODS_WARN` / `MTK_CTX_OPS_WARN`; `MTK_CONTEXT_BUDGET_PCT` sets the read-bytes reset percentage |

**Decision rule for `/mtk`:** Say what you want in plain English. The router picks the right workflow skill — fix / implement / pre-commit-review / repo-health / context-report / research-context / instructions-audit / instructions-capture / toolkit-health / mtk-doctor.

**Updates:** MTK is a Claude Code plugin — use the plugin manager to upgrade. There is no in-repo update command.

---

## Build & Test

```bash
# Validate toolkit structure and manifest integrity
bash scripts/validate-toolkit.sh

# No dotnet build — this is a markdown/bash/JSON toolkit, not a .NET app
# Pressure tests are manual: read tests/pressure-tests/*.md and verify skill behavior

# Router fixtures + evals: bash scripts/run-fixtures.sh && bash scripts/run-evals.sh
# Install health check: bash scripts/mtk-doctor.sh (--json, --fix)
```

Releases regenerate `checksums.sha256` via `bash scripts/generate-checksums.sh` as the last change in the release commit (S4.11).

---

## Project Profile

- **Type:** Claude Code plugin / shared toolkit
- **Languages:** Markdown (skills, agents, references), Bash (hooks, scripts), JSON (manifest, settings, plugin)
- **Distribution:** Claude Code plugin marketplace via `.claude-plugin/plugin.json`
- **Version tracking:** `.claude/manifest.json` + `.claude-plugin/plugin.json` (must stay in sync)
- **Test approach:** `scripts/validate-toolkit.sh` (structural) + `tests/pressure-tests/` (adversarial behavioral)
- **Target audience:** Engineering teams building serious software (.NET first-class, Python supported, more stacks pluggable; finance domain supplement included)
- **Tech stack architecture:** Workflow skills are language-agnostic; per-stack context lives in `tech-stack-{name}` skills loaded via `.claude/tech-stack`

---

## Critical Rules (Always Apply)

- **C0.1** Manifest versions must match: `.claude/manifest.json` version == `.claude-plugin/plugin.json` version == `.claude-plugin/marketplace.json` plugin entry version. Bump all three when releasing.
- **C0.2** Every file in the repo must be listed in manifest.json `files` section. Every manifest path must exist on disk.
- **C0.3** Skills follow the anatomy in `.claude/rules/skill-authoring.md` S2.2 (Overview / When To Use / Workflow / Verification for workflow skills; phase-structured and entry-point skills are exempt as listed there). Entry-point skills use `allowed-tools` and `argument-hint` in frontmatter. Skill directory name must match frontmatter `name:`.
- **C0.4** Agents and skills must have `---` frontmatter blocks.
- **C0.5** Hooks must be executable (`chmod +x`) and use `set -euo pipefail`.
- **C0.6** Never hardcode secrets, API keys, or user-specific paths in committed files. The local settings override file is gitignored.
- **C0.7** `AGENTS.md` is protected — `setup-bootstrap` generates it (together with the `CLAUDE.md` shim that imports it), but subsequent edits are project-specific. Don't overwrite during update.
- **C0.8** Run `bash scripts/validate-toolkit.sh` and confirm "Toolkit validation passed" before reporting any change as complete.

---

## Standards Reference

Detailed rules in `.claude/rules/` (auto-loaded by Claude Code):

| File | Covers | Rules |
|---|---|---|
| `toolkit-structure.md` | Manifest, file organization, naming | S1.x |
| `skill-authoring.md` | Skill anatomy, CSO principle, pressure tests | S2.x |
| `hooks-and-scripts.md` | Bash hooks, validation scripts | S3.x |
| `git-workflow.md` | Branches, commits, versioning | S4.x |

Full reference docs (distributed to target repos, read on-demand):

**Shared (any stack):**
- `.claude/references/security-checklist.md` — Security checklist for serious software
- `.claude/references/domain-finance.md` — Finance domain supplement (regulated state, sensitive data, audit requirements)
- `.claude/references/testing-patterns.md` — Generic testing guidance
- `.claude/references/performance-checklist.md` — Generic performance checklist

**Per stack (loaded via the active tech stack skill's `## Reference Files`):**
- `.claude/references/dotnet/` — coding-guidelines, ef-core-checklist, mediatr-slice-patterns, testing-supplement, performance-supplement
- `.claude/references/python/` — coding-guidelines (placeholder), sqlalchemy-checklist, fastapi-patterns, testing-supplement, performance-supplement

---

## Agent Routing

This repository uses **skills** as both user-facing entry points and reusable workflow blocks, and
**agents** as specialist reviewers. Full detail — decision tree, per-workflow composition, the
model-invoked skill list, the two-stage review graph, the review-output schema, the eval pipeline
and path-scoped reference loading — lives in `.claude/references/agent-routing-guide.md`.

### Entry-Point Skills

There are just two user-invocable skills:

| Skill | Purpose |
|:---|:---|
| `/mtk-setup` | First-time setup (bootstrap + audit), `--audit` to re-audit, `--merge` to unify multi-repo audits, `--refresh` to drift-refresh all generated docs (`--dry-run` to preview), `--check` as read-only CI staleness gate, `--converge` to judge code against agreed principles as graded work items |
| `/mtk <description>` | Natural-language router — dispatches to fix / batch-fix / implement / pre-commit-review / context-report / repo-health / research-context / instructions-audit / instructions-capture / toolkit-health / mtk-doctor / pr-review-mining / promote-lesson / lesson-mining / lesson-refresh / setup-refresh / setup-converge |

Everything else is either a **routed workflow skill** (reached through `/mtk`) or a
**model-invoked skill** (`handoff`, `correction-capture`, `golden-path-capture`,
`prior-work-check`, `subagent-implementation`, `code-simplification`, `workflow-artifacts`),
loaded automatically when its trigger fires. Both lists, with composition, are in the guide.

### Review Routing (Two-Stage)

Stage 1 (`compliance-reviewer`, plus `silent-failure-hunter` on error-handling diffs) gates Stage 2 (`test-reviewer`, `architecture-reviewer`); the full procedure, triggers and lane rules are in `.claude/references/agent-routing-guide.md` → *Review Routing (Two-Stage)*.

### Tech Stack Loading

The toolkit uses pluggable tech stacks. The active stack is recorded in `.claude/tech-stack` (a
single word like `dotnet`, `python`, or `typescript`). Every entry-point skill and agent reads
this file in Phase 0 and loads the matching `tech-stack-{stack}` skill, which provides build and
test commands, ORM and framework patterns, stack-specific reference paths, scan recipes for
`setup-bootstrap` and `setup-audit`, and settings to merge during setup. For the `typescript`
stack, `.claude/tech-stack-pm` additionally stores the auto-detected package manager (bun /
pnpm / yarn / npm). If a repo has no `.claude/tech-stack` file, run `/mtk-setup` first.

### Reference Loading

Load shared references **progressively** — only what the current phase needs:

| Phase | References |
|:---|:---|
| **Always** | The coding guidelines from the active tech stack's `## Reference Files` |
| **Planning** | `security-checklist.md` *(if scope touches security)*, `testing-patterns.md` |
| **Implementation** | `performance-checklist.md`, plus stack-specific ORM checklist and framework patterns |
| **Review** | the repo's quick-check list *(if present)* |

### Routing Rules

1. Read this file first — it is the project-specific source of truth. `CLAUDE.md` only imports it.
2. Start a task with `context-engineering`; it loads the phase-appropriate references above.
3. If an entry-point skill exists for the task, prefer it — it orchestrates the underlying workflow skills.
4. Do not skip planning, testing, review, or verification when the chosen skill requires them.
5. For toolkit structural health (toolkit maintainers only), run `bash scripts/validate-toolkit.sh`. For onboarding a new repo, install the MTK plugin from the marketplace then run `/mtk-setup`.

### Agent Self-Escalation

All agents may report `BLOCKED` or `NEEDS_CONTEXT` instead of producing uncertain output. A clear
escalation is always more valuable than a low-confidence review.
