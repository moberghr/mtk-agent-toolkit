# TypeScript Data Layer Checklist

Project-level reminders for reviewing and writing data access code in TypeScript projects. Covers Prisma, Drizzle, and TanStack Query (client-side). The TypeScript ecosystem lacks a single dominant ORM — match whatever the project already uses.

## Prisma

- Use `select` to project specific fields. `include` pulls full relations — expensive for read-heavy endpoints.
- Transactions: array form (`prisma.$transaction([a, b, c])`) for independent ops, callback form (`prisma.$transaction(async (tx) => {...})`) for sequential dependent ops.
- Missing `@@index` on foreign keys is a common performance bug — review new migrations for it.
- Run `prisma generate` after every schema change. Stale generated types cause confusing errors.
- `PrismaClient` is server-only. Never import it into React components (Next.js: only in server actions, route handlers, or server components).
- In serverless environments, reuse `PrismaClient` across invocations (module-level singleton) or use the Data Proxy / connection pooling — don't instantiate per request.
- Log slow queries in production (`log: ['query']` with a threshold) — cheapest way to catch N+1s.

## Drizzle

- Schema-first: define once, infer types with `typeof table.$inferSelect` and `typeof table.$inferInsert`.
- Use `.prepare()` for hot-path queries — prepared statements cache the plan on the DB side.
- Transactions: `db.transaction(async (tx) => {...})`. Nested transactions become savepoints automatically.
- `drizzle-kit generate:pg` creates migrations from schema diff. Review the generated SQL before applying — especially for renames (drizzle can misinterpret them as drop+add).
- For read-heavy projections, use `.select({ id: users.id, name: users.name })` — don't pull columns you won't use.

## TanStack Query (Client-Side)

- Set explicit `staleTime` per query. Default is 0 (immediately stale) — almost never what you want.
- `queryKey` arrays must be stable and structured: `['resource', id, { filter }]`. Unstable keys (new object literal per render) cause refetch loops.
- `invalidateQueries` on mutation `onSuccess`, not optimistically — avoids races with the server response.
- Don't mirror server state into `useState`. TanStack Query is your cache; duplicating it creates sync bugs.
- `useQueries` for parallel fetches where you want all results; `useQuery` with `enabled: false` + manual `refetch` for conditional dependent fetches.

## Migrations (All ORMs)

- One migration per logical change. Don't bundle unrelated schema changes.
- Never edit applied migrations — write a new one. Editing applied migrations desyncs environments.
- Always test migration rollback before merging destructive changes (drops, type narrowings).
- Backfill strategies for `NOT NULL` columns on existing tables: add nullable → backfill → enforce NOT NULL as three separate migrations.

## Test Provider Rules

- SQLite in-memory works for schema-shape tests, NOT for tests that depend on Postgres semantics (JSONB, arrays, `ILIKE`, partial indexes, advisory locks, tsvector full-text search).
- For real integration tests, use `testcontainers` (npm package) with a Postgres container, or an ephemeral DB created by the test harness.
- Prisma: `prisma migrate deploy` against a throwaway database per test suite is the cleanest pattern.
- Drizzle: point at a test database URL via env var; reset schema between suites with `drizzle-kit push:pg`.

## Review Questions

- Is the query shaped to the response? (No `include` pulling unused relations, no `SELECT *` anti-pattern in Drizzle.)
- Are indexes present for every `WHERE` / `ORDER BY` / foreign key used in hot queries?
- Is pagination in place for list endpoints? Unbounded `findMany()` is a production timebomb.
- Are transactions scoped tightly? Long-running transactions cause lock contention.
- Does the test provider actually validate the behavior being tested, or is it masking a Postgres-specific bug?
- For client code: are server-state and client-state cleanly separated, or duplicated?
