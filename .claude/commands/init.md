---
description: Bootstrap a repo for implement. Detects tech stack, scans codebase, pulls coding guidelines, and generates a project-specific CLAUDE.md. Run this once per repo.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
---

# Moberg Init — Bootstrap Repository for AI-Assisted Development

You are setting up a repository for the `/moberg:implement` workflow.
Your job is to detect the tech stack, scan the codebase, and generate a tailored `CLAUDE.md` that the implementation and review agents will use as their source of truth.

This bootstrap also prepares the repo for the shared skill layer and OpenCode routing.

## STEP 0: Detect Tech Stack

Scan the repo root for tech stack markers:

| Marker files | Tech stack |
|---|---|
| `*.sln`, `*.slnx`, `*.csproj` | `dotnet` |
| `pyproject.toml`, `setup.py`, `requirements.txt`, `Pipfile` | `python` |
| `package.json` (without `*.csproj`) | `node` (not yet supported — stop and warn) |
| `go.mod` | `go` (not yet supported — stop and warn) |

Detection commands:
```bash
DOTNET=$(find . -maxdepth 3 -name "*.csproj" -o -name "*.sln" -o -name "*.slnx" 2>/dev/null | head -1)
PYTHON=$(find . -maxdepth 2 -name "pyproject.toml" -o -name "setup.py" -o -name "requirements.txt" -o -name "Pipfile" 2>/dev/null | head -1)
```

If multiple stacks detected, ask the engineer:
```
question: "Multiple tech stacks detected. Which is the primary stack for this repo?"
header: "Tech stack"
options:
  - label: "dotnet"
    description: ".NET / C# is the primary stack"
  - label: "python"
    description: "Python is the primary stack"
```

If no supported stack detected, stop and tell the engineer to add a `tech-stack-{name}/` skill or open an issue.

Write the result to `.claude/tech-stack` (plain text, single word):
```bash
echo "dotnet" > .claude/tech-stack
```

Then load `.claude/skills/tech-stack-{stack}/SKILL.md` — this is the source of truth for build commands, scan recipes, and reference paths used in the rest of init.

## STEP 1: Pull External Standards

### Coding Guidelines

Check the active tech stack skill's `## Coding Style Reference` section. If it lists a remote source URL, fetch it:

For `dotnet`:
```
curl -sL https://raw.githubusercontent.com/moberghr/coding-guidelines/main/CodingStyle.md -o .claude/references/dotnet/coding-guidelines.md
```

For `python`: see the placeholder in `.claude/references/python/coding-guidelines.md`. If it's empty, leave it for the team to fill in when starting their first Python project.

If the fetch fails (network restrictions), check if the file already exists. If not, tell the engineer to manually place it.

### Architecture Principles
Check if `.claude/references/architecture-principles.md` exists.
If not, use AskUserQuestion:

```
question: "Architecture principles document not found at .claude/references/architecture-principles.md. How should I proceed?"
header: "Arch doc"
options:
  - label: "Generate from codebase (Recommended)"
    description: "I'll scan the codebase and create a starter architecture-principles.md based on actual patterns found"
  - label: "I'll provide it manually"
    description: "I'll place the file at .claude/references/architecture-principles.md and re-run init"
```

If the engineer picks "Generate from codebase", generate a starter architecture doc based on Step 2 findings.

## STEP 2: Scan the Codebase

Use the **`## Scan Recipes`** section from the active tech stack skill (`.claude/skills/tech-stack-{stack}/SKILL.md`). Each tech stack provides its own scanning bash blocks.

Run the recipes in order:
1. Project Structure
2. Patterns In Use
3. Data Layer
4. Infrastructure
5. Naming Conventions
6. Testing Patterns
7. Configuration

Then run these stack-agnostic checks:
```bash
# Git Conventions
git log --oneline -20
git branch -a | head -20
find . -name "pull_request_template*"
```

Record what you find — this is the input for Step 3.

## STEP 3: Generate CLAUDE.md + Rules Files

The generated output follows Claude Code best practices:
- **Root `CLAUDE.md`** stays **under 200 lines** (better adherence, less context waste)
- **`.claude/rules/*.md`** files hold detailed, topic-specific rules (auto-loaded by Claude Code)
- **`.claude/references/`** files are read on-demand by commands and agents (not duplicated)

### If CLAUDE.md does NOT exist → Generate from scratch

Create `CLAUDE.md` and `.claude/rules/` files following the templates below.

### If CLAUDE.md ALREADY exists → Merge mode (default)

1. Read the existing CLAUDE.md and check if `.claude/rules/` exists
2. **If monolithic CLAUDE.md (>200 lines, contains full rule sections):**
   - Extract each section into the corresponding `.claude/rules/` file
   - Replace CLAUDE.md with the lean template, preserving project-specific content
3. **If lean CLAUDE.md + `.claude/rules/` already exists:**
   - Compare each rules file against scan findings
   - Identify stale, missing, and conflicting content
4. Present a summary:
   ```
   CLAUDE.md Structure Analysis:
     Current: [monolithic N lines | lean + N rule files]
     Proposed changes:
       [list each change]
   ```
5. Apply the changes (in merge mode, don't ask — the engineer chose init knowing it modifies files)

### Root CLAUDE.md Template

**Hard limit: 200 lines.** If it's longer, move detail to `.claude/rules/`.

````markdown
# [Project Name] — Engineering Standards

> Auto-generated by init on [date]. Based on:
> - Tech stack: [stack name from `.claude/tech-stack`]
> - Coding guidelines (`.claude/references/{stack}/coding-guidelines.md`)
> - Architecture principles (`.claude/references/architecture-principles.md`) [or "not found"]
> - Codebase scan of this repository
>
> This file + `.claude/rules/` are the source of truth for AI agents.
> Detailed standards live in `.claude/rules/`. Reference docs live in `.claude/references/`.

---

## Command Routing

| What you need | Command | When |
|---|---|---|
| Build a feature | `/moberg:implement <description>` | New endpoints, tables, handlers, multi-file work |
| Quick fix | `/moberg:fix <description>` | Bug fixes, config tweaks, 1-3 file changes |
| Pre-commit check | `/moberg:quick-check` | Before every commit — fast security scan |
| Install or update toolkit | `/moberg:install` | Idempotent — fresh setup on first run, in-place sync afterwards |

**Decision rule:** If unsure, start with `fix`. If the change grows beyond 3 files, switch to `implement`.

---

## Tech Stack

- **Active stack:** [from `.claude/tech-stack`]
- **Build command:** [from tech stack skill `## Build & Test Commands`]
- **Test command:** [from tech stack skill `## Build & Test Commands`]
- **Format command:** [from tech stack skill `## Format Command`]

For framework-specific guidance, see `.claude/skills/tech-stack-{stack}/SKILL.md`.

---

## Project Profile

[Generate based on scan findings — adapt fields per stack]

For dotnet:
- **Framework:** .NET [version]
- **Data layer:** [EF Core / Dapper / Data API / etc.]
- **Patterns:** [MediatR/CQRS, Result pattern, FluentValidation, etc.]
- **Hosting:** [Lambda / ECS / App Service / etc.]
- **Database:** [PostgreSQL / SQL Server / etc.]
- **Test stack:** [xUnit/NUnit + Moq/NSubstitute + InMemory/SQLite/TestContainers]

For python:
- **Framework:** [Django / FastAPI / Flask / etc.]
- **Python version:** [from pyproject.toml or .python-version]
- **Data layer:** [SQLAlchemy / Django ORM / Tortoise / etc.]
- **Test stack:** [pytest / unittest, mocking framework]
- **Hosting:** [Lambda / ECS / docker / etc.]

---

## Critical Rules (Always Apply)

These are the highest-impact rules — the ones most commonly violated or most damaging when broken. Full detailed standards live in `.claude/rules/`.

[Generate the top 5-10 most critical rules from across all categories, based on what this project actually uses. Pick the rules that, if violated, cause the most damage. Number them §0.1–§0.N.]

---

## Standards Reference

Detailed rules in `.claude/rules/` (auto-loaded by Claude Code):

| File | Covers | Rules |
|---|---|---|
| `security.md` | Auth, secrets, audit, PII | §1.x |
| `architecture.md` | Layers, slices, DI, patterns | §2.x |
| `coding-style.md` | Project-specific style overrides | §3.x |
| `testing.md` | Frameworks, coverage, naming | §4.x |
| `data-layer.md` | ORM, queries, connections | §5.x |
| `performance.md` | Async, caching, connection pooling | §6.x |
| `infrastructure.md` | IaC, containers, cloud services | §7.x |
| `git-workflow.md` | Branches, commits, PRs | §8.x |
| `project-specific.md` | Patterns unique to this repo | §9.x |

Full reference docs (read on-demand by commands and review agents):
- `.claude/references/{stack}/coding-guidelines.md` — Stack-specific coding style
- `.claude/references/architecture-principles.md` — Architecture principles
- `.claude/references/security-checklist.md` — Security checklist (shared)
- Stack-specific references listed in `.claude/skills/tech-stack-{stack}/SKILL.md` `## Reference Files`
````

### .claude/rules/ File Templates

Generate each file below. **Only generate files for sections relevant to this project.** Skip files for technologies the project doesn't use.

Each rules file target: **30–80 lines**. Be concise.

The rule file templates are largely the same as before — adapt the content per tech stack:
- `security.md` — generic, applies to all stacks
- `architecture.md` — based on actual patterns found
- `coding-style.md` — project-specific overrides only (don't duplicate the coding guidelines file)
- `testing.md` — based on test patterns found, reference the tech stack's testing supplement
- `data-layer.md` — based on actual data access patterns (EF Core / SQLAlchemy / etc.)
- `performance.md` — based on actual performance considerations
- `infrastructure.md` — IaC, containers, cloud services found
- `git-workflow.md` — commit and branch conventions
- `project-specific.md` — anything unique

### Rules for Generation
- **Root CLAUDE.md must stay under 200 lines.** Count before finishing. If over, move detail to rules files.
- Every rule in `.claude/rules/` must have a section number (§X.Y) for review agents to cite.
- Include **code examples** from the actual codebase where possible.
- Flag conflicts: "⚠️ Guideline says X, but codebase does Y. Standardize on: [recommendation]"
- Be specific to THIS project — skip technologies not in use.
- **Don't duplicate** content from `.claude/references/` — point to the file instead.
- Skip rules files for sections that don't apply.

## STEP 4: Set Up Supporting Files & Directories

### .claude/rules/ Directory
Create `.claude/rules/` if it doesn't exist:
```bash
mkdir -p .claude/rules
```

### Settings Merge

Read the active tech stack skill's `## Settings Additions` section. Merge those entries into `.claude/settings.json`:
- `allowedTools` — union with existing
- `deny` — union with existing
- `hooks.PostToolUse` — append the stack's format hook

### Commands, Skills, Agents
Ensure the following files exist:
- `.claude/commands/implement.md` — main implementation loop
- `.claude/commands/fix.md` — quick fix loop
- `.claude/commands/install.md` — idempotent install/update
- `.claude/commands/validate.md` — toolkit validation
- `.claude/commands/quick-check.md` — pre-commit scan
- `.claude/skills/spec-driven-development/SKILL.md`
- `.claude/skills/incremental-implementation/SKILL.md`
- `.claude/skills/test-driven-development/SKILL.md`
- `.claude/skills/planning-and-task-breakdown/SKILL.md`
- `.claude/skills/debugging-and-error-recovery/SKILL.md`
- `.claude/skills/code-review-and-quality-fintech/SKILL.md`
- `.claude/skills/tech-stack-{stack}/SKILL.md` — for the active stack
- `.claude/agents/compliance-reviewer.md`
- `.claude/agents/test-reviewer.md`
- `.claude/agents/architecture-reviewer.md`
- `AGENTS.md`

If any are missing, tell the engineer to run `/moberg:install`.

### Quick Check List

Generate `.claude/references/quick-check-list.md` based on scan findings. Use stack-specific items from the tech stack skill where applicable.

If the file already exists, leave it alone.

**Selection rules (per stack):**

For dotnet:
- If EF Core found: `AsNoTracking` on reads, `Select()` over `Include()`, `CancellationToken` propagated
- If MediatR found: one `SaveChanges` per handler, validate request
- If Lambda found: DbContext disposal, cold start considerations

For python:
- If SQLAlchemy found: session management, eager/lazy loading, N+1 patterns
- If FastAPI found: dependency injection, Pydantic validation
- If Django found: select_related/prefetch_related, transaction.atomic

Always include (any stack):
- No PII in logs
- Tests for new public methods
- No hardcoded secrets

**Max 10 items.** Pick the ones most likely to be violated.

### Tasks Directory
Create the `tasks/` directory if it doesn't exist:
```bash
mkdir -p tasks
```

Create `tasks/lessons.md` if it doesn't exist (header only).

Add `tasks/todo.md` to `.gitignore` if not already there. Do NOT gitignore `tasks/lessons.md`.

### Cross-Tool AGENTS.md

Generate a root-level `AGENTS.md` for cross-tool compatibility (Cursor, Copilot, Codex, Gemini CLI). Stack-aware: include the active tech stack's build/test commands and key conventions.

If `AGENTS.md` already exists, leave it alone.

## STEP 5: Verify & Report

```
✅ MOBERG INIT COMPLETE

Project: [name]
Tech stack: [stack name from .claude/tech-stack]

Standards sources:
  ✓ Tech stack skill: .claude/skills/tech-stack-{stack}/SKILL.md
  ✓ Coding guidelines: .claude/references/{stack}/coding-guidelines.md
  ✓ Architecture principles: .claude/references/architecture-principles.md [or ⚠️ not found]
  ✓ Codebase scan: [N] files across [N] projects/modules

Generated/Updated:
  ✓ .claude/tech-stack: [stack]
  ✓ CLAUDE.md ([N] lines — under 200 ✓)
  ✓ .claude/rules/ — [N] rule files generated
  ✓ .claude/references/quick-check-list.md — [generated with N items | already exists, skipped]
  ✓ .claude/settings.json — merged [N] stack-specific entries

Codebase findings:
  [stack-specific summary based on scan]

Commands available:
  /moberg:implement  — Full feature loop
  /moberg:fix        — Quick fix (1-3 files)
  /moberg:quick-check — Fast security scan
  /moberg:install    — Install or update the toolkit (idempotent)

Next: Try it with:
  /moberg:implement Add [your feature description here]
```

## IMPORTANT
- Create `.claude/references/` and `.claude/rules/` directories if they don't exist
- **Default to merge mode** when CLAUDE.md already exists — don't ask overwrite/merge/abort
- If existing CLAUDE.md is monolithic (>200 lines), migrate to lean structure automatically
- If CLAUDE.md doesn't exist, generate from scratch without asking
- The generated files should be committed to the repo
- **Count CLAUDE.md lines before finishing.** If over 200, move content to rules files.
- The `.claude/tech-stack` file is critical — every command reads it. Make sure it's written before reporting completion.
