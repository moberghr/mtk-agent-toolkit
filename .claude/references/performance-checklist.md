# Performance Checklist

Quick performance review prompts for .NET services.

## Data Access

- Use `AsNoTracking()` on read-only EF Core queries.
- Prefer projections over loading full entities for DTO responses.
- Avoid N+1 query patterns and database calls inside loops.
- Add pagination to list endpoints that can grow.

## Async And Cancellation

- Propagate `CancellationToken` through async calls.
- Use async database APIs for I/O-bound work.

## Memory And Network

- Avoid loading unbounded result sets into memory.
- Reuse `HttpClient` through `IHttpClientFactory`.
- Keep expensive remote calls outside tight loops when possible.

## Review Questions

- Does this change create a scaling bottleneck under realistic load?
- Is there avoidable extra data fetching?
- Are there missing cancellation or pagination protections?
