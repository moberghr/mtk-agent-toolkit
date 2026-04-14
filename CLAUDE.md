# claude-helpers — MTK Standards

> Updated 2026-04-13 for v5.4.0 (renamed commands: `init` → `setup-bootstrap`, `scan` → `setup-audit`, `quick-check` → `pre-commit-review`; removed `install` and `validate` user commands in favor of marketplace install and `bash scripts/validate-toolkit.sh`).
>
> This file + `.claude/rules/` are the source of truth for AI agents.
> Detailed standards live in `.claude/rules/`. Reference docs live in `.claude/references/` (shared) and `.claude/references/{stack}/` (stack-specific).

---

## Command Routing

| What you need | Command | When |
|---|---|---|
| Add/modify a skill, command, or agent | `/mtk:implement <description>` | New skills, multi-file changes, structural work |
| Quick fix | `/mtk:fix <description>` | Bug fixes, typos, single-file changes |
| Validate toolkit | `bash scripts/validate-toolkit.sh` | Before every commit — structural check of manifest, plugin.json, and skill anatomy |

**Decision rule:** If the change touches only 1-2 files (typo fix, hook tweak), use `fix`. If it adds a new skill, command, or agent, use `implement`.

---

## Build & Test

```bash
# Validate toolkit structure and manifest integrity
bash scripts/validate-toolkit.sh

# No dotnet build — this is a markdown/bash/JSON toolkit, not a .NET app
# Pressure tests are manual: read tests/pressure-tests/*.md and verify skill behavior
```

---

## Project Profile

- **Type:** Claude Code plugin / shared toolkit
- **Languages:** Markdown (commands, skills, agents, references), Bash (hooks, scripts), JSON (manifest, settings, plugin)
- **Distribution:** Claude Code plugin marketplace via `.claude-plugin/plugin.json`
- **Version tracking:** `.claude/manifest.json` + `.claude-plugin/plugin.json` (must stay in sync)
- **Test approach:** `scripts/validate-toolkit.sh` (structural) + `tests/pressure-tests/*.md` (adversarial behavioral)
- **Target audience:** Engineering teams building serious software (.NET first-class, Python supported, more stacks pluggable; finance domain supplement included)
- **Tech stack architecture:** Workflow skills are language-agnostic; per-stack context lives in `tech-stack-{name}` skills loaded via `.claude/tech-stack`

---

## Critical Rules (Always Apply)

- **C0.1** Manifest versions must match: `.claude/manifest.json` version == `.claude-plugin/plugin.json` version. Bump both when releasing.
- **C0.2** Every file in the repo must be listed in manifest.json `files` section. Every manifest path must exist on disk.
- **C0.3** Skills must follow the anatomy: frontmatter + `## Overview` + `## When To Use` + `## Workflow` + `## Verification`. Skill directory name must match frontmatter `name:`.
- **C0.4** Commands, agents, and skills must have `---` frontmatter blocks.
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
