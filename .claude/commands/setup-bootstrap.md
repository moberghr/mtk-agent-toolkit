---
description: One-time repo setup. Detects tech stack, audits the codebase, pulls coding guidelines, and generates a project-specific CLAUDE.md. Run this once per repo.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
argument-hint: [--preview] [--non-interactive]
---

# MTK Setup Bootstrap — Prepare Repository for AI-Assisted Development

You are setting up a repository for the `/mtk:implement` workflow.
Your job is to detect the tech stack, audit the codebase, and generate a tailored `CLAUDE.md` that the implementation and review agents will use as their source of truth.

This bootstrap also prepares the repo for the shared skill layer and OpenCode routing.

## Modes

Parse arguments before starting:

- **`--preview`** — run detection, scan, and interview, then **show the proposed CLAUDE.md + rules files diff** and ask for confirmation via `AskUserQuestion` before writing anything. Use this when the engineer wants to review before commit. Without `--preview`, the bootstrap writes files directly (merge mode is still the default for existing CLAUDE.md).
- **`--non-interactive`** — skip the post-scan interview (STEP 2.5). Use when scripting the bootstrap or when the engineer has no time for questions. Defaults to interactive.

Both flags can combine: `--preview --non-interactive` runs silently but still asks to confirm writes.

## Research-backed constraints (read this first)

The content you generate is subject to an **instruction budget** — Claude's compliance with CLAUDE.md rules degrades uniformly past ~150 total instructions (Anthropic's system prompt already consumes ~50). The ETH Zurich benchmark across 1,188 runs showed LLM-generated CLAUDE.md files performed *worst*. Anthropic's own cookbook CLAUDE.md is ~80 lines. HumanLayer's production file is <60 lines. Boris Cherny (Claude Code creator) uses ~100.

**Therefore:**

1. **Root CLAUDE.md target: 60–80 lines. Hard cap: 120 lines.** If you can't get under 120, something belongs in `.claude/rules/` or a hook, not CLAUDE.md.
2. **Trigger-action, negative phrasing sticks better.** Prefer `WHEN X, DO NOT Y` and `NEVER Z` over `Always follow X`. Use `IMPORTANT:` / `YOU MUST` markers sparingly for the top 1–2 rules.
3. **Mechanize what you can.** If a rule can live in a hook or `settings.json` deny-list, put it there and do NOT duplicate in CLAUDE.md.
4. **No aspirational rules.** Every rule must come from an actual pattern or actual failure mode in this codebase. If you're inventing it, drop it.
5. **No list-of-everything.** Omit rules Claude can figure out from reading the code (e.g., "use async/await" in a JS project).

## STEP 0: Detect Tech Stack

Scan the repo root for tech stack markers:

| Marker files | Tech stack |
|---|---|
| `*.sln`, `*.slnx`, `*.csproj` | `dotnet` |
| `pyproject.toml`, `setup.py`, `requirements.txt`, `Pipfile` | `python` |
| `package.json`, `tsconfig.json` (and no `*.csproj`) | `typescript` (covers React, Next.js, Tauri, Node backends) |
| `go.mod` | `go` (not yet supported — stop and warn) |

Detection commands:
```bash
DOTNET=$(find . -maxdepth 3 -name "*.csproj" -o -name "*.sln" -o -name "*.slnx" 2>/dev/null | head -1)
PYTHON=$(find . -maxdepth 2 -name "pyproject.toml" -o -name "setup.py" -o -name "requirements.txt" -o -name "Pipfile" 2>/dev/null | head -1)
TYPESCRIPT=$(find . -maxdepth 2 -name "package.json" -not -path "*/node_modules/*" 2>/dev/null | head -1)
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
  - label: "typescript"
    description: "TypeScript / JavaScript is the primary stack (React, Next.js, Tauri, Node)"
```

If no supported stack detected, stop and tell the engineer to add a `tech-stack-{name}/` skill or open an issue.

Write the result to `.claude/tech-stack` (plain text, single word):
```bash
echo "dotnet" > .claude/tech-stack
```

Then load `.claude/skills/tech-stack-{stack}/SKILL.md` — this is the source of truth for build commands, scan recipes, and reference paths used in the rest of init.

### Package manager auto-detect (typescript only)

When the active stack is `typescript`, also write the detected package manager to `.claude/tech-stack-pm` so workflow skills can substitute `<pm>` in commands. Pick automatically by lockfile priority:

```bash
if [ -f bun.lock ] || [ -f bun.lockb ]; then PM=bun
elif [ -f pnpm-lock.yaml ]; then PM=pnpm
elif [ -f yarn.lock ]; then PM=yarn
else PM=npm  # package-lock.json or no lockfile
fi
echo "$PM" > .claude/tech-stack-pm
```

If multiple lockfiles exist (e.g. both `yarn.lock` and `package-lock.json`), that's almost always a mistake — warn the engineer and pick the highest-priority one. Do not prompt; the priority order is: bun > pnpm > yarn > npm.

## STEP 1: Pull External Standards

### Coding Guidelines

Check the active tech stack skill's `## Coding Style Reference` section. If it lists a remote source URL, fetch it:

For `dotnet`:
```
curl -sL https://raw.githubusercontent.com/moberghr/coding-guidelines/main/CodingStyle.md -o .claude/references/dotnet/coding-guidelines.md
```

For `python`: see the placeholder in `.claude/references/python/coding-guidelines.md`. If it's empty, leave it for the team to fill in when starting their first Python project.

For `typescript`: see the placeholder in `.claude/references/typescript/coding-guidelines.md`. The defaults in the placeholder (strict `tsconfig.json`, Biome, ESM, naming conventions) are reasonable until the team formalizes its own guide.

If the fetch fails (network restrictions), check if the file already exists. If not, tell the engineer to manually place it.

### Architecture Principles
Check if `.claude/references/architecture-principles.md` exists.

- **If it exists:** leave it alone — init respects prior architecture decisions.
- **If it does NOT exist:** auto-generate it from the Step 2 audit findings using the same template as `/mtk:setup-audit` (descriptive audit of actual patterns, with "⚠️ Inconsistency" flags where the codebase disagrees with itself). No prompt — this is the one-time bootstrap.

To refresh the file later as the architecture evolves, the engineer runs `/mtk:setup-audit` explicitly.

## STEP 2: Audit the Codebase

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

## STEP 2.5: Post-Scan Interview (skip if `--non-interactive`)

Auto-detection captures WHAT is in the codebase. It cannot capture the team's implicit knowledge — the things that make CLAUDE.md actually useful. Ask **3–5 focused questions** via `AskUserQuestion`. These answers feed directly into the Critical Rules and `project-specific.md`.

**Rules for the interview:**
- Keep it short. 5 questions max. If the engineer pushes back or seems unsure, accept "skip" as a valid answer.
- Do NOT ask anything you can answer from the scan (e.g., "what's your test framework" — you already know).
- Frame for answers you can convert into trigger-action rules.
- Record answers; integrate into Step 3 output.

**Question set (adapt wording per stack):**

1. **Top failure modes** — "What are the 2–3 things AI assistants (or junior engineers) get wrong most often in this codebase?" Convert each answer into a `WHEN X, DO NOT Y` rule.

2. **Hard nevers** — "What should an AI **never** do in this repo without explicit approval?" Examples to prompt with: "touch migrations / modify financial state without audit trail / change auth middleware / drop caches / skip the review step". These become the top Critical Rules (§0.x).

3. **Invisible conventions** — "Is there an architectural or naming convention that isn't obvious from reading the code?" (e.g., "all money is `decimal` with 4-digit scale", "handlers must emit a domain event", "routes live in `Endpoints/` not `Controllers/` even though we use MVC").

4. **Branch + PR workflow** — only ask if recent `git log` / PR templates didn't make this obvious. "How do you name branches and what's the PR convention?"

5. **Compliance / regulatory constraints** (fintech-specific, always ask for fintech repos) — "Are there compliance constraints that should surface in reviews? (e.g., PII handling, audit log requirements, SOC2 scope, PCI scope)"

**What to do with answers:**
- Each `hard never` → top of Critical Rules, with `IMPORTANT:` prefix.
- Each `top failure mode` → rule in the relevant `.claude/rules/` file (e.g., failure about EF queries → `data-layer.md`).
- Each `invisible convention` → `project-specific.md`.
- Compliance answers → fold into `security.md` with `§1.x` numbering.

If `--non-interactive` is passed, skip this entire step but print a notice:
```
⚠️ Interview skipped. CLAUDE.md will be auto-detected only — consider running without --non-interactive for better team-specific rules.
```

## STEP 3: Generate CLAUDE.md + Rules Files

The generated output follows Claude Code best practices:
- **Root `CLAUDE.md`** target **60–80 lines**, hard cap **120 lines** (ETH Zurich benchmark + HumanLayer + Anthropic cookbook). Past ~150 instructions, compliance degrades uniformly — every line must earn its place.
- **`.claude/rules/*.md`** files hold detailed, topic-specific rules (auto-loaded by Claude Code)
- **`.claude/references/`** files are read on-demand by commands and agents (not duplicated)
- **Hooks / `settings.json` deny-list** handle anything mechanically enforceable (formatting, secret scanning, banned commands) — do NOT duplicate those rules in CLAUDE.md.

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

**Target: 60–80 lines. Hard cap: 120 lines.** If it's longer, move detail to `.claude/rules/` or delete speculative rules entirely. Count before finishing.

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
| Build a feature | `/mtk:implement <description>` | New endpoints, tables, handlers, multi-file work |
| Quick fix | `/mtk:fix <description>` | Bug fixes, config tweaks, 1-3 file changes |
| Pre-commit check | `/mtk:pre-commit-review` | Before every commit — fast security-focused review |

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

For typescript:
- **Framework:** [React / Next.js / Tauri / Express / Fastify / Hono / NestJS / etc.]
- **Package manager:** [from `.claude/tech-stack-pm` — bun / pnpm / yarn / npm]
- **Build tool:** [Vite / Next / tsup / Rollup / Tauri / etc.]
- **Data layer:** [Prisma / Drizzle / TypeORM / Kysely / none (client-only) / etc.]
- **State / data fetching:** [TanStack Query / SWR / tRPC / Zustand / Redux / etc.]
- **Test stack:** [Vitest / Jest / Playwright / RTL / MSW / etc.]
- **Hosting:** [Vercel / Cloudflare Workers / AWS Lambda / Tauri desktop binary / etc.]
- **Tauri sidecar:** [Yes — `src-tauri/Cargo.toml` present / No]

---

## Critical Rules (Always Apply)

These are the highest-impact rules — the ones most commonly violated or most damaging when broken. Full detailed standards live in `.claude/rules/`.

[Generate the top **3–5** most critical rules (not 10 — every extra rule dilutes adherence). Prefer interview "hard nevers" first, then scan-derived failure modes. Number them §0.1–§0.N.

**Phrasing rules (non-negotiable):**
- Use trigger-action form: `WHEN X, DO NOT Y` or `NEVER Z WITHOUT W`.
- Negatives beat positives. `NEVER commit secrets` > `Always keep secrets safe`.
- Prefix the top 1–2 most damaging rules with `IMPORTANT:` or `YOU MUST` (research shows measurable compliance improvement — but only works if used sparingly).
- If a rule can be enforced by a hook, `settings.json` deny-list, or pre-commit-review-list, put it there and DO NOT list it here.
- Every rule must point to a concrete failure mode in this codebase — no aspirational rules.]

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
- **Root CLAUDE.md target 60–80 lines, hard cap 120.** Count before finishing. If over 120, move detail to rules files or delete speculative rules.
- Every rule in `.claude/rules/` must have a section number (§X.Y) for review agents to cite.
- Include **code examples** from the actual codebase where possible.
- Flag conflicts: "⚠️ Guideline says X, but codebase does Y. Standardize on: [recommendation]"
- Be specific to THIS project — skip technologies not in use.
- **Don't duplicate** content from `.claude/references/` — point to the file instead.
- Skip rules files for sections that don't apply.

## STEP 3.5: Preview Gate (if `--preview`)

If the engineer passed `--preview`, **do not write any files yet**. Instead:

1. Hold the generated content in memory (CLAUDE.md body, each `.claude/rules/*.md` body, AGENTS.md, pre-commit-review-list).
2. Print a plan summary:
   ```
   📋 PROPOSED CHANGES (preview — nothing written yet)

   CLAUDE.md                                   [NEW | MERGE | REPLACE — N lines, cap 120]
   .claude/rules/security.md                   [NEW — N lines]
   .claude/rules/architecture.md               [NEW — N lines]
   .claude/rules/testing.md                    [NEW — N lines]
   .claude/rules/data-layer.md                 [NEW — N lines]
   .claude/rules/project-specific.md           [NEW — N lines]
   .claude/references/pre-commit-review-list.md [NEW — N items]
   AGENTS.md                                   [NEW | SKIP — already exists]

   Critical Rules (top of CLAUDE.md):
     §0.1 [first rule]
     §0.2 [second rule]
     ...

   Tech stack:  [stack]
   Package mgr: [pm, if ts]
   ```
3. Print the full CLAUDE.md body inline (inside a fenced code block) so the engineer can review it.
4. Ask via `AskUserQuestion`:
   ```
   question: "Proceed with writing these files?"
   header: "Bootstrap confirmation"
   options:
     - label: "Yes, write all"
       description: "Commit the proposed files as shown"
     - label: "Yes, but skip CLAUDE.md"
       description: "Write rules files only — I'll author CLAUDE.md myself"
     - label: "Cancel"
       description: "Discard the proposed output"
   ```
5. On "Cancel", stop and leave the repo untouched.
6. On "skip CLAUDE.md", write everything except root CLAUDE.md.
7. On "Yes, write all", proceed to STEP 4.

Without `--preview`, skip this step and write directly.

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
- `.claude/commands/pre-commit-review.md` — pre-commit security review
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

If any are missing, tell the engineer to re-install the MTK plugin from the marketplace (`/plugin install mtk@moberghr`).

### Pre-Commit Review List

Generate `.claude/references/pre-commit-review-list.md` based on audit findings. Use stack-specific items from the tech stack skill where applicable.

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

For typescript:
- If React found: Rules of Hooks, SSR-safe browser access, stable list keys
- If Next.js found: `'use client'` at the boundary, server actions validated, `next/image` / `next/font` over raw tags
- If Tauri found: allowlist discipline, every `#[tauri::command]` validates input, no `all: true`
- If Prisma / Drizzle found: `select` projection over `include`, indexes on foreign keys, paginated list queries
- If TanStack Query found: explicit `staleTime`, stable `queryKey`, no server-state duplication in `useState`

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

## STEP 4.5: Monorepo — Per-Package CLAUDE.md (conditional)

Research-backed: a documented monorepo case study reduced per-session context load by ~80% by splitting a 47k-word monolithic CLAUDE.md into a ~9k-word root + short per-package files that load on-demand when Claude accesses those directories.

### Detect if this is a monorepo

Run these checks in parallel:

```bash
# JS/TS workspaces
LERNA=$(test -f lerna.json && echo "yes")
PNPM_WS=$(test -f pnpm-workspace.yaml && echo "yes")
TURBO=$(test -f turbo.json && echo "yes")
NX=$(test -f nx.json && echo "yes")
RUSH=$(test -f rush.json && echo "yes")
PKG_WORKSPACES=$(grep -l '"workspaces"' package.json 2>/dev/null)

# .NET multi-project solutions
SLN_COUNT=$(find . -maxdepth 2 -name "*.sln" -o -name "*.slnx" 2>/dev/null | wc -l | tr -d ' ')
CSPROJ_COUNT=$(find . -maxdepth 4 -name "*.csproj" -not -path "*/bin/*" -not -path "*/obj/*" 2>/dev/null | wc -l | tr -d ' ')

# Python multi-package
PYPROJECT_COUNT=$(find . -maxdepth 3 -name "pyproject.toml" -not -path "*/.venv/*" -not -path "*/node_modules/*" 2>/dev/null | wc -l | tr -d ' ')

# Conventional layout
HAS_APPS=$(test -d apps && echo "yes")
HAS_PACKAGES=$(test -d packages && echo "yes")
HAS_SERVICES=$(test -d services && echo "yes")
HAS_LIBS=$(test -d libs && echo "yes")
```

**Classification:**
- **Not a monorepo** if: single `*.sln` with ≤3 `*.csproj` in a linear hierarchy, or single `pyproject.toml` at root, or single `package.json` with no `workspaces`. Skip the rest of this step.
- **Monorepo** if: any of LERNA/PNPM_WS/TURBO/NX/RUSH/PKG_WORKSPACES is set, OR `CSPROJ_COUNT >= 4`, OR `SLN_COUNT >= 2`, OR `PYPROJECT_COUNT >= 2`, OR any of the conventional layout dirs exist and contain >1 subdirectory with a project marker.

If classification is ambiguous, ask via `AskUserQuestion`:
```
question: "Is this a monorepo? (Multiple packages/services sharing a repo)"
header: "Repo layout"
options:
  - label: "Yes — generate per-package CLAUDE.md files"
    description: "Short per-directory files pointing to root CLAUDE.md"
  - label: "No — single project"
    description: "Skip per-package generation"
```

### Enumerate packages

Build the list of package directories:

- **JS/TS workspaces:** read `workspaces` from `package.json`, `packages` from `pnpm-workspace.yaml`, or globs from `turbo.json` / `nx.json`. Expand globs.
- **.NET:** each directory containing a `*.csproj` is a package. Group by top-level folder if there's a clear `src/<Module>/<Project>.csproj` pattern.
- **Python:** each directory containing a `pyproject.toml`.
- **Convention-based:** each immediate subdirectory of `apps/`, `services/`, `packages/`, `libs/` that contains a project marker.

Cap at **20 packages**. If there are more, pick the top 20 by file count and print a note: "Skipped N packages — generate per-package CLAUDE.md manually for any that need special context."

### Generate per-package CLAUDE.md

**For each package**, create `<package-path>/CLAUDE.md` **only if it doesn't already exist** (never overwrite — these may be hand-authored).

Each file targets **15–30 lines**. It should contain the **local delta** — what Claude needs to know here that isn't already in root CLAUDE.md. No repeated rules, no general guidance.

Template:

```markdown
# [Package Name] — Local Context

> This package lives in a monorepo. See root `CLAUDE.md` for team-wide standards.
> This file only documents what's specific to this package.

## What this is
[One or two sentences. Inferred from README, package.json description, .csproj description, or directory name.]

## Framework / runtime
[From package.json dependencies, .csproj TargetFramework, pyproject.toml requires-python, etc. Only note if it differs from the root default.]

## Build / test (local)
[Only if commands differ from root. Otherwise omit this section.]
```bash
[package-specific commands, if any]
```

## Local conventions
[Only patterns unique to this package. Examples:
 - "No I/O — this is a pure domain package"
 - "Client-only — no server imports"
 - "Public API package — changes require version bump"
 - "This service owns the <X> database schema"
]

## Dependencies / boundaries
[Only if there are notable dependency rules:
 - "Imports from ../core only — never from ../web"
 - "This package is consumed by the SDK — breaking changes require a major bump"
]
```

**Rules for per-package generation:**
- **Omit any section you can't fill with something specific.** An empty "Local conventions" section is worse than no section.
- If a package has no notable local delta (e.g., a trivial shared `types/` package), generate a 5-line stub:
  ```markdown
  # [Name] — Local Context

  > See root `CLAUDE.md`. No package-specific conventions beyond the root standards.
  ```
- Never duplicate rules from root. If a rule appears in root, do not re-state it locally.
- Never overwrite an existing per-package `CLAUDE.md` — skip with a note.

### Update root CLAUDE.md

Add a short **Monorepo Layout** block to the root CLAUDE.md (inside the 120-line cap — this earns its place because it helps Claude navigate):

```markdown
## Monorepo Layout

This is a monorepo with [N] packages. Each package has its own `CLAUDE.md` with local context.

- `apps/api/` — [one-line purpose]
- `apps/web/` — [one-line purpose]
- `packages/core/` — [one-line purpose]
- ...

Claude loads package-level `CLAUDE.md` files automatically when working in that directory.
```

If the root is already near 120 lines, collapse each entry to a single line and skip the one-line purpose.

## STEP 5: Verify & Report

```
✅ MTK INIT COMPLETE

Project: [name]
Tech stack: [stack name from .claude/tech-stack]

Standards sources:
  ✓ Tech stack skill: .claude/skills/tech-stack-{stack}/SKILL.md
  ✓ Coding guidelines: .claude/references/{stack}/coding-guidelines.md
  ✓ Architecture principles: .claude/references/architecture-principles.md [or ⚠️ not found]
  ✓ Codebase scan: [N] files across [N] projects/modules

Generated/Updated:
  ✓ .claude/tech-stack: [stack]
  ✓ CLAUDE.md ([N] lines — under 120 ✓)
  ✓ .claude/rules/ — [N] rule files generated
  ✓ .claude/references/pre-commit-review-list.md — [generated with N items | already exists, skipped]
  ✓ .claude/settings.json — merged [N] stack-specific entries
  [if monorepo:]
  ✓ Monorepo detected — [N] packages found
      ✓ Generated per-package CLAUDE.md for: [list of packages]
      [⚠️ Skipped (already exists): list of packages]

Codebase findings:
  [stack-specific summary based on scan]

Commands available:
  /mtk:implement         — Full feature loop
  /mtk:fix               — Quick fix (1-3 files)
  /mtk:pre-commit-review — Fast security-focused review of staged changes
  /mtk:setup-audit       — Re-run architecture audit

Next: Try it with:
  /mtk:implement Add [your feature description here]
```

## IMPORTANT
- Create `.claude/references/` and `.claude/rules/` directories if they don't exist
- **Default to merge mode** when CLAUDE.md already exists — don't ask overwrite/merge/abort
- If existing CLAUDE.md is monolithic (>200 lines), migrate to lean structure automatically
- If CLAUDE.md doesn't exist, generate from scratch without asking
- The generated files should be committed to the repo
- **Count CLAUDE.md lines before finishing.** Target 60–80. If over 120, move content to rules files or delete speculative rules.
- **Per-package CLAUDE.md files are never overwritten.** If one already exists, skip it and report it as skipped. These may be hand-authored.
- **Per-package files must be small (15–30 lines) and contain only the local delta.** If a package has no notable delta, generate the 5-line stub pointing to root.
- The `.claude/tech-stack` file is critical — every command reads it. Make sure it's written before reporting completion.
