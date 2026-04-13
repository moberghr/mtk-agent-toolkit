# Python Performance Supplement

Stack-specific performance rules for Python projects. Read alongside `.claude/references/performance-checklist.md`.

## Async And I/O

- Use `async def` for I/O-bound work when the framework supports it (FastAPI, asyncio).
- Don't mix sync and async carelessly: blocking calls (sync DB drivers, `requests`) inside an async handler block the event loop.
- Use `asyncio.gather` for concurrent independent I/O.
- For CPU-bound work, use `concurrent.futures.ProcessPoolExecutor` — threads don't help due to the GIL.

## Database

- Avoid N+1 patterns: SQLAlchemy `joinedload`/`selectinload`, Django `select_related`/`prefetch_related`.
- Use connection pooling (SQLAlchemy `pool_size`, Django `CONN_MAX_AGE`).
- For batch operations, use bulk APIs (`session.execute(insert(...).values([...]))`, `Model.objects.bulk_create([...])`).
- Add pagination to list endpoints — never return unbounded result sets.

## HTTP Clients

- Reuse `httpx.AsyncClient` or `requests.Session` instances. Don't create per-request.
- Set explicit timeouts on every external call.
- Use connection pooling and `keepalive` settings appropriate for the load profile.

## Memory

- Avoid loading large datasets into memory. Stream with generators or paginated queries.
- Be wary of `list(queryset)` — forces full evaluation. Iterate directly when possible.
- For Pandas / numpy work, prefer chunked reads (`pd.read_csv(..., chunksize=...)`).

## Lambda / Serverless

- Cold start matters: keep imports minimal at module top-level.
- Reuse connections across invocations (database pools, HTTP clients) via module-level globals when safe.
- Use Lambda Layers for heavy dependencies to reduce deploy size.

## Review Questions

- Does this change create a scaling bottleneck under realistic load?
- Are async/sync boundaries handled correctly?
- Is connection pooling configured appropriately?
- Are pagination and timeouts in place for unbounded operations?
