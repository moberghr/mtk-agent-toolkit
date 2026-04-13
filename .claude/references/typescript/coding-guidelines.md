# TypeScript Coding Guidelines — Placeholder

> **STATUS: To be authored when the team formalizes TypeScript conventions.**
>
> This file exists so the toolkit's TypeScript tech stack has a stable reference path.
> When the team agrees on conventions, replace this placeholder with real guidelines.

## Default Starting Point

Until this file is written, default to:

- **Strict `tsconfig.json`:** `"strict": true`, `"noUncheckedIndexedAccess": true`, `"exactOptionalPropertyTypes": true`, `"noImplicitOverride": true`
- **Biome** as the canonical formatter and linter (single tool, fast). Fall back to Prettier + ESLint if the project started there.
- **ESM** only — no CommonJS in new code.
- **PascalCase** for types, React components, classes. **camelCase** for variables, functions, methods. **SCREAMING_SNAKE** for constants.
- **kebab-case** for file names (modules). **PascalCase** for React component files (`UserCard.tsx`).

## Sections to Author Later

When this file gets written for real, structure it like the C# guidelines:

1. **Naming conventions** — files, modules, types, functions, React components, hooks, constants
2. **Layout conventions** — import order, line length, JSX formatting
3. **Type discipline** — when `any` is acceptable (basically never), `unknown` at boundaries, generic defaults, `import type` vs runtime imports
4. **React patterns** — hooks style, component composition, prop types, children patterns
5. **Async patterns** — `async`/`await` only, no raw `.then()` chains in new code, error boundaries
6. **Error handling** — exception strategy, Result-style alternatives, typed errors
7. **Module boundaries** — what gets a named export vs default, barrel files yes/no, circular import policy
8. **Framework-specific** — Next.js server/client boundary rules, Tauri IPC validation, Express middleware style
9. **Testing style** — Vitest vs Jest, file placement, MSW for network, test-data factories
10. **Common anti-patterns** — `useEffect` overuse, prop drilling vs context vs state library, over-memoization, `any` escape hatches

## How To Update

When authoring this file:
1. Reference real code from the first production TypeScript project
2. Decide between Biome and Prettier+ESLint (recommend Biome for new projects — faster, one tool, fewer configs)
3. Decide on test framework (Vitest for new, keep Jest where it's already entrenched)
4. Commit the decisions before scaling the project
5. Update `tech-stack-typescript/SKILL.md` to remove the "placeholder" warning from the Coding Style Reference section
