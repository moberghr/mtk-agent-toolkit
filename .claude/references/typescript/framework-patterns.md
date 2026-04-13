# TypeScript Framework Patterns

Shared conventions for React, Next.js, Tauri, and Node backend codebases. Match project conventions first; this file captures defaults when conventions are absent.

## React

- **Rules of Hooks are non-negotiable.** No hooks in conditionals, loops, or after early returns. The lint rule (`react-hooks/rules-of-hooks`) exists because violating them causes subtle state corruption.
- **Composition over prop drilling.** If you're passing a prop through 3+ layers just to reach a leaf, consider context, a state library (Zustand, Jotai), or component composition.
- **Memoization is a tool, not a default.** `useMemo`, `useCallback`, `React.memo` add complexity. Apply only after profiling shows a measurable problem.
- **Co-locate by feature.** A component's styles, tests, and sub-components belong in the same directory, not in parallel `styles/` / `tests/` trees.
- **SSR-safe browser access.** `window`, `document`, `localStorage` access must be inside `useEffect` or guarded by `typeof window !== 'undefined'`. Direct access at module scope breaks SSR and static generation.
- **Keys on lists must be stable and unique.** Array indexes as keys cause rendering bugs on insertion/deletion.

## Next.js (App Router)

- **Server Components are the default.** Components are server-rendered unless they opt in with `'use client'` at the top.
- **Put `'use client'` at the boundary.** A client component can import server-only modules' *types* but not run them. Push the `'use client'` marker down as far as possible — don't make entire pages client just because a leaf needs interactivity.
- **Server Actions are public endpoints.** They look like function calls but are RPC over HTTP. Validate inputs with Zod (or similar) every single time, including user-identity checks.
- **Route handlers (`app/api/.../route.ts`)** for REST endpoints. Don't mix server actions and route handlers for the same operation — pick one pattern per feature.
- **Prefer `next/image`, `next/font`, `next/link`.** They exist for measurable reasons (CLS, LCP, prefetch). Using `<img>` or `<a>` bypasses those benefits.
- **Data fetching in Server Components** uses `fetch` with Next's extended caching options (`cache`, `next.revalidate`). Understand the cache semantics before relying on defaults.

## Next.js (Pages Router — legacy projects)

- `getServerSideProps` / `getStaticProps` for data fetching. Don't mix with client-side fetching for the same data.
- API routes in `pages/api/` return JSON. Use middleware for auth, not per-handler checks.
- Migrating to App Router: co-exist is possible but risky — plan the migration per route, not file-by-file.

## Tauri

- **The `#[tauri::command]` boundary is the trust boundary.** Validate every input on the Rust side. The frontend is not trusted, even in a desktop app — XSS in a webview becomes a native execution vulnerability.
- **Allowlist discipline.** Declare every command and every capability explicitly in `tauri.conf.json`. Never set `all: true` on allowlist categories — it's a privilege escalation waiting to happen.
- **Keep sensitive operations Rust-side.** File system access, shell execution, HTTP to arbitrary URLs: expose narrow commands (`read_user_config`, not `read_any_file`), not raw capabilities.
- **Use `tauri::AppHandle` for window / event operations.** Don't pass raw pointers or mutable globals between Rust and JS.
- **IPC is async.** Every `invoke()` returns a Promise. Handle errors explicitly — unhandled rejections from IPC surface as silent failures in the UI.
- **Updater signing.** If you enable the updater, sign releases. Unsigned updates are trivially tamperable by a MITM.

## Node Backends (Express / Fastify / Hono / NestJS)

- **Validate at the boundary.** Zod / Valibot / TypeBox on request body, query, and params. No raw `req.body` access in handler logic.
- **Middleware chain for cross-cutting concerns.** Auth, rate limit, request ID, logging — middleware. One mega-handler is not the answer.
- **Structured errors.** Consistent shape (`{ error: { code, message } }`) across endpoints. Clients shouldn't have to guess the error format per route.
- **Async handlers must await.** Unhandled promise rejections crash the Node process on 15+. Wrap handlers in an `asyncHandler` utility if the framework doesn't do it automatically (Express doesn't; Fastify does).
- **Timeouts on external I/O.** Every HTTP client, DB query, and queue call needs an explicit timeout. Default timeouts are rarely tuned for your SLO.
- **Don't leak internal errors.** Never return raw exception messages or stack traces to clients. Log them server-side, return a generic error with a correlation ID.

## Review Questions

- Is the framework's primary pattern used consistently (Server Components / App Router / middleware chain)?
- Is the trust boundary (server / client, Rust / JS) validated explicitly, not assumed?
- Are cross-cutting concerns in the right layer (middleware / provider / context) rather than duplicated?
- For Tauri: is the allowlist minimal? Are IPC commands scoped narrowly?
- For Next.js: is `'use client'` pushed as far down the tree as possible?
- For backends: are structured errors, timeouts, and input validation in place at every endpoint?
