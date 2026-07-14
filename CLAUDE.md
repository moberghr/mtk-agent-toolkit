# claude-helpers — MTK Standards

> Version history and per-release notes: see CHANGELOG.md. (Kept out of this file so the always-loaded prefix stays prompt-cache-stable across releases.)
>
> This file + `.claude/rules/` are the source of truth for AI agents.
> Detailed standards live in `.claude/rules/`. Reference docs live in `.claude/references/` (shared) and `.claude/references/{stack}/` (stack-specific).

---

## Skill Routing

| What you need | Command | When |
|---|---|---|
| First-time repo setup | `/mtk-setup` | Bootstrap — detects tech stack, pulls guidelines, generates CLAUDE.md and architecture-principles.md |
| Re-run audit | `/mtk-setup --audit` | Refresh `.claude/references/architecture-principles.md` after architectural change |
| Merge multi-repo audits | `/mtk-setup --merge` | Unify per-repo audits in `.claude/references/audits/` into a team-wide doc |
| Everything else | `/mtk <description>` | Natural language — routes to fix / implement / pre-commit-review / repo-health / context-report |
| Periodic readiness check | `/mtk repo-health` or `bash scripts/repo-health-score.sh` | 12-asset scorecard + PR review mining (last 10 merged PRs) |
| Validate toolkit | `bash scripts/validate-toolkit.sh` | Before every commit — structural check of manifest, plugin.json, and skill anatomy |
| Install health check | `/mtk-doctor` | PASS/WARN/FAIL diagnostics across core files, components, hooks; `--json` for CI, `--fix` for safe auto-repairs |
| Promote a lesson | `/promote-lesson` | Promote a personal lesson from `.claude/lessons/personal.md` to team-wide `tasks/lessons.md`; optionally open a validated contribute-back PR to the toolkit |
| Mine lessons from past sessions | `/mtk mine lessons` | Sweep recent session transcripts for durable lesson/memory candidates (reject-by-default rubric, suggest-only) |
| Disable tier-2 hooks | `MTK_HOOKS_TIER2=0` in `.claude/settings.local.json` env | Silences skill-invoking hooks (queue + drain) without touching shared settings |
| Auto-approve safe plans | `MTK_AUTO_PROCEED=1` in `.claude/settings.local.json` env | Skips Phase 2.5 prompt only when spec has no open decisions and no plan-gap BLOCKING findings |
| Disable artifact publishing | `MTK_ARTIFACT_PUBLISH=0` in `.claude/settings.local.json` env | Stops workflow skills publishing spec/plan/handoff/health to a claude.ai Artifact (data-egress opt-out for regulated repos); disk output is unaffected. See `.claude/references/artifact-publishing.md` |
| Enable compaction snapshots (plugin installs) | `MTK_COMPACT_SNAPSHOT=1` in `.claude/settings.local.json` env | Opts a plugin-installed repo into pre-compaction git-stash snapshots; always on in this dev checkout |

**Decision rule for `/mtk`:** Say what you want in plain English. The router picks the right workflow skill — fix / implement / pre-commit-review / repo-health / context-report / research-context / claude-md-audit / claude-md-capture / toolkit-health / mtk-doctor.

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
- **Test approach:** `scripts/validate-toolkit.sh` (structural) + `tests/pressure-tests/*.md` (adversarial behavioral)
- **Target audience:** Engineering teams building serious software (.NET first-class, Python supported, more stacks pluggable; finance domain supplement included)
- **Tech stack architecture:** Workflow skills are language-agnostic; per-stack context lives in `tech-stack-{name}` skills loaded via `.claude/tech-stack`

---

## Critical Rules (Always Apply)

- **C0.1** Manifest versions must match: `.claude/manifest.json` version == `.claude-plugin/plugin.json` version == `.claude-plugin/marketplace.json` plugin entry version. Bump all three when releasing.
- **C0.2** Every file in the repo must be listed in manifest.json `files` section. Every manifest path must exist on disk.
- **C0.3** Workflow skills must follow the anatomy: frontmatter + `## Overview` + `## When To Use` + `## Workflow` + `## Verification`. Entry-point skills use `allowed-tools` and `argument-hint` in frontmatter. Skill directory name must match frontmatter `name:`.
- **C0.4** Agents and skills must have `---` frontmatter blocks.
- **C0.5** Hooks must be executable (`chmod +x`) and use `set -euo pipefail`.
- **C0.6** Never hardcode secrets, API keys, or user-specific paths in committed files. `.claude/settings.local.json` is gitignored.
- **C0.7** `CLAUDE.md` is protected — `setup-bootstrap` generates it, but subsequent edits are project-specific. Don't overwrite during update.
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
