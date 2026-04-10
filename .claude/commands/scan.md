---
description: Scan the current repository and generate an architecture principles document based on actual codebase patterns. Run in each repo you want to source. Outputs to .claude/references/architecture-principles.md
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
---

# Moberg Scan — Extract Architecture Principles from Codebase

You are a senior .NET architect performing an architectural audit of this repository.
Your job is to analyze the codebase and produce a comprehensive architecture principles
document that captures HOW this team builds software.

Do NOT invent rules. Document what the codebase ACTUALLY does. If you find inconsistencies,
note them as "⚠️ Inconsistency" — let the team decide which pattern to standardize on.

---

## STEP 1: Project Overview

```bash
# Solution and project structure
find . -name "*.sln" -not -path "*/bin/*" 2>/dev/null
find . -name "*.csproj" -not -path "*/bin/*" -not -path "*/obj/*" 2>/dev/null | sort

# Folder structure (top 3 levels)
find . -type d -maxdepth 3 -not -path "*/bin/*" -not -path "*/obj/*" -not -path "*/.git/*" -not -path "*/node_modules/*" | sort

# .NET version
grep -r "TargetFramework" --include="*.csproj" | head -10

# Key NuGet packages (reveals architectural choices)
grep -rh "PackageReference" --include="*.csproj" | sed 's/.*Include="//' | sed 's/".*//' | sort -u
```

Record: solution name, project count, .NET version, key packages.

## STEP 2: Layer Architecture

```bash
# Identify layer pattern
ls -d */ 2>/dev/null | head -20
find . -name "*.csproj" -not -path "*/bin/*" | xargs grep -l "ProjectReference" 2>/dev/null

# Check for common layer names
for layer in Api Application Domain Infrastructure Core Shared Common; do
  find . -type d -name "*${layer}*" -not -path "*/bin/*" -not -path "*/obj/*" 2>/dev/null
done
```

Then for each layer found, sample 2-3 files to understand responsibilities:
- What goes in each layer?
- What are the dependency directions?
- Are there cross-layer violations?

## STEP 3: Design Patterns

### CQRS / MediatR
```bash
grep -rl "IRequest\b\|IRequestHandler\|IMediator\|MediatR" --include="*.cs" | head -20
find . -path "*/Commands/*" -name "*.cs" -not -path "*/bin/*" | head -10
find . -path "*/Queries/*" -name "*.cs" -not -path "*/bin/*" | head -10
grep -rl "IRequestHandler" --include="*.cs" | head -3 | while read f; do echo "=== $f ==="; head -80 "$f"; done
```

### Repository Pattern
```bash
grep -rl "IRepository\|IGenericRepository\|Repository<" --include="*.cs" | head -10
grep -rl "DbContext\|DbSet" --include="*.cs" | head -10
```

### Domain Events
```bash
grep -rl "IDomainEvent\|DomainEvent\|INotification\b" --include="*.cs" | head -10
```

### Result Pattern
```bash
grep -rl "Result<\|Result\.Success\|Result\.Failure\|ErrorOr\|OneOf" --include="*.cs" | head -10
```

### Validation
```bash
grep -rl "AbstractValidator\|FluentValidation\|IRuleBuilder" --include="*.cs" | head -10
grep -rl "AbstractValidator" --include="*.cs" | head -1 | xargs head -40 2>/dev/null
```

### Mapping
```bash
grep -rl "IMapper\|AutoMapper\|CreateMap\|Mapster\|TypeAdapterConfig" --include="*.cs" | head -10
```

## STEP 4: API Patterns

```bash
# Controller / handler patterns
find . -name "*Controller*.cs" -not -path "*/bin/*" | head -10
find . -name "*Handler*.cs" -not -path "*/bin/*" -not -path "*Test*" | head -10

# Minimal API vs controllers
grep -rn "MapGet\|MapPost\|MapPut\|MapDelete" --include="*.cs" | head -10

# Route patterns
grep -rn "\[Http\|Route\|MapGet\|MapPost" --include="*.cs" | head -20

# Auth patterns
grep -rn "\[Authorize\|RequireAuthorization\|AddAuthentication\|AddAuthorization" --include="*.cs" | head -10

# Middleware
grep -rl "IMiddleware\|UseMiddleware\|app\.Use" --include="*.cs" | head -10

# API versioning
grep -rl "ApiVersion\|MapToApiVersion" --include="*.cs" | head -5

# Response envelope/wrapper
grep -rl "ApiResponse\|ResponseWrapper\|IActionResult\|ActionResult<" --include="*.cs" | head -10
```

## STEP 5: Data Layer (deep scan)

```bash
# DbContext
grep -rl "DbContext" --include="*.cs" | head -5
find . -name "*DbContext*.cs" -not -path "*/bin/*" | head -3 | while read f; do echo "=== $f ==="; head -60 "$f"; done

# Entity configuration style
find . -name "*Configuration*.cs" -not -path "*/bin/*" | head -10
grep -rl "IEntityTypeConfiguration\|modelBuilder" --include="*.cs" | head -5

# Fluent API vs Data Annotations
grep -rn "HasKey\|HasIndex\|ToTable\|HasColumnName" --include="*.cs" | head -5
grep -rn "\[Table\|\[Key\|\[Column\|\[Required" --include="*.cs" | head -5

# AsNoTracking usage
grep -rn "AsNoTracking" --include="*.cs" | head -10

# Select projections vs Include
grep -rc "\.Include(" --include="*.cs" | grep -v ":0" | head -5
grep -rc "\.Select(" --include="*.cs" | grep -v ":0" | head -5

# Raw SQL / Data API
grep -rl "FromSqlRaw\|ExecuteSqlRaw\|DataApiHelper\|Dapper\|SqlCommand" --include="*.cs" | head -5

# Connection string management
grep -rn "ConnectionString\|UseNpgsql\|UseSqlServer\|GetConnectionString" --include="*.cs" | head -5

# Entity patterns
find . -path "*/Entities/*" -name "*.cs" -not -path "*/bin/*" | head -5 | while read f; do echo "=== $f ==="; head -40 "$f"; done

# Timestamps, soft delete, audit columns
grep -rn "CreatedAt\|UpdatedAt\|IsDeleted\|DeletedAt\|ModifiedBy\|CreatedBy" --include="*.cs" | head -10

# Money/decimal handling
grep -rn "decimal\|Money\|Amount\|Currency" --include="*.cs" | head -10

# Migrations
find . -path "*/Migrations/*" -name "*.cs" | wc -l
find . -path "*/Migrations/*" -name "*.cs" | tail -3
```

## STEP 6: Testing Patterns

```bash
# Test projects and frameworks
find . -name "*Test*" -name "*.csproj" -not -path "*/bin/*"
grep -rh "PackageReference" --include="*.csproj" | grep -i "xunit\|nunit\|mstest\|moq\|nsubstitute\|fakeiteas\|bogus\|autofix\|fluentassert\|shouldly" | sort -u

# EF Core test providers
grep -rn "UseInMemoryDatabase\|UseSqlite\|TestContainers\|Testcontainers" --include="*.cs" | head -10

# Test organization
find . -path "*Tests*" -name "*.cs" -not -path "*/bin/*" -not -path "*/obj/*" | head -20

# Sample test naming and structure
find . -path "*Tests*" -name "*Test*.cs" -not -path "*/bin/*" | head -3 | while read f; do echo "=== $f ==="; head -60 "$f"; done

# Integration test base
grep -rl "WebApplicationFactory\|IClassFixture\|IntegrationTest" --include="*.cs" | head -5
```

## STEP 7: Infrastructure & Deployment

```bash
# Docker
find . -name "Dockerfile" -o -name "docker-compose*" -o -name ".dockerignore" 2>/dev/null

# CI/CD
find . -name "*.yml" -o -name "*.yaml" | grep -i "github\|pipeline\|ci\|cd\|workflow\|azure\|jenkins" 2>/dev/null

# AWS services
grep -rh "Amazon\.\|AWS\.\|AWSSDK" --include="*.csproj" | sort -u
grep -rl "SQS\|SNS\|S3\|Lambda\|DynamoDB\|SecretsManager\|ParameterStore" --include="*.cs" | head -10

# CDK / IaC
find . -name "*.csproj" -path "*cdk*" -o -name "*.csproj" -path "*Cdk*" | head -5
grep -rl "Amazon.CDK\|Constructs\|StackProps" --include="*.cs" | head -5
# If CDK found, sample the stack:
find . -name "*Stack*.cs" -path "*cdk*" -not -path "*/bin/*" | head -1 | xargs head -80 2>/dev/null

# Lambda patterns
grep -rl "ILambdaContext\|FunctionHandler\|LambdaSerializer" --include="*.cs" | head -5
grep -rl "DockerImageFunction\|Function_\|LambdaFunction" --include="*.cs" | head -5

# VPC / networking
grep -rn "Vpc\|SubnetType\|SecurityGroup\|NatGateway" --include="*.cs" | head -10

# Configuration/secrets
find . -name "appsettings*.json" -not -path "*/bin/*" | head -10
grep -rl "SecretsManager\|ParameterStore\|GetSecretValue\|SecretResolver" --include="*.cs" | head -10
grep -rl "IOptions\|IConfiguration\.\|builder\.Configuration" --include="*.cs" | head -10

# Health checks
grep -rl "MapHealthChecks\|AddHealthChecks\|IHealthCheck" --include="*.cs" | head -5

# Logging
grep -rl "ILogger\|Serilog\|NLog" --include="*.cs" | head -10
grep -rn "LogInformation\|LogWarning\|LogError" --include="*.cs" | head -5
```

## STEP 8: Cross-Cutting Concerns

```bash
# Exception handling
grep -rl "ExceptionHandler\|ExceptionMiddleware\|ProblemDetails\|GlobalException" --include="*.cs" | head -5

# Correlation IDs
grep -rl "CorrelationId\|RequestId\|TraceId" --include="*.cs" | head -5

# Caching
grep -rl "IDistributedCache\|IMemoryCache\|Redis\|ElastiCache" --include="*.cs" | head -5

# Background jobs
grep -rl "IHostedService\|BackgroundService\|Hangfire\|Quartz" --include="*.cs" | head -5

# Feature flags
grep -rl "FeatureFlag\|FeatureGate\|LaunchDarkly" --include="*.cs" | head -5

# DI registration patterns
grep -rn "AddSingleton\|AddScoped\|AddTransient\|AddDbContext\|AddHttpClient" --include="*.cs" | head -15
```

## STEP 9: Generate Architecture Principles Document

Based on EVERYTHING you found, create `.claude/references/architecture-principles.md`:

```markdown
# Architecture Principles — [Project Name]

> Auto-generated by scan on [date].
> Based on analysis of [N] .cs files across [N] projects.
> This document captures the ACTUAL architectural patterns in this codebase.

---

## 1. System Overview
- Project name and purpose (inferred from code and namespaces)
- .NET version: [found]
- Solution structure: [describe]
- Key dependencies: [list major NuGet packages and what they're used for]

## 2. Layer Architecture
- [Describe the actual layers found]
- [Dependency direction rules observed]
- [What belongs in each layer — with examples from the codebase]

## 3. Design Patterns in Use
### 3.1 [Pattern Name] (e.g., CQRS with MediatR)
- How it's implemented here
- File naming conventions
- Example from codebase

### 3.2 [Pattern Name] (e.g., Repository Pattern)
- [Same structure]

[Continue for each pattern found]

## 4. API Design
- Routing conventions (controllers vs minimal API)
- Authentication/authorization approach
- Response format/envelope pattern
- Error handling pattern
- Versioning approach (if any)

## 5. Data Layer
- ORM: [EF Core / Dapper / Data API / etc.]
- Configuration: [Fluent API / Data Annotations / inline]
- Read patterns: [AsNoTracking, Select projections, Include usage]
- Write patterns: [SaveChanges per handler, transactions]
- Connection management: [Secrets Manager, connection pooling, Lambda considerations]
- Entity conventions (base classes, timestamps, soft delete)
- Money/decimal handling
- Migration strategy

## 6. Testing Approach
- Test framework and tools
- EF Core test provider: [InMemory / SQLite / TestContainers]
- Test organization
- Naming conventions
- Integration test patterns

## 7. Infrastructure
- Hosting: [Lambda / ECS / App Service / etc.]
- IaC: [CDK / Terraform / ARM / none]
- AWS services used and their purpose
- VPC/networking architecture
- Container strategy (Docker images, base images)
- Configuration/secrets management
- Logging and observability

## 8. Cross-Cutting Concerns
- Exception handling strategy
- Correlation/tracing
- Caching approach
- Background processing
- DI lifetime conventions

## 9. Inter-Service Communication
- Sync: [REST/gRPC/etc.]
- Async: [SQS/SNS/events/etc.]
- Contracts and versioning approach

## 10. Inconsistencies Found
⚠️ [List any patterns that are inconsistent across the codebase]
⚠️ [Note: these are opportunities to standardize, not bugs]
```

### Rules for Generation:
- Document what IS, not what should be. This is a descriptive document.
- Include actual code paths as examples (e.g., "See `AIProxy/Handlers/SkillsHandler.cs`")
- Flag inconsistencies — where the same thing is done differently in different places
- If a pattern is only used in some places, note its adoption percentage
- Be specific about file locations so engineers can find examples
- Don't skip sections — if you found nothing for a section, say "Not found in this codebase"

## STEP 10: Present Results

```
✅ MOBERG SCAN COMPLETE

Repository: [name]
Scanned: [N] .cs files across [N] projects

Architecture profile:
  - .NET [version]
  - API style: [Minimal API / Controllers / mixed]
  - Data layer: [EF Core / Dapper / Data API / etc.]
  - Patterns: [list key patterns found]
  - Layers: [list layers]
  - Database: [PostgreSQL / SQL Server / none / etc.]
  - Hosting: [Lambda / ECS / etc.]
  - IaC: [CDK / Terraform / none]
  - Messaging: [SQS/SNS / RabbitMQ / none]
  - Testing: [xUnit/NUnit] + [Moq/NSubstitute] + [InMemory/SQLite/TestContainers]

Generated:
  ✓ .claude/references/architecture-principles.md

Inconsistencies found: [N]
  [list the top 3 if any]

Next steps:
  1. Review the generated document — edit anything that's wrong
  2. Decide how to resolve any inconsistencies flagged
  3. Run /moberg:init to generate the full CLAUDE.md
```

---

## IMPORTANT
- This command is READ-ONLY except for writing the output document
- Never modify source code during a scan
- If `.claude/references/architecture-principles.md` already exists, use AskUserQuestion before overwriting:
  ```
  question: ".claude/references/architecture-principles.md already exists. Overwrite with a fresh scan?"
  header: "Overwrite"
  options:
    - label: "Overwrite"
      description: "Replace the existing file with a new scan of the current codebase"
    - label: "Cancel"
      description: "Keep the existing file unchanged"
  ```
- Create `.claude/references/` directory if it doesn't exist
