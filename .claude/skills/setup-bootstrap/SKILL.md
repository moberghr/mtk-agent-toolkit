---
name: setup-bootstrap
description: One-time repo setup that detects tech stack, audits the codebase, pulls coding guidelines, and generates a project-specific CLAUDE.md
type: skill
---

# MTK Setup Bootstrap — Prepare Repository for AI-Assisted Development

## MTK File Resolution

MTK skills and shared references live either in the project (local install) or the plugin cache (marketplace install). Resolve once:

1. If `$CLAUDE_PLUGIN_ROOT` is set, prefix `.claude/skills/` and `.claude/references/` reads with it.
2. Otherwise, if `.claude/skills/context-engineering/SKILL.md` exists locally → project-relative paths work as-is.
3. Otherwise, fall back to `find ~/.claude/plugins -maxdepth 8 -name "SKILL.md" -path "*/mtk/*/context-engineering/*" -type f 2>/dev/null | head -1 | sed 's|/.claude/skills/context-engineering/SKILL.md||'`. If empty, MTK skills are unavailable — warn the engineer and proceed with `CLAUDE.md` only.

Always project-relative (never prefixed): `CLAUDE.md`, `.claude/tech-stack`, `.claude/rules/`, `tasks/`, `docs/`, `.claude/references/architecture-principles.md`, `.claude/references/pre-commit-review-list.md`.

---

You are setting up a repository for the `/mtk` workflows.
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

> ⚠️ **`.claude/tech-stack` is a FILE, not a directory.** Never include it in a `mkdir -p` list — that will create it as a directory and the `echo > .claude/tech-stack` below will then fail. If you later need to create `.claude/rules/` or other dirs (STEP 4), run that `mkdir -p` separately without `.claude/tech-stack` in the argument list.
>
> ⚠️ **Do not chain `mkdir` + `rm -rf` + `echo >` into one shell command.** Conservative permission modes reject any command that contains `rm -rf`, causing the entire chain to abort. Run each step as its own Bash call so a single denied command doesn't take down the bootstrap.

Then load `.claude/skills/tech-stack-{stack}/SKILL.md` — this is the source of truth for build commands, scan recipes, and reference paths used in the rest of init.

### Tool Prerequisites Check

After detecting the tech stack, run the prerequisites check:

```bash
bash hooks/check-prerequisites.sh
```

This checks for recommended tools (shellcheck, shfmt, jq, plus stack-specific tools like ruff/mypy for Python, dotnet-format for .NET, etc.). Missing tools are reported as warnings in the final report — they never block bootstrap. Include the output in the STEP 5 verification report.

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
- **If it does NOT exist:** auto-generate it from the Step 2 audit findings using the same template as `/mtk-setup --audit` (descriptive audit of actual patterns, with "⚠️ Inconsistency" flags where the codebase disagrees with itself). No prompt — this is the one-time bootstrap.

To refresh the file later as the architecture evolves, the engineer runs `/mtk-setup --audit` explicitly.

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

5. **Compliance / regulatory constraints** (always ask for regulated domains) — "Are there compliance constraints that should surface in reviews? (e.g., PII handling, audit log requirements, SOC2 scope, PCI scope)"

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
- **`.claude/references/`** files are read on-demand by skills and agents (not duplicated)
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

## Skill Routing

| What you need | Skill | When |
|---|---|---|
| Build a feature | `/mtk <feature description>` | New endpoints, tables, handlers, multi-file work (routes to implement) |
| Quick fix | `/mtk fix <description>` | Bug fixes, config tweaks, 1-3 file changes |
| Pre-commit check | `/mtk review before commit` | Before every commit — fast security-focused review |

**Decision rule:** If unsure, start with `fix`. If the change grows beyond 3 files, switch to `implement`.

---

## Tech Stack

- **Active stack:** [from `.claude/tech-stack`]
- **Build command:** [from tech stack skill `## Build & Test Commands`]
- **Test command:** [from tech stack skill `## Build & Test Commands`]
- **Format:** [human-readable form of the format command from tech stack skill `## Format Command` — strip `$CLAUDE_FILE` and show the base command, e.g., `dotnet format --verbosity quiet` not `dotnet format --include "$CLAUDE_FILE"`. The hook in settings.json handles per-file targeting; CLAUDE.md is for human readers.]

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

Full reference docs (read on-demand by skills and review agents):
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
- **Cache-stable ordering:** put invariants (Critical Rules, Standards Reference, Tech Stack commands) near the top; volatile state (project profile with versions, monorepo layout) below. This keeps the prompt prefix stable across sessions so prompt caching stays warm. See `.claude/skills/writing-skills/SKILL.md` `## Cache-Stable Prefixes`.

## STEP 3.5a: Verify Generated References

Before writing files (or presenting preview), validate every concrete directory, project, and file claim in ALL generated content. This prevents stale references from appearing when bootstrap runs alongside cleanup or when solution files reference deleted projects.

**Scope:** Verify claims in ALL generated files — `CLAUDE.md`, `.claude/references/architecture-principles.md`, every `.claude/rules/*.md`, and (if monorepo) every per-package `CLAUDE.md`.

**Verification procedure:**

1. **Directory claims — use `test -d`, not inference.** For every directory mentioned as existing or containing something, run `test -d`:
   ```bash
   # Collect all directory-like references from generated content.
   # Catch both PascalCase (src/Infrastructure/) and lowercase (apps/api/, packages/core/).
   for file in CLAUDE.md .claude/references/architecture-principles.md .claude/rules/*.md; do
     [ -f "$file" ] || continue
     grep -oE '[a-zA-Z0-9_./-]+/' "$file" | grep -v '^//' | grep -v '^\.' | sort -u | while read dir; do
       # Skip obvious non-paths: URLs, code patterns, comment fragments
       case "$dir" in http*|ftp*|//|.*/) continue ;; esac
       [ ! -d "$dir" ] && echo "STALE in $file: directory '$dir' referenced but not found on disk"
     done
   done
   ```

2. **Project file claims — verify each named file exists.** For `.csproj`, `package.json`, `pyproject.toml`, or any project marker referenced by name:
   ```bash
   # .NET
   for file in CLAUDE.md .claude/references/architecture-principles.md .claude/rules/*.md; do
     [ -f "$file" ] || continue
     grep -oE '[A-Za-z0-9._-]+\.csproj' "$file" 2>/dev/null | sort -u | while read proj; do
       find . -name "$proj" -not -path "*/bin/*" -not -path "*/obj/*" 2>/dev/null | grep -q . || echo "STALE in $file: $proj not found"
     done
   done
   ```

3. **Framework / version claims — verify against actual files:**
   ```bash
   # .NET TargetFramework
   grep -rh "TargetFramework" --include="*.csproj" | sort -u
   # TypeScript — check package.json "engines" or tsconfig "target"
   # Python — check pyproject.toml "requires-python" or .python-version
   ```

4. **Solution membership vs disk reality (.NET).** Solution files can reference projects that have been deleted. Do NOT trust `.sln`/`.slnx` project lists as proof of existence — always `test -d` the project directory:
   ```bash
   # Extract project paths from solution file and verify each
   grep 'Project(' *.sln 2>/dev/null | grep -oE '"[^"]+\.csproj"' | tr -d '"' | while read proj; do
     [ ! -f "$proj" ] && echo "STALE: solution references $proj but file does not exist"
   done
   ```

5. **Rules files — check for specific project/directory/service references:**
   For each `.claude/rules/*.md`, scan for proper nouns that look like project or directory names. Verify each with `test -d` or `test -f`.

**Action on stale references:**

- If a directory/project is referenced as "exists" but doesn't → remove the reference or mark as removed.
- If a directory/project is referenced as "not on disk" but does exist → correct the claim.
- If a framework version is claimed but no project file uses it → remove the claim.
- If a solution references a project that doesn't exist on disk → note the stale solution entry but do NOT modify the `.sln` file.
- Re-run this check after any file deletions or renames in the same session.

**Rule:** Never infer disk presence from solution membership, package manifests, or lock files alone. The `test -d` / `test -f` check is the source of truth. The generated content must reflect the repository state AT THE TIME OF WRITING, not at the time of scanning.

## STEP 3.5b: Preview Gate (if `--preview`)

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

> ⚠️ Do NOT add `.claude/tech-stack` to this `mkdir -p` — it is a file, written in STEP 0. Only directories belong here.

### Settings Merge

Read the active tech stack skill's `## Settings Additions` section. Merge those entries into `.claude/settings.json`:
- `allowedTools` — union with existing
- `deny` — union with existing
- `hooks.PostToolUse` — append the stack's format hook

### Git Pre-Commit Hook

Install the deterministic linter as a git pre-commit hook so critical findings (secrets, raw SQL, etc.) block the commit automatically.

```bash
HOOK_TARGET=".git/hooks/pre-commit"
HOOK_SOURCE="hooks/git-hooks/pre-commit"
```

1. **If `.git/hooks/pre-commit` does not exist** — create a symlink:
   ```bash
   ln -s ../../hooks/git-hooks/pre-commit .git/hooks/pre-commit
   ```
2. **If `.git/hooks/pre-commit` exists and is already a symlink to our hook** — skip (idempotent).
   ```bash
   # Check with: readlink .git/hooks/pre-commit
   ```
3. **If `.git/hooks/pre-commit` exists but is something else** — do NOT overwrite. Print a warning:
   ```
   ⚠️ Existing git pre-commit hook found at .git/hooks/pre-commit.
   MTK's deterministic linter was NOT installed as a git hook.
   To chain it manually, add this line to your existing hook:
     exec hooks/git-hooks/pre-commit
   ```

The hook runs `hooks/pre-commit-linters.sh --cached` (< 1 second) and blocks on critical findings. Engineers bypass with `git commit --no-verify`. The full AI review (`/mtk review before commit`) remains a separate, manual step.

### Skills and Agents
Ensure the following files exist:
- `.claude/skills/implement/SKILL.md` — main implementation loop
- `.claude/skills/fix/SKILL.md` — quick fix loop
- `.claude/skills/pre-commit-review/SKILL.md` — pre-commit security review
- `.claude/skills/spec-driven-development/SKILL.md`
- `.claude/skills/incremental-implementation/SKILL.md`
- `.claude/skills/test-driven-development/SKILL.md`
- `.claude/skills/planning-and-task-breakdown/SKILL.md`
- `.claude/skills/debugging-and-error-recovery/SKILL.md`
- `.claude/skills/code-review-and-quality/SKILL.md`
- `.claude/skills/tech-stack-{stack}/SKILL.md` — for the active stack
- `.claude/agents/compliance-reviewer.md`
- `.claude/agents/test-reviewer.md`
- `.claude/agents/architecture-reviewer.md`
- `AGENTS.md`

If any are missing, tell the engineer to re-install the MTK plugin from the marketplace (`/plugin install mtk@moberghr`).

### Reference File Customization

Shared reference files ship as generic, multi-stack guidance with "match existing" placeholders. After confirming they exist, substitute those placeholders with concrete scan findings so that every subsequent `/mtk` implement and review run gets project-specific guidance without re-scanning.

**When to customize:** Only when the scan found exactly ONE tool in a category (unambiguous evidence).
**When NOT to customize:** If the scan found multiple tools (e.g., both xUnit and NUnit), or zero matches — leave the generic guidance intact.

**Customization table — dotnet:**

| Category | File to patch | Generic pattern to find | Example replacement |
|---|---|---|---|
| Test framework | `{stack}/testing-supplement.md` | `xUnit, NUnit, or MSTest — match the project's existing choice.` | `xUnit only. Do not introduce NUnit or MSTest.` |
| Mocking library | `{stack}/testing-supplement.md` | `Mocking: Moq, NSubstitute, or FakeItEasy — match existing.` | `Mocking: NSubstitute only. Do not introduce Moq or FakeItEasy.` |
| Integration test base | `{stack}/testing-supplement.md` | `WebApplicationFactory<T> for ASP.NET Core, IClassFixture for shared setup` | Keep as-is (both are standard); but if TestContainers detected, append: `TestContainers is the standard integration test infrastructure in this repo.` |
| ORM | `{stack}/ef-core-checklist.md` | No generic pattern (EF-only file) | If Dapper also detected alongside EF Core, add a note: `This repo also uses Dapper for [raw SQL / read-side queries]. Do not migrate Dapper queries to EF Core unless explicitly asked.` |
| Validation | `{stack}/mediatr-slice-patterns.md` | `Validate requests using the project-standard approach.` | `Validate requests using FluentValidation.` (or `DataAnnotations`, or whatever was detected) |

**Customization table — typescript:**

| Category | File to patch | Generic pattern to find | Example replacement |
|---|---|---|---|
| Test framework | `{stack}/testing-supplement.md` | (Multiple frameworks listed in `## Test Framework`) | If Vitest only: remove Jest/Playwright guidance paragraphs. If Jest only: remove Vitest paragraphs. Leave both if both detected. |
| Component testing | `{stack}/testing-supplement.md` | `@testing-library/react for React component tests` | If no React detected, remove this section entirely. |
| Data fetching | `{stack}/testing-supplement.md` | `## TanStack Query in Tests` | If no TanStack Query detected, remove this section. |
| State management | `{stack}/framework-patterns.md` | Generic state patterns | Narrow to detected library (Zustand, Redux, etc.) |
| Data layer | `{stack}/data-layer-checklist.md` | Multi-ORM guidance | Narrow to detected ORM (Prisma, Drizzle, etc.) |

**Customization table — python:**

| Category | File to patch | Generic pattern to find | Example replacement |
|---|---|---|---|
| Test framework | `{stack}/testing-supplement.md` | `pytest is the default` | If unittest found instead: `unittest.TestCase is the standard in this repo. Do not introduce pytest without team approval.` |
| Mocking | `{stack}/testing-supplement.md` | `Use respx for mocking HTTPX clients, vcrpy for recorded HTTP interactions.` | Narrow to detected library only. |
| Database testing | `{stack}/testing-supplement.md` | `testcontainers-python with a Postgres container` | If the repo uses a different approach (e.g., `pytest-django --reuse-db`), narrow to that. |

**Procedure:**

1. For each category in the active stack's table above, check whether the scan detected exactly one tool.
2. If yes — read the target reference file, find the generic pattern, and replace it with the project-specific version using `Edit`.
3. If the pattern isn't found (file was already customized or has different wording) — skip silently, do not force the replacement.
4. After all substitutions, add a comment at the top of each modified reference file:
   ```markdown
   <!-- Customized by setup-bootstrap on [date]. Detected: [list of substituted values]. -->
   ```
   This makes it obvious which files were patched and allows `setup-update` to re-customize if the reference template changes upstream.

**Rule:** Only narrow when the evidence is unambiguous (single tool, zero alternatives detected). Never remove sections about tools the project doesn't use YET — only remove sections about tools from a different category (e.g., remove TanStack Query guidance from a project with no React). The goal is to prevent shared references from contradicting the repo-specific `.claude/rules/` files while keeping useful guidance for future adoption.

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

### Analyzer Configuration (opt-in)

After distributing references, ask the engineer whether to configure recommended analyzers for the detected stack. This sets up Roslyn analyzers (.NET), ruff/mypy (Python), or biome/tsc-strict (TypeScript) so that build output feeds into the review pipeline with `source: "analyzer"` and `confidence: 100`.

1. Read `.claude/references/{stack}/analyzer-config.md` for the recommended packages and config
2. Ask: "Would you like to set up recommended analyzers for {stack}? This adds [packages] to your build and surfaces semantic findings in the review pipeline. (y/n)"
3. If yes: generate the appropriate config (`Directory.Build.props` additions for .NET, `pyproject.toml [tool.ruff]` for Python, `biome.json` for TypeScript)
4. If no: skip — the regex linter and AI review still work without analyzers
5. Add `.mtk/` to `.gitignore` (ephemeral analyzer output cache)

### Companion Plugin: dotnet-claude-kit (.NET only)

If the detected stack is `dotnet`, check whether the `codewithmukesh/dotnet-claude-kit` plugin is installed:

```bash
# Check if dotnet-claude-kit is available
find ~/.claude/plugins -maxdepth 4 -name "plugin.json" -path "*dotnet-claude-kit*" 2>/dev/null | head -1
```

If NOT found, recommend installation:

> **Recommended companion:** `codewithmukesh/dotnet-claude-kit` provides 15 Roslyn-powered MCP tools for real semantic analysis — anti-pattern detection, circular dependency detection, dead code finder, project graph, type hierarchy, and more. MTK orchestrates the workflow; dotnet-claude-kit provides .NET code intelligence. Install it via the Claude Code plugin marketplace.
>
> With dotnet-claude-kit installed, the review pipeline gains:
> - `DetectAntiPatterns` findings feed into the review as `source: "analyzer"`, confidence 100
> - `GetProjectGraph` and `GetDependencyGraph` enable scoped builds on large solutions
> - `FindDeadCode` and `DetectCircularDependencies` catch issues no AI review can reliably find
>
> MTK works without it — the regex linter, build output parser, and AI review still function. dotnet-claude-kit adds the Roslyn layer.

If found, note it in the bootstrap output: "dotnet-claude-kit detected — Roslyn MCP tools available for the review pipeline."

### Recommended Tooling (recommend-only, all stacks)

After the stack-specific Companion Plugin block, print a consolidated list of recommended MCP servers, plugins, and editor integrations that noticeably boost Claude Code productivity on this stack. **Never auto-install** — these are pointers with copy-pasteable commands. The engineer decides what to install.

**Procedure:**

1. Read the shared reference: `.claude/references/recommended-tooling.md` (editor-level integrations, cross-stack MCPs like `context7`, `playwright`, `github`, Claude for Chrome, `claude-mem`).
2. Read the stack-specific reference for the detected stack: `.claude/references/{stack}/recommended-tooling.md`.
3. Print both — do not summarize aggressively; the install commands and the "why it matters" column are the value. Keep the user in one place.
4. Output format (paste content under these two headers):
   ```
   ━━━ Recommended Tooling — Stack-agnostic ━━━
   [contents of .claude/references/recommended-tooling.md]

   ━━━ Recommended Tooling — {stack} ━━━
   [contents of .claude/references/{stack}/recommended-tooling.md]
   ```
5. Close the block with: `Install manually when you're ready — MTK works without any of these.`

**Do not:**
- Run `claude mcp add`, `/plugin install`, or any installer on the engineer's behalf.
- Ask per-tool install questions. This is a batch recommendation, not a wizard.
- Suppress the list because "some tools are already installed" — printing it again is cheap and surfaces new recommendations when MTK updates the reference files.

**Skip this block when:**
- The reference files are missing (warn once, continue).
- The engineer passed `--non-interactive` AND a follow-up `--quiet-recommendations` flag (not yet defined — for now, always print).

### Version Stamp

Write the MTK version stamp so `setup-update` can track which version this repo was bootstrapped with:

```bash
echo '{"version":"VERSION","installed":"DATE","source":"https://github.com/moberghr/claude-helpers"}' > .claude/mtk-version.json
```

Replace VERSION with the manifest version and DATE with today's date. This file is committed (not gitignored) so the team can track MTK versions across repos.

### Cross-Agent Compatibility

After generating CLAUDE.md and rules, generate portable configs for all AI coding tools:

1. Run `bash scripts/generate-agents-md.sh` (if the script exists in the plugin directory)
2. This creates an `AGENTS.md` at the repo root that Codex and other AGENTS.md-aware tools can read
3. The file contains coding guidelines, security requirements, testing expectations, and architecture principles — extracted from the references already distributed
4. Custom sections (prefixed `## Custom:`) are preserved across regeneration
5. If `AGENTS.md` already exists and has no `## Custom:` sections, the file is regenerated from current references
6. Run `bash scripts/generate-tool-configs.sh --all` (if the script exists) to generate native configs for other tools:
   - `.cursor/rules/mtk-*.mdc` — glob-scoped Cursor rules (applyTo globs from manifest)
   - `.github/copilot-instructions.md` — GitHub Copilot instructions
   - `.windsurfrules` — Windsurf rules
   - `GEMINI.md` — Gemini CLI guidelines
   - `.clinerules` — Cline/Roo rules

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
  ✓ Git pre-commit hook: [installed | ⚠️ existing hook found, skipped]
  ✓ Tool prerequisites: [all found | ⚠️ N missing — see details above]
  [if monorepo:]
  ✓ Monorepo detected — [N] packages found
      ✓ Generated per-package CLAUDE.md for: [list of packages]
      [⚠️ Skipped (already exists): list of packages]

Codebase findings:
  [stack-specific summary based on scan]

Skills available:
  /mtk <feature>         — Full feature loop
  /mtk fix <description> — Quick fix (1-3 files)
  /mtk review before commit — Fast security-focused review of staged changes
  /mtk-setup --audit     — Re-run architecture audit

Next: Try it with:
  /mtk Add [your feature description here]
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
- The `.claude/tech-stack` file is critical — every skill reads it. Make sure it's written before reporting completion.
