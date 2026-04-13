# TypeScript Testing Supplement

Stack-specific testing guidance for TypeScript projects. Read alongside `.claude/references/testing-patterns.md`.

## Test Framework

- **Vitest** for new projects. Faster than Jest, better ESM support, same API for Jest migrations.
- **Jest** for existing projects — don't migrate unless the pain justifies it.
- **Playwright** for E2E and component tests with browser behavior. Preferred over Cypress for new work (better parallelism, better trace viewer, built-in TS).
- **@testing-library/react** for React component tests. Query by role and accessible name, not test-id or class name.

## File Placement

Match existing project convention:
- **Co-located:** `Button.tsx` + `Button.test.tsx` in the same folder. Easier to find, easier to delete.
- **Parallel tree:** `src/components/Button.tsx` + `tests/components/Button.test.tsx`. Easier to exclude from bundles.

Don't mix styles within the same project.

## Component Tests (React Testing Library)

- **Query by role, name, or label.** `getByRole('button', { name: /submit/i })` is resilient; `getByTestId` is brittle.
- **No shallow rendering.** Enzyme's `shallow` is a lie that hides bugs. Render the real tree.
- **Fire real events.** `userEvent` (from `@testing-library/user-event`) over `fireEvent` — simulates actual browser behavior (focus, hover, type delays).
- **Avoid implementation detail assertions.** Test "user sees submit button enabled after filling form", not "`handleSubmit` was called".

## Integration Tests

- **Mock at network boundary with MSW.** MSW (`msw`) intercepts `fetch` / `XHR` at the service-worker layer in browsers or the HTTP layer in Node. Don't mock internal modules.
- **One MSW server per test suite.** Set up handlers in `beforeAll`, reset in `afterEach`, close in `afterAll`.
- **Database-backed tests use real databases.** TestContainers or an ephemeral Postgres spun up per test run. SQLite in-memory is NOT Postgres.

## E2E Tests (Playwright)

- **Page Object Model for anything non-trivial.** Spreading selectors across test files is maintenance debt.
- **Trace on failure, video on retry.** Configure `trace: 'on-first-retry'`, `video: 'retain-on-failure'`.
- **Fixtures over `beforeEach` setup.** Playwright's fixture system is cleaner than hook-based setup for shared browser state.
- **Run headless in CI, headed locally** — `--headed` for debugging.

## TanStack Query in Tests

- **Fresh `QueryClient` per test.** Shared clients leak state. Pattern:
  ```typescript
  const createWrapper = () => {
    const client = new QueryClient({
      defaultOptions: { queries: { retry: false } }
    });
    return ({ children }) => <QueryClientProvider client={client}>{children}</QueryClientProvider>;
  };
  ```
- **Disable retries in tests.** `retry: false` — otherwise failed network mocks cause multi-second delays.
- **Use `waitFor` for async assertions.** Queries resolve asynchronously even with mocked responses.

## Async Tests

- **Always `await` async operations.** Dangling promises cause tests to pass when they should fail.
- **Use `findBy*` queries for async-appearing elements.** `getBy*` throws synchronously; `findBy*` waits.
- **Fake timers are a last resort.** `vi.useFakeTimers()` / `jest.useFakeTimers()` for time-sensitive code, but prefer waiting for real timers in most cases.

## Mocking

- **Module mocks at the boundary only.** Don't mock internal modules — refactor to inject the dependency instead.
- **`vi.mock` / `jest.mock` hoisting.** These are hoisted to the top of the file. `vi.mock` factories must not reference outer variables (use `vi.hoisted` if needed).
- **Spy, don't replace, when possible.** `vi.spyOn(obj, 'method')` preserves the original and is easier to assert against.

## Snapshot Tests

- **Use sparingly.** Snapshot tests catch unintended changes but also accept wrong changes (just press `-u`). Useful for small, stable outputs (serializer output, API response shapes).
- **Inline snapshots for small snippets.** `.toMatchInlineSnapshot()` keeps the expected value next to the test.

## Review Questions

- Does the test actually validate behavior, or just implementation details?
- Are mocks placed at boundaries (network, file system, time), not on internal logic?
- Is database-dependent behavior tested against the real database type?
- For React components: are queries resilient (role-based) or brittle (test-id / class)?
- For TanStack Query: is the `QueryClient` fresh per test?
- Are async assertions waited on properly (`findBy*`, `waitFor`, `await`)?
