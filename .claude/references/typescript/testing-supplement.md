---
description: TypeScript testing supplement — runners to match, Testing Library, MSW (and its cookie trap), TanStack Query isolation
globs: ["**/*.test.ts", "**/*.spec.ts", "**/*.test.tsx"]
alwaysApply: false
tools: [vitest, jest, playwright, cypress, testing-library, msw]
---
# TypeScript Testing Supplement

> **Precedence:** project rules in `.claude/rules/testing.md` override this file.

## Test Framework

- **Vitest** for new projects; **Jest** where it is already entrenched. Do not migrate without a reason.
- **Playwright** for E2E and browser-behavior tests (over Cypress for new work).
- **@testing-library/react** for React component tests. Query by role and accessible name, not test-id or class; `userEvent` over `fireEvent`; no shallow rendering.
- Match the project's file placement (co-located or parallel `tests/` tree); never mix them.

## Network Mocking (MSW)

- Mock at the network boundary with MSW, not internal modules. One server per suite: handlers in `beforeAll`, reset in `afterEach`, close in `afterAll`.
- **Read cookies from the parsed argument, never the header.** In an MSW handler `request.headers.get('cookie')` is always `null`: `Cookie` is a forbidden header name, so an intercepted request need not expose it. Use the `cookies` argument:

  ```ts
  // Wrong: always null, so the flag is permanently false.
  http.get('/api/my/team', ({ request }) => {
    const demo = request.headers.get('cookie')?.includes('demo=1')
  })
  // Right: MSW parses cookies for you.
  http.get('/api/my/team', ({ cookies }) => {
    const demo = cookies.demo === '1'
  })
  ```

  It fails silently: the branch behind the flag is unreachable and its tests pass because they only exercise the other branch. When you find one instance, sweep the sibling handlers.

## TanStack Query in Tests

- A fresh `QueryClient` per test with `retry: false` (shared clients leak state; retries turn a failed mock into multi-second delays). Await with `findBy*` / `waitFor`.

## Database-backed Tests

- Real Postgres (Testcontainers or an ephemeral database), not SQLite, when the behavior depends on Postgres semantics.
