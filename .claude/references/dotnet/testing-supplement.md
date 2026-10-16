---
description: .NET testing supplement — frameworks to match, EF Core test providers, Testcontainers
globs: ["**/*Tests.cs", "**/*.Tests/**/*.cs"]
alwaysApply: false
tools: [xunit, nunit, mstest, testcontainers, verify]
---
# .NET Testing Supplement

> **Precedence:** project rules in `.claude/rules/testing.md` override this file. If `testing.md` says "xUnit only", that wins over the framework list below.

## Frameworks

- xUnit, NUnit, or MSTest — match the project's existing choice.
- Mocking: Moq, NSubstitute, or FakeItEasy — match existing.
- Integration test base: `WebApplicationFactory<T>` for ASP.NET Core, `IClassFixture` for shared setup.

## EF Core Test Providers

- Do not rely on `UseInMemoryDatabase` for behavior that depends on relational semantics (arrays, JSONB, timestamps, transactions, raw SQL). It also cannot catch the untranslatable post-projection `OrderBy`/`Where` (see `tech-stack-dotnet` `## ORM & Data Layer Guidance`).
- Use SQLite or the project-standard integration infrastructure when query translation matters, and `Testcontainers` when Postgres- or SQL Server-specific behavior must be proved.
- Integration tests for money, ledger and audit paths run on the production database engine (`domain-finance.md`).
