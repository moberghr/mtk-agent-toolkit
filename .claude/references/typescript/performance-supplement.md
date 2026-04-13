# TypeScript Performance Supplement

Stack-specific performance rules for TypeScript projects. Read alongside `.claude/references/performance-checklist.md`.

## Bundle Size (Client)

- **Track it.** Every production build should report bundle size; regressions should fail CI or at least alert. `next build` reports per-route; `vite build --mode analyze` shows the breakdown.
- **Tree-shakeable imports only.** `import { specific } from 'lib'`, not `import * as lib`. Not all libraries are tree-shakeable — check the library's sideEffects field.
- **Dynamic imports for heavy, rarely-used code.** Charts, rich editors, admin panels: `const Chart = lazy(() => import('./Chart'))`.
- **Avoid moment.js.** Use `date-fns` (tree-shakes by function) or `dayjs` (2KB). Moment is ~70KB and not tree-shakeable.
- **Lodash: per-function imports.** `import debounce from 'lodash/debounce'`, not `import { debounce } from 'lodash'` — the latter pulls the whole library with some bundlers.

## Rendering (React)

- **Profile before memoizing.** `useMemo`/`useCallback` add overhead; most components don't need them. React DevTools Profiler shows real measurements.
- **Avoid inline object/array literals in props.** `<Child options={{ foo: 1 }} />` creates a new object every render — invalidates memo. Hoist to a constant or `useMemo`.
- **List virtualization for long lists.** `react-window` or `@tanstack/react-virtual` when rendering 100+ rows. Rendering 10,000 DOM nodes is never fast.
- **Images: `next/image` or equivalent.** Automatic sizing, lazy loading, modern formats — all things you shouldn't have to think about per-component.

## Server-Side Rendering / SSG

- **Measure TTFB, LCP, CLS separately.** Each has different fixes. Slow TTFB is a server problem; slow LCP is usually a network/image problem; CLS is a layout problem.
- **Static generation for anything that doesn't need per-request data.** SSG caches forever at the edge; SSR runs on every request.
- **Streaming and Suspense** in Next.js App Router: let fast content render while slow content streams in. Don't wait for the slowest data source.

## Data Fetching

- **Cache with intent.** Know the `staleTime` and `gcTime` for every TanStack Query. Unset defaults lead to refetch storms.
- **Deduplication.** Both TanStack Query and Next.js `fetch` dedupe identical requests in the same render pass — don't disable unless you know why.
- **Pagination always.** No unbounded list fetches in production. If the API doesn't paginate, paginate client-side after fetch or push back on the API.
- **Parallel fetches with `Promise.all` / `useQueries`.** Sequential awaits on independent data multiplies latency.

## Node Backend Performance

- **Async everywhere for I/O.** Never call sync I/O (`fs.readFileSync`, `execSync`) in request-handling paths — it blocks the event loop.
- **Connection pooling for databases.** Prisma defaults to 10 connections; tune for your deploy topology (fewer per instance in serverless, more per instance in long-running containers).
- **HTTP client reuse.** Create `fetch` agents / Undici `Pool` once, not per-request.
- **Timeouts everywhere.** Every external call gets an explicit timeout. Default Node `fetch` has no timeout until the OS kills the socket (minutes).
- **Compression at the edge, not in Node.** Cloudflare, Vercel, Cloudfront handle gzip/brotli better and without burning CPU cycles per request.

## Serverless / Edge

- **Cold start matters.** Keep imports at the top of the file minimal — lazy-load anything not needed for the happy path.
- **Module-level globals across invocations.** Database clients, HTTP clients: define once at module scope so the next invocation reuses them.
- **Edge runtime (Vercel Edge / Cloudflare Workers) is not Node.** No `fs`, no `child_process`, no native modules. Check library compatibility before deploying.
- **Response streaming** on edge runtimes: start sending bytes as soon as you have them. Latency wins come from overlapping work.

## Tauri Performance

- **IPC is expensive.** Each `invoke()` crosses the JS/Rust boundary with serialization. Batch calls; don't invoke in tight loops.
- **Bundle the frontend.** Dev mode loads from Vite; production bundles into the binary. Measure both — they have different perf profiles.
- **Native-side work for heavy operations.** File I/O, crypto, compression belong in Rust commands, not JS.

## Memory

- **Avoid loading large datasets into memory on the server.** Stream with Node Streams API or pagination.
- **Watch for event listener leaks.** Adding listeners without removing them (especially `window.addEventListener` in React without `return () => ...`) accumulates over time.
- **Worker threads for heavy CPU in Node.** Don't block the event loop — offload to a `Worker` or a separate process.

## Review Questions

- Does this change add to the client bundle? By how much?
- For React: is this component rendering more often than needed? Where's the wasted work?
- Is every external I/O call timed out and cached appropriately?
- For serverless: does this introduce cold-start sensitive imports at module scope?
- Is pagination in place for unbounded fetches, both client and server?
- For Tauri: is heavy work on the Rust side, or are we round-tripping through IPC?
