---
description: Grep patterns to catch stub implementations, placeholder code, mock data, and unwired components in code review
globs: ["**/*"]
alwaysApply: false
---

# Stub Detection

Reviewers should treat stubs, placeholders, and unwired components as **incomplete implementation**, not "almost done". This reference is a deterministic pattern catalog cited by `code-review-and-quality` and the per-stack reviewers.

## Why it matters

Stubs slip through review because they look syntactically correct. A function that returns `null` compiles. A React component that renders a div compiles. Tests that never assert anything pass. The reviewer's job is to surface them, not approve the diff because it builds.

## Pattern catalog

### Comment markers

```bash
grep -rEn 'TODO|FIXME|XXX|HACK|TEMP|PLACEHOLDER' --include='*.{ts,tsx,js,jsx,cs,py,go,rs,rb,java,kt,swift}' .
grep -rin 'coming soon\|not implemented\|to be implemented\|placeholder' .
```

A `TODO` added by THIS change is almost always a stub indicator. A `TODO` that already existed in the file is a separate (older) finding — flag both, but distinguish them.

### Empty function bodies

**TypeScript / JavaScript:**
```bash
grep -rEn 'function\s+\w+\([^)]*\)\s*\{\s*\}' .
grep -rEn 'const\s+\w+\s*=\s*\([^)]*\)\s*=>\s*\{\s*\}' .
grep -rEn 'async\s+\w+\([^)]*\)\s*\{\s*\}' .
```

**C# / .NET:**
```bash
grep -rEn 'public\s+\w[\w<>?]*\s+\w+\([^)]*\)\s*\{\s*\}' --include='*.cs' .
grep -rEn 'throw\s+new\s+NotImplementedException' --include='*.cs' .
```

**Python:**
```bash
grep -rEn '^\s*def\s+\w+\([^)]*\):\s*$' --include='*.py' .   # def with no body
grep -rEn 'raise\s+NotImplementedError' --include='*.py' .
grep -rEn '^\s*pass\s*$' --include='*.py' .                  # context-dependent
```

### Suspect return values

Returning literal empty / null where the contract clearly requires real data:

```bash
grep -rEn 'return\s+(null|undefined|None);' .
grep -rEn 'return\s+\{\s*\};?' .
grep -rEn 'return\s+\[\s*\];?' .
grep -rEn 'return\s+""\s*;?' .
grep -rEn 'return\s+0\s*;?' .  # only suspect when the function name implies nontrivial output
```

These are findings only when the surrounding contract / type signature implies the function should produce actual data. A `getItems(): Item[]` returning `[]` is a strong signal; an `onClose(): void` with `return` is not.

### Mock / placeholder data in production code

```bash
grep -rEn '\b(mockData|fakeUser|dummyUser|testValue|sampleData|placeholderText|loremIpsum|lorem ipsum)\b' .
grep -rEn 'console\.log\((.*stub|.*mock|.*placeholder)' --include='*.{ts,tsx,js,jsx}' .
```

### Empty React/JSX components

```bash
grep -rEn 'return\s*\(\s*<div\s*/>\s*\)' --include='*.{tsx,jsx}' .
grep -rEn 'return\s*\(\s*<>\s*</>\s*\)' --include='*.{tsx,jsx}' .
grep -rEn 'return\s+null;\s*\}' --include='*.{tsx,jsx}' .
```

### Unwired components — the silent class of stubs

The diff adds a handler / route / event subscriber, but does not register it where the system would actually call it. Hardest to catch by line-grep alone — verify by reading the registry file.

| Surface | Where to verify wiring |
|---|---|
| HTTP route / handler | router index, OpenAPI spec, route table |
| MediatR / CQRS handler (.NET) | DI registration, `IRequestHandler<>` discovery |
| Background job | scheduler / hangfire / quartz registry |
| React route | `react-router` route config |
| CLI subcommand | argument parser registration |
| Migration | migrations directory + sequence number |
| Feature flag check | flag service registration + UI surface |

If the diff adds a unit but no entry in the corresponding registry, raise `under_scoped_integrations` (severity proportional to user-visible impact).

## Severity guidance

- **Critical (Block)** — empty body or `NotImplementedException` on a public contract that the diff also exposes (handler, controller method, exported function the spec promises). Implementation is incomplete.
- **Critical (Block)** — `mockData`, `fakeUser`, etc. in code paths reachable from production routes.
- **High (Required Fix)** — TODO/FIXME added by this diff inside the change manifest.
- **Medium (Required Fix)** — empty React component or `return null` in a UI path the spec says ships.
- **Low (Advisory)** — pre-existing TODOs touched but not introduced by this diff. Note them; do not block.

## What NOT to flag

- `pass` in a Python `except` clause that intentionally swallows a documented error class (this is an error-handling concern — surface to `silent-failure-hunter` instead, not stub-detection).
- Empty implementations explicitly marked with a structured stub macro (`@abstractmethod`, interface declarations, `unimplemented!()` in trait skeletons) — these are placeholders by design.
- `return null` in functions whose return type explicitly permits null (`T | null`, `Option<T>`).
- Test fixtures that return mock data inside `tests/` directories.

## How reviewers use this

Cite findings against the pattern that triggered them. Example:

> **Critical** — `src/api/profile.ts:42` returns `[]` but `getProfile()` is the only path the spec lists for fetching profile data. Implementation appears stubbed (pattern: empty-array literal return on declared data path). Verify intent before approving.

This format is parseable by the structured-findings schema in `.claude/references/review-finding-schema.md`.
