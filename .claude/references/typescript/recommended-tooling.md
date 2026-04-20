# Recommended Tooling — TypeScript

> Stack-specific MCP servers, plugins, and integrations that noticeably improve Claude Code productivity on TypeScript/JavaScript projects (React, Next.js, Tauri, Node). Pair with `.claude/references/recommended-tooling.md` (shared).
>
> MTK does not auto-install anything on this list.

## Strongly Recommended

| Tool | Kind | Why it matters | Install |
|---|---|---|---|
| **context7** | MCP (shared) | Essential for TS because framework APIs move fast (React Server Components, Next 15+, TanStack Query v5, Prisma, Drizzle). Fetches current docs. See shared `recommended-tooling.md`. | See shared file |
| **playwright** | MCP (shared) | Core dev loop for web frontends — drive a real browser, verify UI changes, debug e2e failures. Heavily used for React/Next.js/Tauri work. See shared `recommended-tooling.md`. | See shared file |
| **TypeScript Language Server (editor)** | Editor LSP | `tsserver` running in your editor gives Claude access to real-time type errors, go-to-definition, references, and rename. Already bundled with VS Code; JetBrains has it built-in. No MCP needed — the editor extension exposes it. | VS Code (bundled), JetBrains (bundled) |
| **Biome (or ESLint) via editor** | Editor LSP | Surfaces lint + format findings instantly. MTK already runs `biome check` / `eslint` at build/pre-commit time; the editor integration gives same feedback interactively. | VS Code Marketplace → "Biome" or "ESLint" |

## Nice to Have

| Tool | Kind | Why it matters | Install |
|---|---|---|---|
| **frontend-design** | Plugin | Generates distinctive, production-grade UI components with opinionated design quality — avoids generic AI aesthetics. High value for frontend-heavy work. | `/plugin install frontend-design` |
| **Chrome DevTools MCP** | MCP | Lets Claude inspect a running Chrome instance — network requests, console, DOM. Overlaps with Playwright but useful for debugging deployed apps. | Check `modelcontextprotocol.io/servers` |
| **Vercel MCP** | MCP | For Next.js projects deploying to Vercel — query deployment status, logs, env vars. Skip if not on Vercel. | Check Vercel docs |
| **Tauri / Rust-analyzer (Tauri projects only)** | Editor LSP | If `src-tauri/` exists, `rust-analyzer` in your editor handles the Rust sidecar — Claude can navigate Tauri commands, inspect types, see `cargo check` errors interactively. | Editor marketplace → "rust-analyzer" |

## Notes

- **No dominant TypeScript LSP MCP yet** — as of 2026, `tsserver` works best via editor integration, not as a standalone MCP. Claude can ask the editor for diagnostics through the VS Code / JetBrains extensions.
- **Package-manager MCPs:** `bun`, `pnpm`, `yarn`, `npm` run fine as Bash commands; no MCP needed. MTK's `tech-stack-pm` auto-detection handles routing.
- **Next.js / React DevTools:** browser devtools don't have a stable MCP; use Chrome DevTools MCP or the Playwright MCP instead.
- **Monorepo tooling (Turbo, Nx):** no MCPs today. The CLI tools work fine via Bash.
