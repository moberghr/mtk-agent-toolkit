# .NET Testing Supplement

> **Precedence:** This is a shared reference file. Project-specific overrides in `.claude/rules/testing.md` take precedence over guidance here. If `testing.md` says "xUnit only", that overrides the generic framework list below.

Stack-specific testing guidance for .NET projects. Read alongside `.claude/references/testing-patterns.md`.

## Test Selection

- Unit tests: pure logic, validators, mapping, branching rules.
- Integration tests: handlers, API endpoints, persistence, authorization, serialization, EF Core behavior.
- End-to-end tests: only when the project already uses them and the behavior crosses major boundaries.

## EF Core Test Providers

- Do not rely on `UseInMemoryDatabase` for behavior that depends on relational semantics (arrays, JSONB, timestamps, transactions, raw SQL).
- Prefer SQLite or project-standard integration infrastructure when query translation matters.
- Verify projections, filtering, pagination, and transaction behavior with realistic providers.
- Use `Testcontainers` when Postgres-specific or SQL Server-specific behavior must be tested.

## Frameworks

- xUnit, NUnit, or MSTest — match the project's existing choice.
- Mocking: Moq, NSubstitute, or FakeItEasy — match existing.
- Integration test base: `WebApplicationFactory<T>` for ASP.NET Core, `IClassFixture` for shared setup.

## Review Questions

- Does the chosen test provider actually validate the relational behavior in question?
- Is `UseInMemoryDatabase` masking provider-specific issues?
- Are integration tests using the same database engine as production?
