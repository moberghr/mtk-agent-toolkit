# Performance Checklist

Shared, language-agnostic performance rules. For stack-specific rules, see the active tech stack skill's reference files (e.g., `.claude/references/dotnet/performance-supplement.md`).

## Data Access

- Avoid N+1 query patterns and database calls inside loops.
- Add pagination to list endpoints that can grow unbounded.
- Fetch only the data you need — avoid loading full objects when projections will do.
- Keep filtering in the database, not after materialization.

## Async And Cancellation

- Use async I/O for database, HTTP, and file operations.
- Propagate cancellation tokens / abort signals through async chains.
- Do not block async code with synchronous waits.

## Memory And Network

- Avoid loading unbounded result sets into memory.
- Reuse HTTP connection pools rather than creating new clients per request.
- Keep expensive remote calls outside tight loops when possible.

## Review Questions

- Does this change create a scaling bottleneck under realistic load?
- Is there avoidable extra data fetching?
- Are there missing cancellation or pagination protections?
- Is the connection/resource management correct under concurrent load?
