---
name: tech-stack-dotnet
description: Provides .NET-specific build commands, test commands, ORM guidance, framework patterns, and reference file paths for workflow skills.
license: MIT
compatibility:
  - claude-code
  - codex
trigger: tech-stack-context
skip_when: never-skip-when-active-stack
type: tech-stack
user-invocable: false
---

# Tech Stack: .NET

## Overview

This tech stack skill provides .NET/C#-specific context for the generic workflow skills (`spec-driven-development`, `incremental-implementation`, `test-driven-development`) and for review agents. It is loaded when `.claude/tech-stack` contains `dotnet`.

## When To Use

Loaded automatically by commands and skills when the active tech stack is `dotnet`. Not invoked directly.

## Build & Test Commands

- **Compile:** `dotnet build`
- **Test (batch):** `dotnet test` or `dotnet test --filter <project>`
- **Test (full):** `dotnet test`
- **Test (list-only):** enumerates discovered tests without executing them — the F7/command-verification list variant used to verify `dotnet test` is runnable without paying for a full suite run. Conditional on the solution format:
  - `.sln`: `dotnet test <sln> --list-tests`
  - `.slnx` (or `global.json` sets `"test": {"runner": "Microsoft.Testing.Platform"}`): `dotnet test --solution <slnx> --list-tests` — a bare `dotnet test <slnx> --list-tests` fails with `"Specifying a solution for 'dotnet test' should be via '--solution'"` under Microsoft.Testing.Platform.
- **Format:** `dotnet format --verbosity quiet` (project-wide). Edited-file formatting is wired via `hooks/format-on-edit.sh`, which **queues** paths at PostToolUse and **formats** them at Stop — both halves must be wired or nothing is formatted. `--include` takes paths relative to the workspace directory, so the flush pass groups files by their nearest `.csproj` and runs from that directory; an absolute `--include` silently matches nothing and still exits 0. Do NOT reference `$CLAUDE_FILE` — it is not a Claude Code env var; hook input arrives via stdin.

## File Extensions & Markers

How `setup-bootstrap` detects this stack in a repository:

| Marker | Confidence |
|---|---|
| `*.sln` or `*.slnx` | High |
| `*.csproj` | High |
| `global.json` | Medium |
| `Directory.Build.props` | Medium |

Detection command:
```bash
find . \( -name "*.sln" -o -name "*.slnx" -o -name "*.csproj" \) -not -path "*/bin/*" -not -path "*/obj/*" 2>/dev/null | head -5
```

## ORM & Data Layer Guidance

**EF Core rules (when EF Core is detected):**

- Add `AsNoTracking()` for read-only queries.
- Prefer `.Select()` projection to `Include()` for DTO reads.
- Keep filtering in the database, not after materialization.
- Use async query methods (`ToListAsync`, `FirstOrDefaultAsync`).
- Keep mutation logic explicit and easy to trace.
- Avoid multiple `SaveChanges` calls in one handler unless clearly justified.
- Keep transaction boundaries clear when audit data or multiple aggregates are involved.

**Test provider rules:**

- Do not default to `UseInMemoryDatabase` when relational behavior matters (arrays, JSONB, timestamps, transactions).
- Prefer SQLite or project-standard integration infrastructure when query translation matters.
- Verify projections, filtering, pagination, and transaction behavior with realistic providers.

**Reference:** `.claude/references/dotnet/ef-core-checklist.md`

## Framework Patterns

**MediatR/CQRS (when MediatR is detected):**

- Keep `Request`, `Response`, and `Handler` together when the project follows that pattern.
- Use `Command` and `Query` suffixes consistently.
- Match the folder layout used by neighboring slices.
- Handlers orchestrate application logic; they should not become dumping grounds for unrelated concerns.
- Validate requests using the project-standard approach.
- Keep side effects explicit.
- One `SaveChanges` per handler.

**Reference:** `.claude/references/dotnet/mediatr-slice-patterns.md`

## Test Level Guidance

- **Unit tests:** pure logic, validators, mapping, branching rules.
- **Integration tests:** handlers, API endpoints, persistence, authorization, serialization, EF Core behavior.
- **End-to-end tests:** only when the project already uses them and the behavior crosses major boundaries.
- Use the project-standard provider for EF-sensitive behavior. Do not default to `UseInMemoryDatabase` when relational behavior matters.
- Test assertions should be meaningful — not just "does not throw".
- Match existing project test naming and fixture patterns.

## Coding Style Reference

Path: `.claude/references/dotnet/coding-guidelines.md`

Source: `https://raw.githubusercontent.com/moberghr/coding-guidelines/main/CodingStyle.md`

Key conventions enforced by the coding guidelines (summary for reviewers):
- Lambda params: `x`, nested: `y`, `z`
- LINQ: chained methods on separate lines, multiple conditions as multiple `.Where()` calls
- `Select()` projections from DB, not `Include()`
- File-scoped namespaces, `var` for all locals, early return over `else`
- MediatR: one `SaveChanges` per handler, Handler+Request+Response in same file
- Braces on all control flow, even single-line

## Analyzer Configuration

See `.claude/references/dotnet/analyzer-config.md` for recommended Roslyn analyzer packages and `.editorconfig` rules. Key packages: `Microsoft.EntityFrameworkCore.Analyzers`, `Meziantou.Analyzer`, `Roslynator.Analyzers`.

Build with analyzer capture:
```bash
dotnet build 2>&1 | tee /dev/tty | hooks/parse-build-diagnostics.sh > .mtk/analyzer-output.json
```

## Companion Plugin: dotnet-claude-kit

If `codewithmukesh/dotnet-claude-kit` is installed, its 15 Roslyn MCP tools are available for deeper analysis. These tools load the actual MSBuild workspace and provide semantic code intelligence that MTK's file-based analysis cannot match.

**Key tools to use in MTK workflows:**
- `DetectAntiPatterns` — call during pre-commit or batch review for deterministic anti-pattern findings (AsyncVoid, BroadCatch, EfCoreNoTracking, HttpClientInstantiation, MissingCancellationToken, SyncOverAsync). Treat results as `source: "analyzer"`, `confidence: 100`.
- `GetProjectGraph` / `GetDependencyGraph` — call to scope builds to affected projects on large solutions. Feed results to `incremental-implementation` for targeted build/test commands.
- `FindDeadCode` / `DetectCircularDependencies` — call during architecture review for structural findings.
- `GetDiagnostics` — call for compiler and analyzer warnings on specific files, more targeted than full `dotnet build`.
- `GetTestCoverageMap` — call during test review to verify coverage claims.

**Graceful degradation:** If dotnet-claude-kit is not installed, all MTK skills fall back to build output parsing (`hooks/parse-build-diagnostics.sh`) and AI-based review. The workflow is the same; the deterministic layer is thinner.

## Recommended Tooling

See `docs/recommended-tooling/dotnet.md` for MCP servers, plugins, and editor integrations that noticeably improve Claude Code productivity on .NET projects — notably `csharp-lsp` (Roslyn semantic navigation), `dotnet-claude-kit` (Roslyn analyzer pack), and `microsoft-learn` (official Azure/.NET docs). Paired with the stack-agnostic `docs/recommended-tooling/shared.md`. `setup-bootstrap` prints both during onboarding; install is manual.

## Reference Files

These files are loaded by commands and review agents when the active stack is `dotnet`:

- `.claude/references/dotnet/coding-guidelines.md` — Moberg C# coding style guide
- `.claude/references/dotnet/ef-core-checklist.md` — EF Core review and implementation checklist
- `.claude/references/dotnet/mediatr-slice-patterns.md` — MediatR/CQRS slice conventions
- `.claude/references/dotnet/testing-supplement.md` — .NET-specific testing guidance (EF Core providers)
- `.claude/references/dotnet/performance-supplement.md` — .NET-specific performance rules
- `.claude/references/dotnet/analyzer-config.md` — Recommended Roslyn analyzer packages and `.editorconfig` rules
- `docs/recommended-tooling/dotnet.md` — Recommended MCPs / plugins / editor integrations for .NET

## Settings Additions

Merge these into the project's `.claude/settings.json` during `setup-bootstrap`:

### allowedTools (merge: union)
- `Bash(dotnet build:*)`
- `Bash(dotnet test:*)`
- `Bash(dotnet format:*)`

### deny (merge: union)
- `Read(**/appsettings.Production.json)`
- `Bash(dotnet publish:*)` — deny-only; publish is a deploy-adjacent action bootstrap should not pre-authorize. When a pattern appears in both `allowedTools` and `deny`, deny wins, so it is listed here only.

### hooks (do NOT add)

`format-on-edit.sh` is wired by the **plugin**, in MTK's own `hooks/hooks.json`
(PostToolUse `Edit|Write` to queue, Stop + SubagentStop `--flush` to format).
Bootstrap must NOT copy it into the target's `.claude/settings.json`.

`$CLAUDE_PLUGIN_ROOT` is only defined for hooks a plugin declares itself. Written
into a project settings file it expands to the empty string, so the command runs
as `bash /hooks/format-on-edit.sh` and fails on *every* edit — 4,552 such failures
were measured across 7 bootstrapped repos, with formatting never once running.

The project's opt-in signal is the `.claude/tech-stack` marker bootstrap already
writes; the hook checks it and no-ops in repos that never adopted MTK.
`MTK_FORMAT_ON_EDIT=0` opts a bootstrapped repo back out.

Both halves matter and the plugin wires both: PostToolUse only **queues** the
edited path, `--flush` at Stop is what formats. Queue-only formats nothing;
mutating at PostToolUse instead rewrites a file Claude has already read, and its
next Edit fails with "File has been modified since read". Matchers are regexes on
**tool name** only — `Write(*.cs)` is not valid syntax and silently never fires;
file-extension dispatch happens inside the hook.

## Format Command

```bash
# Wired by the plugin's own hooks.json (queue at PostToolUse, flush at Stop) —
# not by the project's settings.json. See '### hooks (do NOT add)' above.
# Manual invocation (project-wide):
dotnet format --verbosity quiet
```

At flush the wrapper groups the turn's edited `.cs` files by their nearest `.csproj` (falling back to `.sln`/`.slnx`) and runs one `dotnet format --include <relative paths> --verbosity quiet` per workspace, from that workspace directory. Both details matter: `--include` matches only paths relative to the invocation directory — given an absolute path it matches nothing and still exits 0 — and `dotnet format` loads the whole workspace before filtering, so one run per file is pathological. A `.cs` file with no `.csproj`/`.sln` above it is skipped rather than triggering a repo-wide format. Failures log to stderr but never block.

## Pre-Commit Review Items

Conditional, tool-keyed items for the generated `pre-commit-review-list.md`.
`setup-bootstrap` selects items whose trigger tool was detected in the scan,
adds the three stack-agnostic always-include items, and caps the list at 10.

- [EF Core] `AsNoTracking` on reads, `Select()` over `Include()`, `CancellationToken` propagated, `DbContext` scoped/disposed correctly
- [MediatR] one `SaveChanges` per handler, validate request
- [Lambda] cold-start considerations — lazy-init heavy clients/secrets, avoid blocking work at startup

## Scan Recipes

These bash commands are used by `setup-audit.md` when auditing a .NET repository.

### Dependency Registry Verification

Before planning the install of any NuGet package not already referenced — especially one recommended by an AI assistant, blog post, or research brief — verify it exists and is the real package (criterion 0 of `.claude/references/dependency-intake-checklist.md`):

```bash
dotnet package search <id> --exact-match --source https://api.nuget.org/v3/index.json
```

A package not found, or one whose name closely resembles a popular package with different scope (typosquat signal), is an immediate block. `planning-and-task-breakdown` tags an unverified AI-recommended package `[ASSUMED]` and inserts a `checkpoint:human-verify` step before any install.

### Project Structure
```bash
find . -name "*.csproj" -not -path "*/bin/*" -not -path "*/obj/*" 2>/dev/null | sort
find . -name "*.sln" -not -path "*/bin/*" 2>/dev/null
grep -r "TargetFramework" --include="*.csproj" | head -10
grep -rh "PackageReference" --include="*.csproj" | sed 's/.*Include="//' | sed 's/".*//' | sort -u
```

### Patterns In Use
```bash
# MediatR / CQRS
grep -rl "IRequest\|IRequestHandler\|IMediator" --include="*.cs" | head -20
find . \( -path "*/Commands/*" -o -path "*/Queries/*" \) | head -20
# Result pattern
grep -rl "Result<\|Result\.Success\|Result\.Failure" --include="*.cs" | head -10
# Domain events
grep -rl "IDomainEvent\|DomainEvent\|INotification" --include="*.cs" | head -10
# FluentValidation
grep -rl "AbstractValidator\|IRuleBuilder" --include="*.cs" | head -10
# AutoMapper / Mapster
grep -rl "IMapper\|CreateMap\|TypeAdapterConfig" --include="*.cs" | head -10
# EF Core
grep -rl "DbContext\|DbSet\|OnModelCreating" --include="*.cs" | head -10
```

### Data Layer
```bash
# EF Core configuration
find . -name "*Configuration*.cs" -not -path "*/bin/*" | head -10
grep -rl "IEntityTypeConfiguration\|modelBuilder\.\|HasKey\|HasIndex" --include="*.cs" | head -5
# Raw SQL
grep -rn "FromSqlRaw\|ExecuteSqlRaw\|SqlQuery" --include="*.cs" | head -5
# AsNoTracking usage
grep -rn "AsNoTracking" --include="*.cs" | head -5
# Select vs Include
grep -rc "\.Include(" --include="*.cs" | grep -v ":0" | head -5
grep -rc "\.Select(" --include="*.cs" | grep -v ":0" | head -5
# Connection strings
grep -rn "ConnectionString\|UseNpgsql\|UseSqlServer\|UseInMemory" --include="*.cs" | head -5
# Non-ORM data access
grep -rl "DataApiHelper\|IAmazonRDSDataService\|Dapper\|SqlCommand" --include="*.cs" | head -5
```

### Infrastructure
```bash
# AWS services
grep -rh "Amazon\.\|AWS\.\|AWSSDK" --include="*.cs" --include="*.csproj" | sort -u | head -20
# CDK/IaC
find . -name "*.csproj" \( -path "*cdk*" -o -path "*Cdk*" \) | head -5
# Lambda
grep -rl "ILambdaContext\|FunctionHandler\|LambdaSerializer" --include="*.cs" | head -5
# VPC/networking
grep -rn "Vpc\|SubnetType\|SecurityGroup\|NatGateway" --include="*.cs" | head -10
# Docker
find . \( -name "Dockerfile" -o -name "docker-compose*" \)
# SQS/SNS/messaging
grep -rl "IAmazonSQS\|IAmazonSNS\|SendMessageAsync\|SQSEvent" --include="*.cs" | head -5
# Secrets Manager
grep -rl "SecretsManager\|GetSecretValue\|SecretResolver" --include="*.cs" | head -5
```

### Naming Conventions
```bash
# Sample handler/controller files for route patterns and naming
find . -name "*Controller*.cs" -not -path "*/bin/*" | head -10
find . -name "*Handler*.cs" -not -path "*/bin/*" -not -path "*Test*" | head -10
# Check for common DI patterns
grep -rn "AddSingleton\|AddScoped\|AddTransient\|AddDbContext" --include="*.cs" | head -10
```

### Testing Patterns
```bash
find . -name "*Test*" -name "*.csproj" -not -path "*/bin/*"
grep -rh "PackageReference" --include="*.csproj" | grep -i "xunit\|nunit\|mstest\|moq\|nsubstitute\|bogus\|fluentassert" | sort -u
grep -rn "UseInMemoryDatabase\|UseSqlite\|TestContainers" --include="*.cs" | head -10
grep -rl "WebApplicationFactory\|IClassFixture\|IntegrationTest" --include="*.cs" | head -5
```

### Configuration
```bash
find . -name "appsettings*.json" -not -path "*/bin/*" | head -10
grep -rl "IOptions\|IConfiguration\.\|builder\.Configuration" --include="*.cs" | head -10
grep -rl "ILogger\|Serilog\|NLog" --include="*.cs" | head -10
```

## Verification

- [ ] Tech stack skill is loaded when `.claude/tech-stack` contains `dotnet`
- [ ] Build and test commands execute correctly for the target project
- [ ] Reference files exist at the paths listed in `## Reference Files`
- [ ] Scan recipes produce meaningful output for a .NET repository
