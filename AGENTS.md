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
| Everything else | `/mtk <description>` | Natural language — routes to fix / batch-fix / implement / pre-commit-review / repo-health / instructions / mtk-doctor |
| Run a known workflow directly | `/mtk:implement`, `/mtk:fix` or `/mtk:batch-fix` | Skip the router when you already know the workflow — same skill the router would load |
| Periodic readiness check | `/mtk repo-health` or `bash scripts/repo-health-score.sh` | 9-asset action checklist + PR review mining (last 10 merged PRs) |
| Validate toolkit | `bash scripts/validate-toolkit.sh` | Before every commit — structural check of manifest, plugin.json, and skill anatomy |
| Install health check | `/mtk-doctor` | PASS/WARN/FAIL diagnostics across core files, components, hooks, active config and environment fit; `--json` for CI, `--fix` for safe auto-repairs, `--usage` for raw usage counts |
| Promote a lesson | `/lessons promote` | Promote a rule from Claude Code native memory to team-wide `tasks/lessons.md`; optionally open a validated contribute-back PR to the toolkit (`/promote-lesson` is a one-release alias) |
| Mine lessons from past sessions | `/lessons mine` | Sweep recent session transcripts for durable lesson/memory candidates (reject-by-default rubric, suggest-only) |
| Tune MTK behaviour (hooks, rigor, budgets, thresholds) | `MTK_*` environment variables | Full table of every knob, its default and effect: `.claude/references/env-knobs.md` |

**Decision rule for `/mtk`:** Say what you want in plain English. The router picks the right workflow skill — fix / batch-fix / implement / pre-commit-review / repo-health / research-context / instructions / lessons / mtk-doctor / handoff.

**Updates:** MTK is a Claude Code plugin — use the plugin manager to upgrade. There is no in-repo update command.

---

## Build & Test

```bash
bash scripts/validate-toolkit.sh                            # structure + manifest (before every commit)
bash scripts/run-fixtures.sh                                # router + workflow fixtures
claude plugin eval . --tag smoke --scaffold --allow-tools Bash Write Edit --trust-plugin   # behavioural evals (model calls; see evals/README.md)
bash scripts/mtk-doctor.sh                                  # install health check (--json, --fix)
```

No `dotnet build` — this is a markdown/bash/JSON toolkit. Pressure tests are manual: read
`tests/pressure-tests/*.md` and verify skill behaviour.

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

- **C0.1** Manifest versions must match: `.claude/manifest.json` version == `.claude-plugin/plugin.json` version == `.claude-plugin/marketplace.json` plugin entry version, plus a `## [X.Y.Z]` CHANGELOG heading and the `checksums.sha256` header. Bump them together when releasing (S4.6); `validate-toolkit.sh` FAILs on a miss. The moberg-plugins marketplace entry carries no version.
- **C0.2** Every repo file must have a manifest.json `files` entry, except the short allow-list of non-shipped files in `validate-toolkit.sh` (`manifest_allowed_unlisted`). Every manifest path must exist on disk.
- **C0.3** Skills follow the anatomy in `.claude/rules/skill-authoring.md` S2.2 (Overview / When To Use / Workflow / Verification for workflow skills; phase-structured and entry-point skills are exempt as listed there). Entry-point skills use `allowed-tools` and `argument-hint` in frontmatter. Skill directory name must match frontmatter `name:`.
- **C0.4** Agents and skills must have `---` frontmatter blocks.
- **C0.5** Hooks must be executable (`chmod +x`) and use `set -euo pipefail`.
- **C0.6** Never hardcode secrets, API keys, or user-specific paths in committed files. The local settings override file is gitignored.
- **C0.7** `AGENTS.md` is protected — `setup-bootstrap` generates it (together with the `CLAUDE.md` shim that imports it), but subsequent edits are project-specific. Don't overwrite during update.
- **C0.8** Run `bash scripts/validate-toolkit.sh` and confirm "Toolkit validation passed" before reporting any change as complete.

---

## Standards Reference

Detailed rules live in `.claude/rules/`: `toolkit-structure.md` (S1.x, manifest/organization/naming),
`skill-authoring.md` (S2.x), `hooks-and-scripts.md` (S3.x), `git-workflow.md` (S4.x), `verification-and-proof.md`
(S5.x). Rules are path-scoped by their `paths:` frontmatter; Claude Code loads one when a matching file is touched.

Reference docs are read on demand: shared ones in `.claude/references/` (`domain-finance.md`,
`implement-review-lanes.md`, `env-knobs.md`), and
per-stack ones under `.claude/references/{stack}/`, listed canonically in the active tech stack
skill's `## Reference Files`.

---

## Agent Routing

This repository uses **skills** as both user-facing entry points and reusable workflow blocks, and
**agents** as specialist reviewers. The routing decision tree, per-workflow composition, the
model-invoked skill list, the two-stage review graph, the review-output schema, the eval pipeline,
tech-stack loading and progressive/path-scoped reference loading all live in
`docs/agent-routing-guide.md` — read it whenever routing is not obvious.

Eight skills are user-invocable: `/mtk-setup` (`--audit`, `--merge`, `--refresh`, `--check`), `/mtk <description>` (the natural-language router),
`/mtk-doctor`, `/lessons`, `/promote-lesson` (alias), and `/mtk:implement`, `/mtk:fix`, `/mtk:batch-fix` as direct shortcuts for engineers who already know the workflow.
Everything else is a **routed workflow skill** reached through `/mtk`, or a **model-invoked skill** loaded automatically when its trigger fires.
The canonical route list is the `/mtk` decision rule above.

The active tech stack is recorded in `.claude/tech-stack`; every entry-point skill and agent reads
it in Phase 0 and loads the matching `tech-stack-{stack}` skill. No such file ⇒ run `/mtk-setup`.

Review is two-stage: Stage 1 (`compliance-reviewer`, plus `silent-failure-hunter` on
error-handling diffs) gates Stage 2 (`test-reviewer`, `architecture-reviewer`).

### Routing Rules

1. Read this file first — it is the project-specific source of truth. `CLAUDE.md` only imports it.
2. Start a task with `context-engineering`; it loads the phase-appropriate references.
3. If an entry-point skill exists for the task, prefer it — it orchestrates the underlying workflow skills.
4. Do not skip planning, testing, review, or verification when the chosen skill requires them.
5. For toolkit structural health (toolkit maintainers only), run `bash scripts/validate-toolkit.sh`. For onboarding a new repo, install the MTK plugin from the marketplace then run `/mtk-setup`.

### Agent Self-Escalation

All agents may report `BLOCKED` or `NEEDS_CONTEXT` instead of producing uncertain output. A clear
escalation is always more valuable than a low-confidence review.
