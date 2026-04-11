---
description: Bootstrap a repo for implement. Scans codebase, pulls coding guidelines and architecture principles, generates a project-specific CLAUDE.md. Run this once per repo.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
---

# Moberg Init — Bootstrap Repository for AI-Assisted Development

You are setting up a repository for the `/moberg:implement` workflow.
Your job is to scan this codebase and generate a tailored `CLAUDE.md` that the
implementation and review agents will use as their source of truth.

This bootstrap also prepares the repo for the shared skill layer and OpenCode routing.

## STEP 1: Pull External Standards

### Coding Guidelines
Fetch our coding guidelines from GitHub. Run:
```
curl -sL https://raw.githubusercontent.com/moberghr/coding-guidelines/main/CodingStyle.md -o .claude/references/coding-guidelines.md
```

If the fetch fails (network restrictions), check if `.claude/references/coding-guidelines.md`
already exists. If not, tell the engineer to manually place the file there.

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

Analyze the repository to understand how the team actually works. Collect:

### Project Structure
- Run `find . -name "*.csproj" -not -path "*/bin/*" -not -path "*/obj/*"` to find all projects
- Run `find . -name "*.sln"` to find solutions
- Map the project dependency graph from `.csproj` references
- Identify the layer structure (Api, Application, Domain, Infrastructure, Tests, Shared)

### Patterns in Use
- Check for MediatR: `grep -rl "IRequest\|IRequestHandler\|IMediator" --include="*.cs" | head -20`
- Check for CQRS: `find . -path "*/Commands/*" -o -path "*/Queries/*" | head -20`
- Check for Result pattern: `grep -rl "Result<\|Result\.Success\|Result\.Failure" --include="*.cs" | head -10`
- Check for domain events: `grep -rl "IDomainEvent\|DomainEvent\|INotification" --include="*.cs" | head -10`
- Check for FluentValidation: `grep -rl "AbstractValidator\|IRuleBuilder" --include="*.cs" | head -10`
- Check for AutoMapper or Mapster: `grep -rl "IMapper\|CreateMap\|TypeAdapterConfig" --include="*.cs" | head -10`
- Check for EF Core: `grep -rl "DbContext\|DbSet\|OnModelCreating" --include="*.cs" | head -10`

### Data Layer Patterns (deep scan)
- EF Core configuration style: `find . -name "*Configuration*.cs" -not -path "*/bin/*" | head -10`
- Fluent API vs data annotations: `grep -rl "IEntityTypeConfiguration\|modelBuilder\.\|HasKey\|HasIndex" --include="*.cs" | head -5`
- Raw SQL usage: `grep -rn "FromSqlRaw\|ExecuteSqlRaw\|SqlQuery" --include="*.cs" | head -5`
- AsNoTracking usage: `grep -rn "AsNoTracking" --include="*.cs" | head -5`
- Select projections vs Include: compare counts of `grep -rc "\.Include(" --include="*.cs" | grep -v ":0"` vs `grep -rc "\.Select(" --include="*.cs" | grep -v ":0"`
- Connection string patterns: `grep -rn "ConnectionString\|UseNpgsql\|UseSqlServer\|UseInMemory" --include="*.cs" | head -5`
- Data API / non-ORM access: `grep -rl "DataApiHelper\|IAmazonRDSDataService\|Dapper\|SqlCommand" --include="*.cs" | head -5`

### Infrastructure Patterns
- AWS services: `grep -rh "Amazon\.\|AWS\.\|AWSSDK" --include="*.cs" --include="*.csproj" | sort -u | head -20`
- CDK/IaC: `find . -name "*.csproj" -path "*cdk*" -o -name "*.csproj" -path "*Cdk*" | head -5`
- Lambda patterns: `grep -rl "ILambdaContext\|FunctionHandler\|LambdaSerializer" --include="*.cs" | head -5`
- VPC/networking: `grep -rn "Vpc\|SubnetType\|SecurityGroup\|NatGateway" --include="*.cs" | head -10`
- Docker: `find . -name "Dockerfile" -o -name "docker-compose*"`
- SQS/SNS/messaging: `grep -rl "IAmazonSQS\|IAmazonSNS\|SendMessageAsync\|SQSEvent" --include="*.cs" | head -5`
- Secrets Manager: `grep -rl "SecretsManager\|GetSecretValue\|SecretResolver" --include="*.cs" | head -5`

### Naming Conventions Actually Used
- Sample 5-10 handler/controller files: check route patterns, naming
- Sample 5-10 service files: check method naming, async patterns
- Sample 5-10 entity files: check property naming, field prefixes
- Check if `_camelCase` field convention is followed
- Check lambda parameter naming (x/y/z vs descriptive)

### Testing Patterns
- Find test projects: `find . -name "*Tests*" -type d | head -10`
- Check test framework: `grep -rl "xUnit\|NUnit\|MSTest\|\[Fact\]\|\[Test\]" --include="*.cs" | head -5`
- Check mocking framework: `grep -rl "Moq\|NSubstitute\|FakeItEasy" --include="*.cs" | head -5`
- Check for EF Core test patterns: `grep -rl "UseInMemoryDatabase\|UseSqlite\|InMemory" --include="*.cs" | head -5`
- Sample test naming patterns from existing tests
- Check for integration test base classes

### Database Patterns
- Check migration history: `find . -path "*/Migrations/*" -name "*.cs" | wc -l`
- Sample an entity to check: timestamps, soft delete, money types
- Check for audit trail tables/entities
- Check connection string patterns (Secrets Manager, env vars, etc.)

### Configuration & DI
- Check for `appsettings.json` patterns
- Check for IOptions usage
- Check for DI registration patterns (extension methods vs Program.cs inline)
- Check DI lifetimes: `grep -rn "AddSingleton\|AddScoped\|AddTransient\|AddDbContext" --include="*.cs" | head -10`

### Git Conventions
- Check recent commit messages: `git log --oneline -20`
- Check branch naming: `git branch -a | head -20`
- Check for PR templates: `find . -name "pull_request_template*"`

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
   - Extract each section (§1–§9) into the corresponding `.claude/rules/` file
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
> - Moberg HR coding guidelines (`.claude/references/coding-guidelines.md`)
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
| Update toolkit | `/moberg:update` | Pull latest commands/agents from central repo |

**Decision rule:** If unsure, start with `fix`. If the change grows beyond 3 files, switch to `implement`.

---

## Build & Test

[Generate based on scan: actual build/test commands for this project]
[e.g., `dotnet build`, `dotnet test`, specific solution files, test filters]

---

## Project Profile

- **Framework:** .NET [version]
- **Data layer:** [EF Core / Dapper / Data API / etc.]
- **Patterns:** [MediatR/CQRS, Result pattern, FluentValidation, etc.]
- **Hosting:** [Lambda / ECS / App Service / etc.]
- **Database:** [PostgreSQL / SQL Server / etc.]
- **Test stack:** [xUnit/NUnit + Moq/NSubstitute + InMemory/SQLite/TestContainers]

---

## Critical Rules (Always Apply)

These are the highest-impact rules — the ones most commonly violated or most
damaging when broken. Full detailed standards live in `.claude/rules/`.

[Generate the top 5-10 most critical rules from across all categories, based on
 what this project actually uses. Pick the rules that, if violated, cause the most
 damage. Number them §0.1–§0.N.]

Example:
- **§0.1** No hardcoded secrets, connection strings, or API keys
- **§0.2** `AsNoTracking()` on all read-only EF Core queries
- **§0.3** Every new public method must have test coverage
- **§0.4** Audit logs for financial state changes, in the same transaction
- **§0.5** No PII in logs, error messages, or exceptions

---

## Standards Reference

Detailed rules in `.claude/rules/` (auto-loaded by Claude Code):

| File | Covers | Rules |
|---|---|---|
| `security.md` | Auth, secrets, audit, PII | §1.x |
| `architecture.md` | Layers, slices, DI, patterns | §2.x |
| `coding-style.md` | Project-specific style overrides | §3.x |
| `testing.md` | Frameworks, coverage, naming | §4.x |
| `data-layer.md` | EF Core, queries, connections | §5.x |
| `performance.md` | Async, caching, HttpClient | §6.x |
| `infrastructure.md` | CDK, Lambda, Docker, AWS | §7.x |
| `git-workflow.md` | Branches, commits, PRs | §8.x |
| `project-specific.md` | Patterns unique to this repo | §9.x |

Full reference docs (read on-demand by commands and review agents):
- `.claude/references/coding-guidelines.md` — Moberg coding style guide
- `.claude/references/architecture-principles.md` — Architecture principles
- `.claude/references/security-checklist.md` — Security checklist
````

### .claude/rules/ File Templates

Generate each file below. **Only generate files for sections relevant to this project.**
Skip files for technologies the project doesn't use (no EF Core → skip `data-layer.md`,
no infrastructure code → skip `infrastructure.md`).

Each rules file target: **30–80 lines**. Be concise. If a section is larger, tighten the
wording or split into sub-files.

#### `.claude/rules/security.md` (always generate)
```markdown
# Security & Compliance (§1)

> Generated by init on [date]. Cite rules as §1.N in reviews.

[Generate based on: codebase findings + fintech defaults]
[Include: auth patterns found, secrets management approach, audit patterns, PII rules]
[Number every rule: §1.1, §1.2, etc.]
```

#### `.claude/rules/architecture.md` (always generate)
```markdown
# Architecture Patterns (§2)

> Generated by init on [date]. Cite rules as §2.N in reviews.

[Generate based on: architecture-principles.md + actual patterns found]
[Include: layer structure, dependency direction, handler/service splits, DI patterns]
[Number every rule: §2.1, §2.2, etc.]
```

#### `.claude/rules/coding-style.md` (generate only if project-specific overrides exist)
```markdown
# Coding Style — Project Overrides (§3)

> Generated by init on [date]. Cite rules as §3.N in reviews.
> Full coding guidelines: `.claude/references/coding-guidelines.md`
> This file contains ONLY project-specific additions or overrides.

[Generate based on: conventions found in THIS codebase that differ from or extend the guidelines]
[Do NOT duplicate content from coding-guidelines.md — reference it instead]
[If no project-specific overrides exist, skip this file entirely]
[Number every rule: §3.1, §3.2, etc.]
```

#### `.claude/rules/testing.md` (generate if tests exist)
```markdown
# Testing Standards (§4)

> Generated by init on [date]. Cite rules as §4.N in reviews.

[Generate based on: test patterns found + coding guidelines]
[Include: frameworks, naming conventions, EF Core test providers, integration test patterns]
[Number every rule: §4.1, §4.2, etc.]
```

#### `.claude/rules/data-layer.md` (generate if EF Core / data access found)
```markdown
# Data Layer (§5)

> Generated by init on [date]. Cite rules as §5.N in reviews.

[Generate based on: actual data access patterns found]
[Include: configuration style, AsNoTracking, projections, connections, entity conventions]
[Number every rule: §5.1, §5.2, etc.]
```

#### `.claude/rules/performance.md` (always generate)
```markdown
# Performance Standards (§6)

> Generated by init on [date]. Cite rules as §6.N in reviews.

[Generate based on: patterns found + sensible defaults for fintech]
[Number every rule: §6.1, §6.2, etc.]
```

#### `.claude/rules/infrastructure.md` (generate only if infra code found)
```markdown
# Infrastructure (§7)

> Generated by init on [date]. Cite rules as §7.N in reviews.

[Generate based on: CDK/IaC patterns, AWS services, Lambda, VPC, Docker]
[Number every rule: §7.1, §7.2, etc.]
```

#### `.claude/rules/git-workflow.md` (always generate)
```markdown
# Git & Workflow (§8)

> Generated by init on [date]. Cite rules as §8.N in reviews.

[Generate based on: coding guidelines + commit history + branch patterns]
[Number every rule: §8.1, §8.2, etc.]
```

#### `.claude/rules/project-specific.md` (generate if unique patterns found)
```markdown
# Project-Specific Patterns (§9)

> Generated by init on [date]. Cite rules as §9.N in reviews.

[Anything unique to THIS repo: handler patterns, domain concepts, shared utilities]
[Number every rule: §9.1, §9.2, etc.]
```

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

### Commands, Skills, Agents
Ensure the following files exist in `.claude/commands/`:
- `implement.md` — the main implementation loop command
- `update.md` — toolkit sync command
- `validate.md` — toolkit validation command
- `quick-check.md` — lightweight pre-commit security scan

Also ensure these exist:
- `.claude/skills/spec-driven-development-dotnet/SKILL.md`
- `.claude/skills/planning-and-task-breakdown/SKILL.md`
- `.claude/skills/incremental-implementation-dotnet/SKILL.md`
- `.claude/skills/debugging-and-error-recovery/SKILL.md`
- `.claude/skills/code-review-and-quality-fintech/SKILL.md`
- `.claude/agents/compliance-reviewer.md`
- `.claude/agents/test-reviewer.md`
- `.claude/agents/architecture-reviewer.md`
- `AGENTS.md`

If any are missing, tell the engineer to run `/moberg:update` to pull them
from the central claude-helpers repo. If that command is also missing, tell them to
copy the `.claude/` folder from the claude-helpers repo.

### Quick Check List

Generate `.claude/references/quick-check-list.md` based on what you found in the codebase scan.
This is the inline verification checklist that `implement` and `fix` read after
every batch of code. It should contain only checks relevant to THIS project.

If the file already exists, leave it alone — the engineer may have curated it.

If creating from scratch, include items based on what the codebase actually uses:

```markdown
# Quick Check List

> Project-specific inline verification. Read by implement and fix after each batch.
> Curate this list — add checks for patterns your team cares about, remove irrelevant ones.

- [ ] [item based on scan findings]
- [ ] [item based on scan findings]
...
```

**Selection rules:**
- If EF Core found: include `AsNoTracking` on reads, `Select()` over `Include()`, `CancellationToken` propagated
- If MediatR found: include one `SaveChanges` per handler, validate request
- If Lambda found: include DbContext disposal, cold start considerations
- If financial data found: include no PII in logs, audit trail on state changes
- Always include: `var` for locals, braces on all control flow, tests for new public methods
- **Max 10 items.** Pick the ones most likely to be violated. This list must be fast to scan.

### Tasks Directory
Create the `tasks/` directory if it doesn't exist:
```bash
mkdir -p tasks
```

Create `tasks/lessons.md` if it doesn't exist:
```markdown
# Lessons Learned

> This file captures patterns and mistakes discovered during AI-assisted development.
> It is read at the start of every `/moberg:implement` session.
> Commit this file — it is institutional memory for the team.

```

Add `tasks/todo.md` to `.gitignore` if not already there (it is ephemeral per-feature work):
```bash
echo "tasks/todo.md" >> .gitignore
```

Do NOT gitignore `tasks/lessons.md` — it should be committed and shared.

### Cross-Tool AGENTS.md

Generate a root-level `AGENTS.md` for cross-tool compatibility (Cursor, Copilot, Codex, Gemini CLI).
This file follows the open AGENTS.md standard (agents.md) and contains the subset of rules that
any AI coding tool needs — no Claude-specific features.

If `AGENTS.md` already exists, leave it alone — it may have been customized.

If creating from scratch, generate based on codebase scan findings:

```markdown
# AGENTS.md

> Cross-tool AI coding instructions. Works with Claude Code, Cursor, Copilot, Codex, and others.
> For Claude-specific rules: see CLAUDE.md and .claude/rules/.

## Build & Test

[Generate: actual build and test commands for this project]

## Code Style

[Generate: top 5-8 most critical coding conventions from coding-guidelines.md]
[Include only rules the AI is likely to violate — skip obvious ones]

## Architecture

[Generate: layer structure, dependency direction, handler/service splits]
[Keep to 3-5 bullet points]

## Testing

[Generate: test framework, naming conventions, what must be tested]

## Security

[Generate: top 3-5 security rules relevant to this project]

## Do Not

[Generate: 3-5 things the AI should never do in this codebase]
```

**Rules for generation:**
- Keep under 100 lines. This file loads into every AI tool on every request.
- Use plain markdown — no YAML frontmatter, no tool-specific syntax.
- Include only rules that are NOT obvious from the code itself.
- Focus on things the AI would get wrong without instruction.

## STEP 5: Verify & Report

Present a summary to the engineer:

```
✅ MOBERG INIT COMPLETE

Project: [name]
Standards sources:
  ✓ Coding guidelines: .claude/references/coding-guidelines.md
  ✓ Architecture principles: .claude/references/architecture-principles.md [or ⚠️ not found]
  ✓ Codebase scan: [N] .cs files across [N] projects

Generated/Updated:
  ✓ CLAUDE.md ([N] lines — under 200 ✓)
  ✓ .claude/rules/ — [N] rule files generated:
      [list each file with rule count, e.g., "security.md (§1.1–§1.6)"]
  ✓ .claude/references/quick-check-list.md — [generated with N items | already exists, skipped]

Codebase findings:
  - Framework: .NET [version]
  - Data layer: [EF Core / Data API / Dapper / etc.]
  - Patterns: [MediatR/CQRS/Handler/etc.]
  - Test framework: [xUnit/NUnit/etc.] + [mocking framework]
  - Infrastructure: [Lambda/Docker/CDK/etc.]
  - Database: [PostgreSQL/SQL Server/none/etc.]
  - [N] conventions matched guidelines
  - [N] potential conflicts flagged (see ⚠️ markers in rules files)

Commands available:
  /moberg:implement  — Full feature loop
  /moberg:fix        — Quick fix (1-3 files)
  /moberg:quick-check — Fast security scan
  /moberg:update     — Pull latest toolkit

Working directories:
  ✓ tasks/lessons.md — [created | already exists with N entries]
  ✓ tasks/todo.md — [gitignored]

Next: Try it with:
  /moberg:implement Add [your feature description here]
```

## IMPORTANT
- Create `.claude/references/` and `.claude/rules/` directories if they don't exist
- **Default to merge mode** when CLAUDE.md already exists — don't ask overwrite/merge/abort
- If existing CLAUDE.md is monolithic (>200 lines), migrate to lean structure automatically
- If CLAUDE.md doesn't exist, generate from scratch without asking
- The generated files should be committed to the repo — they're documentation, not secrets
- **Count CLAUDE.md lines before finishing.** If over 200, you must move content to rules files.
