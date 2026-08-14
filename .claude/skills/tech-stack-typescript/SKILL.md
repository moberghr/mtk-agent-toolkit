---
name: tech-stack-typescript
description: Provides TypeScript/JavaScript build/test commands, ORM guidance, framework patterns (React, React Native/Expo, Next.js, Tauri, Node), and reference paths for workflow skills.
license: MIT
compatibility:
  - claude-code
  - codex
trigger: tech-stack-context
skip_when: never-skip-when-active-stack
type: tech-stack
user-invocable: false
---

# Tech Stack: TypeScript

## Overview

This tech stack skill provides TypeScript/JavaScript-specific context for the generic workflow skills (`spec-driven-development`, `incremental-implementation`, `test-driven-development`) and for review agents. It is loaded when `.claude/tech-stack` contains `typescript`.

Covers React SPAs, React Native / Expo mobile apps, Next.js apps, Tauri desktop apps (with Rust sidecar guidance), and Node.js backends. JavaScript-only projects use the same skill — the TypeScript-specific rules become optional recommendations rather than hard requirements.

## When To Use

Loaded automatically by commands and skills when the active tech stack is `typescript`. Not invoked directly.

## Build & Test Commands

All commands assume a package manager is detected during `setup-bootstrap` and written to `.claude/tech-stack-pm` (one of: `bun`, `pnpm`, `yarn`, `npm`). Commands below use `<pm>` as placeholder — substitute the detected value.

**Package manager auto-detection (priority order):**

| Lockfile | Package manager |
|---|---|
| `bun.lock` or `bun.lockb` | `bun` |
| `pnpm-lock.yaml` | `pnpm` |
| `yarn.lock` | `yarn` |
| `package-lock.json` | `npm` |
| (none, `package.json` only) | `npm` (fallback) |

Detection command:
```bash
if [ -f bun.lock ] || [ -f bun.lockb ]; then echo bun
elif [ -f pnpm-lock.yaml ]; then echo pnpm
elif [ -f yarn.lock ]; then echo yarn
else echo npm
fi
```

**Commands:**

- **Install:** `<pm> install` (bun: `bun install`, pnpm: `pnpm install`, etc.)
- **Type check (compile-equivalent):** `<pm> run typecheck` if defined in `package.json`, else `npx tsc --noEmit` (or `tsc -b` for project references)
- **Build:** `<pm> run build` (verifies full toolchain — bundler, type check, assets)
- **Test (batch):** `<pm> test <path/to/file>` or `<pm> run test -- <pattern>` (vitest/jest support filter flags; check `package.json` scripts)
- **Test (full):** `<pm> test` or `<pm> run test`
- **Format:** `<pm> run format` if defined, else `npx prettier --write <path>` or `npx biome format --write <path>` based on project config. Wired through `hooks/format-on-edit.sh`, which **queues** edited paths at PostToolUse and **formats** them at Stop, dispatching biome → prettier by extension — both halves must be wired or nothing is formatted. Do NOT use `$CLAUDE_FILE` — it is not a Claude Code env var.
- **Lint:** `<pm> run lint` if defined, else `npx eslint <path>` or `npx biome check <path>` based on project config

**Tauri addendum (when `src-tauri/` exists):**
- **Rust build:** `cd src-tauri && cargo check` (fast) or `cargo build` (full)
- **Rust test:** `cd src-tauri && cargo test`
- **Rust format:** `cd src-tauri && cargo fmt`
- **Rust lint:** `cd src-tauri && cargo clippy -- -D warnings`
- **Full app dev:** `<pm> run tauri dev`
- **Full app build:** `<pm> run tauri build`

## File Extensions & Markers

How `setup-bootstrap` detects this stack in a repository:

| Marker | Confidence |
|---|---|
| `package.json` | High |
| `tsconfig.json` | High (TypeScript-specific) |
| `bun.lock`, `pnpm-lock.yaml`, `yarn.lock`, `package-lock.json` | Medium (package manager signal) |
| `src-tauri/Cargo.toml` | Tauri sidecar |
| `next.config.{js,ts,mjs}` | Next.js project |
| `vite.config.{js,ts}` | Vite-based (React, Vue, Svelte) |
| `react-native` / `expo` in `package.json` deps | React Native / Expo project |
| `app.json`, `app.config.{js,ts}` | Expo config |
| `metro.config.{js,ts}` | React Native (Metro bundler) |

Detection command:
```bash
find . -maxdepth 2 -name "package.json" -not -path "*/node_modules/*" 2>/dev/null | head -1
test -f tsconfig.json && echo "typescript"
test -f src-tauri/Cargo.toml && echo "has-tauri-sidecar"
grep -qE '"(react-native|expo)"' package.json 2>/dev/null && echo "has-react-native"
ls app.json app.config.js app.config.ts metro.config.js metro.config.ts 2>/dev/null
```

## ORM & Data Layer Guidance

The TypeScript ecosystem has no single dominant ORM the way EF Core dominates .NET. Pick patterns based on what the project uses:

**Prisma (when detected):**

- Use `select` to project — avoid `include` for read-heavy queries unless you need the full relation.
- Put transaction logic in `prisma.$transaction([...])` (array form for independent ops) or `prisma.$transaction(async (tx) => {...})` (callback form for sequential).
- Keep `@@index` annotations accurate — review migrations for missing indexes on foreign keys.
- Use `prisma migrate dev` for local iteration, `prisma migrate deploy` in CI/prod.
- Run `prisma generate` after schema changes — missing step causes stale types.
- Don't expose `PrismaClient` to React components; keep it server-side (Next.js: server actions / API routes only).

**Drizzle (when detected):**

- Prefer schema-first style (`pgTable`, `sqliteTable`) with exported type inference (`typeof users.$inferSelect`).
- Use prepared statements (`db.select().from(...).prepare()`) for hot queries.
- Transactions via `db.transaction(async (tx) => {...})` — nested transactions use savepoints automatically.
- Migrations via `drizzle-kit generate:pg` / `drizzle-kit push:pg` — don't edit generated SQL by hand without reviewing.

**TanStack Query (React Query — client-side data layer):**

- Set explicit `staleTime` per query — don't rely on the default of 0 (immediately stale).
- Use `queryKey` arrays consistently: `['resource', id, filters]`. Cache invalidation depends on matching keys.
- `invalidateQueries` on mutation success, not after — avoid optimistic-update races.
- Server state (TanStack Query) ≠ client state (useState / Zustand / Jotai). Don't duplicate them.

**Test provider rules:**

- SQLite works for schema tests but **does not validate Postgres-specific behavior** (JSONB, arrays, `ILIKE`, partial indexes, advisory locks).
- Use `testcontainers` (npm package) or a dedicated ephemeral Postgres for integration tests that depend on PG semantics.
- For Prisma: `prisma migrate deploy` + a throwaway database per test suite works well.

**Reference:** `.claude/references/typescript/data-layer-checklist.md`

## Framework Patterns

**React (when detected):**

- Follow the Rules of Hooks — no hooks inside conditionals, loops, or after early returns.
- Prefer composition over prop drilling; use context sparingly (state libraries scale better).
- Memoization (`useMemo`, `useCallback`, `React.memo`) is a tool for measured problems, not a default. Profile first.
- Co-locate: component, its CSS module/styles, its test, and its sub-components in one directory.
- Client-only logic (browser APIs, localStorage) must be inside `useEffect` or guarded by `typeof window !== 'undefined'` — breaks SSR otherwise.

**React Native / Expo (when `react-native`/`expo` in deps):**

- No DOM or web APIs — use RN primitives (`View`, `Text`, `Image`, `Pressable`), not `<div>`/`window`/`document`/`localStorage`. Confirm libraries support RN before adding them.
- Persistence is async: `@react-native-async-storage/async-storage` for general data, `expo-secure-store` for tokens/secrets (never store secrets in AsyncStorage — it's unencrypted).
- Navigation via React Navigation (`@react-navigation/*`) or Expo Router (file-based under `app/`); pick one per app and type route params.
- Platform divergence is explicit: `Platform.OS` / `Platform.select(...)` for small branches, `*.ios.tsx` / `*.android.tsx` / `*.native.tsx` files for larger splits (Metro resolves them).
- Prefer Expo SDK modules (`expo-camera`, `expo-location`, `expo-notifications`, `expo-file-system`) over hand-rolled native modules. Know whether the project is managed or bare/dev-build before adding native deps (modules with native code need `expo prebuild` / EAS, not Expo Go).
- Long lists use `FlatList`/`SectionList` with a stable `keyExtractor` — never `.map()` inside a `ScrollView`.

**Next.js (when detected):**

- App Router (Next 13+): default components are Server Components. Add `'use client'` only at the boundary where browser APIs / hooks are actually needed.
- Server Actions: validate input with Zod or similar — they're public endpoints even if they feel like function calls.
- `next/image` and `next/font` over raw `<img>` / CSS imports — they're there for CLS and performance reasons.
- Route handlers (`app/api/.../route.ts`) for REST endpoints. Avoid mixing them with server actions on the same operation.

**Tauri (when `src-tauri/` exists):**

- The `#[tauri::command]` boundary is the trust boundary. Validate all inputs on the Rust side — the frontend is not trusted.
- Declare every command explicitly in `tauri.conf.json` allowlist. Don't enable `all: true` on any allowlist category.
- Use `tauri::AppHandle` for window / event operations, not raw pointers.
- Keep sensitive operations (file system, shell, HTTP with arbitrary URLs) inside Rust; expose narrow commands, not raw capabilities.

**Node backends (Express / Fastify / Hono / NestJS):**

- Validate request shape with Zod / Valibot / TypeBox at the boundary. No raw `req.body` access in handlers.
- Use a middleware chain for cross-cutting concerns (auth, logging, rate limit) — not one mega-handler.
- Return structured errors (`{ error: { code, message } }`) consistently across endpoints.
- Async handlers must await their I/O — unhandled promise rejections crash the process in Node ≥15.

**Reference:** `.claude/references/typescript/framework-patterns.md`

## Test Level Guidance

- **Unit tests:** pure functions, hooks (via `@testing-library/react-hooks` or `renderHook`), validators, reducers. Vitest is preferred for new projects; Jest for existing.
- **Component tests:** React Testing Library — query by role and accessible name, not by test-id or class name. No shallow rendering.
- **Integration tests:** API routes, server actions, database-backed operations. Mock at network boundary with MSW (`msw`), not at internal module boundary.
- **End-to-end tests:** Playwright. Preferred over Cypress for new work — better parallelism, better trace viewer, built-in TypeScript.
- Match existing project conventions on test file placement: `*.test.ts` co-located with source, or `tests/` directory — don't mix styles.
- For TanStack Query: wrap components in a fresh `QueryClientProvider` per test to avoid cache pollution.
- **React Native:** component tests use `@testing-library/react-native` (not the DOM `@testing-library/react`) — query by accessible role/label/text, render with its `render`/`screen`. Jest with `jest-expo` (Expo) or `react-native` preset is the norm; Playwright/Cypress don't apply. End-to-end on device/simulator uses Detox or Maestro, not browser E2E.

## Coding Style Reference

Path: `.claude/references/typescript/coding-guidelines.md`

Source: To be authored when the team starts its first TypeScript project. The placeholder file lists the structure to follow. Biome defaults + strict `tsconfig.json` are a reasonable starting point.

Key conventions to start with (until guidelines are written):
- `tsconfig.json` with `"strict": true`, `"noUncheckedIndexedAccess": true`, `"exactOptionalPropertyTypes": true`
- Prefer `type` over `interface` for data shapes; use `interface` only when declaration-merging is wanted
- `const` by default; `let` when rebinding; never `var`
- Explicit return types on exported functions (helps refactoring, keeps types stable across module edits)
- No `any` without a review comment explaining why; prefer `unknown` at boundaries
- `import type` for type-only imports (tree-shakeable, no runtime cost)
- File naming: `kebab-case.ts` for modules, `PascalCase.tsx` for React components
- No default exports for modules with multiple symbols (named exports refactor better)
- ESM (`import`/`export`) only — avoid CommonJS in new code

## Analyzer Configuration

See `.claude/references/typescript/analyzer-config.md` for recommended tsconfig strict settings and biome rules.

Type check with analyzer capture:
```bash
npx tsc --noEmit 2>&1 | hooks/parse-build-diagnostics.sh --format tsc > .mtk/analyzer-output.json
```

## Recommended Tooling

See `docs/recommended-tooling/typescript.md` for MCP servers, plugins, and editor integrations that noticeably improve Claude Code productivity on TypeScript projects — notably `context7` (current framework docs), `playwright` MCP (browser automation for UI verification), and editor-integrated TypeScript / Biome language servers. Paired with the stack-agnostic `docs/recommended-tooling/shared.md`. `setup-bootstrap` prints both during onboarding; install is manual.

## Reference Files

These files are loaded by commands and review agents when the active stack is `typescript`:

- `.claude/references/typescript/coding-guidelines.md` — TypeScript style guide (placeholder until written)
- `.claude/references/typescript/data-layer-checklist.md` — Prisma / Drizzle / TanStack Query review checklist
- `.claude/references/typescript/framework-patterns.md` — React / React Native (Expo) / Next.js / Tauri / Node backend patterns
- `.claude/references/typescript/testing-supplement.md` — Vitest / Jest / Playwright / MSW patterns
- `.claude/references/typescript/performance-supplement.md` — Bundle size, rendering, caching, Node I/O
- `.claude/references/typescript/analyzer-config.md` — Recommended tsconfig strict settings and biome rules
- `docs/recommended-tooling/typescript.md` — Recommended MCPs / plugins / editor integrations for TypeScript

## Settings Additions

Merge these into the project's `.claude/settings.json` during `setup-bootstrap`:

### allowedTools (merge: union)
- `Bash(bun:*)`
- `Bash(pnpm:*)`
- `Bash(yarn:*)`
- `Bash(npm:*)`
- `Bash(npx:*)`
- `Bash(node:*)`
- `Bash(tsc:*)`
- `Bash(cargo:*)` — only if `src-tauri/` exists

### deny (merge: union)
- `Read(**/.env.production)`
- `Read(**/.env.local)`
- `Bash(*publish*)` — npm publish requires explicit approval

### hooks.PostToolUse (merge: append)
- matcher: `Edit|Write`
- command: `bash $CLAUDE_PLUGIN_ROOT/hooks/format-on-edit.sh`

### hooks.Stop (merge: append)
- command: `bash $CLAUDE_PLUGIN_ROOT/hooks/format-on-edit.sh --flush`

### hooks.SubagentStop (merge: append)
- command: `bash $CLAUDE_PLUGIN_ROOT/hooks/format-on-edit.sh --flush`

Both halves are required. PostToolUse only **queues** the edited path; `--flush` at Stop is what actually formats. Wiring PostToolUse alone formats nothing; wiring a formatter to mutate at PostToolUse instead rewrites a file Claude has already read, and its next Edit fails with "File has been modified since read".

The matcher field accepts a regex on **tool name** only — `Write(*.ts)` is NOT valid Claude Code syntax and will silently never fire. File-extension dispatch happens inside `format-on-edit.sh`, which parses `tool_input.file_path` from stdin JSON.

## Format Command

```bash
# Wired via PostToolUse (queue) + Stop (flush) hooks — see Settings Additions above:
bash $CLAUDE_PLUGIN_ROOT/hooks/format-on-edit.sh
bash $CLAUDE_PLUGIN_ROOT/hooks/format-on-edit.sh --flush
# Manual invocation (for the human-readable CLAUDE.md, drop the wrapper):
npx biome format --write <file>   # or
npx prettier --write <file>
```

At flush the wrapper dispatches biome → prettier per edited file (deduped, with files deleted during the turn dropped).

The wrapper picks biome → prettier based on what's installed and dispatches by extension (`.ts/.tsx/.js/.jsx/.mjs/.cjs`). Failures log to stderr (visible in Claude Code's hook log) but never block the edit.

## Pre-Commit Review Items

Conditional, tool-keyed items for the generated `pre-commit-review-list.md`.
`setup-bootstrap` selects items whose trigger tool was detected in the scan,
adds the three stack-agnostic always-include items, and caps the list at 10.

- [React] Rules of Hooks, SSR-safe browser access, stable list keys
- [React Native / Expo] no DOM/web APIs, secrets in `expo-secure-store` not AsyncStorage, `FlatList` over `.map()` in `ScrollView`
- [Next.js] `'use client'` at the boundary, server actions validated, `next/image` / `next/font` over raw tags
- [Tauri] allowlist discipline, every `#[tauri::command]` validates input, no `all: true`
- [Prisma / Drizzle] `select` projection over `include`, indexes on foreign keys, paginated list queries
- [TanStack Query] explicit `staleTime`, stable `queryKey`, no server-state duplication in `useState`

## Scan Recipes

These bash commands are used by `setup-audit.md` when auditing a TypeScript repository.

### Dependency Registry Verification

Before planning the install of any npm package not already in `package.json` — especially one recommended by an AI assistant, blog post, or research brief — verify it exists and is the real package (criterion 0 of `.claude/references/dependency-intake-checklist.md`):

```bash
npm view <pkg> name version time.modified
```

A package not found, or one whose name closely resembles a popular package with different scope (typosquat signal), is an immediate block. `planning-and-task-breakdown` tags an unverified AI-recommended package `[ASSUMED]` and inserts a `checkpoint:human-verify` step before any install.

### Project Structure
```bash
# Package metadata
find . -maxdepth 2 -name "package.json" -not -path "*/node_modules/*" 2>/dev/null | head -5
find . -maxdepth 2 -name "tsconfig*.json" -not -path "*/node_modules/*" 2>/dev/null
# Package manager signal
ls bun.lock bun.lockb pnpm-lock.yaml yarn.lock package-lock.json 2>/dev/null
# Tauri sidecar
test -f src-tauri/Cargo.toml && echo "Tauri sidecar detected"
# Monorepo signals
find . -maxdepth 2 \( -name "pnpm-workspace.yaml" -o -name "turbo.json" -o -name "nx.json" -o -name "lerna.json" \) 2>/dev/null
# Top-level dependencies summary
grep -hE '"(dependencies|devDependencies|peerDependencies)"' package.json 2>/dev/null | head -5
# Folder structure (excluding heavy dirs)
find . -type d -maxdepth 3 -not -path "*/node_modules/*" -not -path "*/.next/*" -not -path "*/dist/*" -not -path "*/build/*" -not -path "*/.git/*" | sort
```

### Patterns In Use
```bash
# Web framework
grep -l "next" package.json 2>/dev/null && echo "Next.js"
grep -l "\"react\"" package.json 2>/dev/null && echo "React"
grep -l "vite" package.json 2>/dev/null && echo "Vite"
grep -lE "\"(react-native|expo)\"" package.json 2>/dev/null && echo "React Native / Expo"
grep -l "@tauri-apps" package.json 2>/dev/null && echo "Tauri"
grep -l "express\|fastify\|hono\|@nestjs" package.json 2>/dev/null && echo "Node backend detected"
# State management
grep -rlE "from ['\"](zustand|jotai|valtio|mobx|redux)['\"]" --include="*.ts" --include="*.tsx" 2>/dev/null | head -5
# Server state
grep -rlE "from ['\"](\\@tanstack/react-query|swr|@trpc)" --include="*.ts" --include="*.tsx" 2>/dev/null | head -5
# Validation
grep -rlE "from ['\"](zod|valibot|yup|io-ts|@sinclair/typebox)" --include="*.ts" --include="*.tsx" 2>/dev/null | head -5
```

### Data Layer
```bash
# ORM / query builder
find . -name "schema.prisma" -not -path "*/node_modules/*" 2>/dev/null | head -5
grep -rlE "from ['\"](drizzle-orm|@prisma/client|typeorm|mikro-orm|kysely)" --include="*.ts" 2>/dev/null | head -5
# Migrations
find . -path "*/migrations/*" -not -path "*/node_modules/*" \( -name "*.sql" -o -name "*.ts" \) 2>/dev/null | head -10
find . \( -name "drizzle.config.ts" -o -name "drizzle.config.js" \) 2>/dev/null
# Connection strings / env config
grep -rnE "DATABASE_URL|PGUSER|POSTGRES_|DB_HOST" --include="*.ts" --include="*.env*" 2>/dev/null | head -5
# N+1 risks (eager/lazy loading patterns)
grep -rnE "\.findMany\\(|\.findFirst\\(|\\binclude:|\\bselect:" --include="*.ts" 2>/dev/null | head -10
```

### Infrastructure
```bash
# Cloud SDKs
grep -rlE "from ['\"]@aws-sdk/|from ['\"]firebase|from ['\"]@google-cloud/" --include="*.ts" 2>/dev/null | head -10
# Docker
find . -maxdepth 3 \( -name "Dockerfile" -o -name "docker-compose*" -o -name ".dockerignore" \) 2>/dev/null
# Serverless
find . -maxdepth 2 \( -name "serverless.yml" -o -name "serverless.ts" -o -name "cdk.json" \) 2>/dev/null
# Vercel / Netlify / Cloudflare
find . -maxdepth 2 \( -name "vercel.json" -o -name "netlify.toml" -o -name "wrangler.toml" \) 2>/dev/null
# Tauri config
find . -name "tauri.conf.json" -not -path "*/node_modules/*" 2>/dev/null
```

### Naming Conventions
```bash
# Sample route / page / component files
find . -type f \( -name "route.ts" -o -name "page.tsx" -o -name "layout.tsx" \) -not -path "*/node_modules/*" | head -10
find . -type f -name "*.tsx" -not -path "*/node_modules/*" -not -path "*/.next/*" | head -10
# API route handlers
find . -path "*/api/*" -name "*.ts" -not -path "*/node_modules/*" | head -10
# Check component naming (PascalCase)
find . -name "*.tsx" -not -path "*/node_modules/*" -not -path "*/.next/*" | sed 's|.*/||' | head -20
```

### Testing Patterns
```bash
# Test framework
grep -lE "\"vitest\"|\"jest\"|\"@playwright/test\"|\"cypress\"" package.json 2>/dev/null
# Config files
find . -maxdepth 2 \( -name "vitest.config.*" -o -name "jest.config.*" -o -name "playwright.config.*" \) 2>/dev/null
# Test file locations
find . -type f \( -name "*.test.ts" -o -name "*.test.tsx" -o -name "*.spec.ts" -o -name "*.spec.tsx" \) -not -path "*/node_modules/*" | head -10
# MSW / mocking
grep -rlE "from ['\"](msw|nock|@testing-library)" --include="*.ts" --include="*.tsx" 2>/dev/null | head -10
```

### Configuration
```bash
# tsconfig chain
find . -maxdepth 3 -name "tsconfig*.json" -not -path "*/node_modules/*" 2>/dev/null
grep -h '"strict"\|"target"\|"module"' tsconfig*.json 2>/dev/null | head -10
# Formatter / linter config
find . -maxdepth 2 \( -name "biome.json" -o -name ".prettierrc*" -o -name ".eslintrc*" -o -name "eslint.config.*" \) 2>/dev/null
# Environment files
find . -maxdepth 2 -name ".env*" -not -name ".env.example" 2>/dev/null | head -10
# Build tool config
find . -maxdepth 2 \( -name "vite.config.*" -o -name "next.config.*" -o -name "tsup.config.*" -o -name "rollup.config.*" \) 2>/dev/null
# React Native / Expo config
find . -maxdepth 2 \( -name "app.json" -o -name "app.config.js" -o -name "app.config.ts" -o -name "metro.config.js" -o -name "metro.config.ts" -o -name "eas.json" \) 2>/dev/null
```

## Verification

- [ ] Tech stack skill is loaded when `.claude/tech-stack` contains `typescript`
- [ ] Package manager auto-detection populates `.claude/tech-stack-pm` correctly (bun / pnpm / yarn / npm)
- [ ] Build, type check, and test commands execute correctly for the target project
- [ ] Reference files exist at the paths listed in `## Reference Files`
- [ ] Scan recipes produce meaningful output for a TypeScript repository
- [ ] Tauri sidecar guidance is loaded when `src-tauri/Cargo.toml` is present
