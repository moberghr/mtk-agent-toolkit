# .NET Performance Supplement

Stack-specific performance rules for .NET projects. Read alongside `.claude/references/performance-checklist.md`.

## Data Access (EF Core)

- Use `AsNoTracking()` on read-only EF Core queries.
- Prefer `Select()` projections over loading full entities for DTO responses.
- Avoid N+1 query patterns and database calls inside loops.
- Add pagination to list endpoints that can grow.

## Async And Cancellation

- Propagate `CancellationToken` through async chains.
- Use async database APIs (`ToListAsync`, `FirstOrDefaultAsync`) for I/O-bound work.

## Memory And Network

- Avoid loading unbounded result sets into memory.
- Reuse `HttpClient` through `IHttpClientFactory`.
- Keep expensive remote calls outside tight loops when possible.

## Lambda / AWS-Specific

- DbContext disposal in Lambda — manage scope to avoid cold-start overhead.
- Cold start considerations: minimize startup work, avoid heavy DI registration in handlers.
- Reserved concurrency for predictable latency on critical paths.

## Review Questions

- Does this change create a scaling bottleneck under realistic load?
- Is there avoidable extra data fetching?
- Are there missing cancellation or pagination protections?
- Is HttpClient created without the factory?
