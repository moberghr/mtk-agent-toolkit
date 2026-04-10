---
description: Bootstrap a repo for moberg-implement. Scans codebase, pulls coding guidelines and architecture principles, generates a project-specific CLAUDE.md. Run this once per repo.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
---

# Moberg Init — Bootstrap Repository for AI-Assisted Development

You are setting up a repository for the `/project:moberg-implement` workflow.
Your job is to scan this codebase and generate a tailored `CLAUDE.md` that the
implementation and review agents will use as their source of truth.

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
    description: "I'll place the file at .claude/references/architecture-principles.md and re-run moberg-init"
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

## STEP 3: Generate or Merge CLAUDE.md

### If CLAUDE.md does NOT exist → Generate from template

Create a new `CLAUDE.md` following the structure below.

### If CLAUDE.md ALREADY exists → Merge mode (default)

1. Read the existing CLAUDE.md
2. Compare each section against your scan findings
3. Identify:
   - **Stale content**: patterns described in CLAUDE.md that no longer exist in the codebase
   - **Missing content**: patterns found in the codebase not documented in CLAUDE.md
   - **Conflicts**: CLAUDE.md says one thing, codebase does another
4. Present a summary:
   ```
   CLAUDE.md Merge Analysis:
     ✓ [N] sections up to date
     ⚠️ [N] sections stale (need update)
     + [N] missing sections (need adding)

   Proposed changes:
     [list each change with before/after or addition]
   ```
5. Apply the changes (in merge mode, don't ask — the engineer chose init knowing it modifies CLAUDE.md)

### CLAUDE.md Structure

```markdown
# [Project Name] — Engineering Standards

> Auto-generated by moberg-init on [date]. Based on:
> - Moberg HR coding guidelines (`.claude/references/coding-guidelines.md`)
> - Architecture principles (`.claude/references/architecture-principles.md`) [or "not found"]
> - Codebase scan of this repository
>
> This is the single source of truth for both human engineers and AI agents.
> The `/project:moberg-implement` command reads this file.

---

## 1. Security & Compliance
[Generate based on: what you found in the codebase + fintech defaults]
[Include secrets management patterns actually used (Secrets Manager, user-secrets, env vars)]
[Number every rule: §1.1, §1.2, etc.]

## 2. Architecture Patterns
[Generate based on: architecture-principles.md + actual patterns found in codebase]
[If codebase uses EF Core, document DbContext, configurations, projections]
[If codebase uses Lambda, document handler patterns, DI, connection management]
[If codebase uses CDK, document infrastructure patterns]
[Number every rule: §2.1, §2.2, etc.]

## 3. Coding Style
[Pull directly from coding-guidelines.md]
[Organize into subsections matching the original doc]
[Add any project-specific conventions you discovered that aren't in the guidelines]
[Number every rule: §3.1, §3.2, etc.]

## 4. Testing Standards
[Generate based on: test patterns found + coding guidelines]
[Include specific frameworks, EF Core test providers, and patterns this project uses]
[Number every rule: §4.1, §4.2, etc.]

## 5. Data Layer
[Generate based on: actual data access patterns found]
[EF Core: configuration style, AsNoTracking, projections, DbContext lifetime]
[Raw SQL: parameterization, Data API usage]
[Connection management: Secrets Manager, connection pooling, Lambda considerations]
[Number every rule: §5.1, §5.2, etc.]

## 6. Performance Standards
[Generate based on: patterns found + sensible defaults for fintech]
[Number every rule: §6.1, §6.2, etc.]

## 7. Infrastructure
[Generate based on: CDK/IaC patterns, AWS services, Lambda, VPC, Docker]
[Only include if the project has infrastructure code]
[Number every rule: §7.1, §7.2, etc.]

## 8. Git & Workflow
[Pull from coding guidelines (branch naming) + what you see in commit history]
[Number every rule: §8.1, §8.2, etc.]

## 9. Project-Specific Patterns
[Anything unique to THIS repo that doesn't fit above]
[Handler patterns, domain concepts, shared utilities, etc.]
[Number every rule: §9.1, §9.2, etc.]
```

### Rules for Generation:
- Every rule must have a section number (§X.Y) for the review agent to reference
- Include **code examples** from the actual codebase where possible (as good examples)
- Include code examples from the coding guidelines (as the "bad" vs "good" patterns)
- Flag any conflicts between the coding guidelines and what the codebase actually does
  — present these as: "⚠️ Guideline says X, but codebase does Y. Standardize on: [your recommendation]"
- Be specific to THIS project — don't include generic rules that don't apply
- Keep it actionable — every rule should be something the review agent can check
- Don't add sections about technologies this project doesn't use (e.g., no MediatR section if there's no MediatR)

## STEP 4: Set Up Command Files & Working Directories

### Commands & Agents
Ensure the following files exist in `.claude/commands/`:
- `moberg-implement.md` — the main implementation loop command
- `moberg-update.md` — toolkit sync command
- `quick-check.md` — lightweight pre-commit security scan

Also ensure `.claude/agents/compliance-reviewer.md` exists.

If any are missing, tell the engineer to run `/project:moberg-update` to pull them
from the central claude-helpers repo. If that command is also missing, tell them to
copy the `.claude/` folder from the claude-helpers repo.

### Quick Check List

Generate `.claude/references/quick-check-list.md` based on what you found in the codebase scan.
This is the inline verification checklist that `moberg-implement` and `moberg-fix` read after
every batch of code. It should contain only checks relevant to THIS project.

If the file already exists, leave it alone — the engineer may have curated it.

If creating from scratch, include items based on what the codebase actually uses:

```markdown
# Quick Check List

> Project-specific inline verification. Read by moberg-implement and moberg-fix after each batch.
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
- **Max 10 items.** If you have more, pick the ones most likely to be violated. This list must be fast to scan.

### Tasks Directory
Create the `tasks/` directory if it doesn't exist:
```bash
mkdir -p tasks
```

Create `tasks/lessons.md` if it doesn't exist:
```markdown
# Lessons Learned

> This file captures patterns and mistakes discovered during AI-assisted development.
> It is read at the start of every `/project:moberg-implement` session.
> Commit this file — it is institutional memory for the team.

```

Add `tasks/todo.md` to `.gitignore` if not already there (it is ephemeral per-feature work):
```bash
echo "tasks/todo.md" >> .gitignore
```

Do NOT gitignore `tasks/lessons.md` — it should be committed and shared.

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
  ✓ CLAUDE.md — [generated from scratch | merged N changes into existing]
    [N] rules across [N] sections
  ✓ .claude/references/quick-check-list.md — [generated with N items | already exists, skipped]

Codebase findings:
  - Framework: .NET [version]
  - Data layer: [EF Core / Data API / Dapper / etc.]
  - Patterns: [MediatR/CQRS/Handler/etc.]
  - Test framework: [xUnit/NUnit/etc.] + [mocking framework]
  - Infrastructure: [Lambda/Docker/CDK/etc.]
  - Database: [PostgreSQL/SQL Server/none/etc.]
  - [N] conventions matched guidelines
  - [N] potential conflicts flagged (see ⚠️ markers in CLAUDE.md)

Commands available:
  /project:moberg-implement  — Full feature loop (plan → implement → verify → review → fix → cleanup → learn)
  /project:moberg-update     — Pull latest toolkit from central repo
  /project:quick-check       — Fast security scan

Working directories:
  ✓ tasks/lessons.md — [created | already exists with N entries]
  ✓ tasks/todo.md — [gitignored]

Next: Try it with:
  /project:moberg-implement Add [your feature description here]
```

## IMPORTANT
- Create the `.claude/references/` directory if it doesn't exist
- **Default to merge mode** when CLAUDE.md already exists — don't ask overwrite/merge/abort
- If CLAUDE.md doesn't exist, generate from scratch without asking
- The generated CLAUDE.md should be committed to the repo — it's documentation, not a secret
