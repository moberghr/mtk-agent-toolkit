# Recommended Tooling (Stack-Agnostic)

> Curated list of MCP servers, plugins, and editor integrations that noticeably improve Claude Code productivity on any stack. Stack-specific recommendations live in `.claude/references/{stack}/recommended-tooling.md`.
>
> MTK does not auto-install anything on this list. Install what fits your workflow; skip the rest.

## Strongly Recommended

| Tool | Kind | Why it matters | Install |
|---|---|---|---|
| **context7** | MCP | Fetches current documentation for libraries, frameworks, SDKs — better than relying on training-data knowledge. Works for React, Next.js, Prisma, Django, Spring, etc. | `claude mcp add context7 -- npx -y @upstash/context7-mcp` |
| **playwright** | MCP | Lets Claude drive a real browser — click, navigate, take snapshots, fill forms. Essential for UI verification, e2e debugging, and testing frontend changes end-to-end. | `claude mcp add playwright -- npx -y @playwright/mcp@latest` |
| **claude-mem** | Plugin | Cross-session memory: Claude remembers past decisions, solved problems, and context across sessions. Big compound win on long-lived repos. | `/plugin install claude-mem` |
| **Claude for Chrome** | Browser extension | Agent-in-the-browser — lets Claude take actions on web apps, fill forms, verify deployed changes. Pairs well with the playwright MCP for dev-loop work. | [claude.ai/chrome](https://claude.ai/chrome) |
| **Claude Code (VS Code / JetBrains)** | Editor extension | Native IDE integration — diff view, inline edits, keyboard shortcuts. Much better UX than terminal-only. | VS Code Marketplace / JetBrains Plugins |

## Nice to Have

| Tool | Kind | Why it matters | Install |
|---|---|---|---|
| **github** | MCP | Create/read PRs, issues, reviews, and commits via Claude. Useful if you don't want to hand `gh` commands every time. | `claude mcp add github -- npx -y @modelcontextprotocol/server-github` |
| **atlassian** | MCP | Jira + Confluence integration — create tickets from specs, search company knowledge, triage bugs, generate status reports. High value for teams that live in Jira. | See Atlassian MCP docs |
| **jetbrains** | MCP | Exposes JetBrains IDE features (Rider, IntelliJ, WebStorm) to Claude — refactors, symbol navigation, debugger integration. Rider users on .NET benefit most. | JetBrains Marketplace → "MCP Server" |
| **gitnexus** | MCP | Code knowledge graph — impact analysis, dependency tracing, rename safety. Strong for large codebases where blast-radius reasoning matters. | See gitnexus docs |
| **pr-review-toolkit** | Plugin | Specialized PR review agents (code-reviewer, test-analyzer, comment-analyzer, silent-failure-hunter). Complements MTK's review skills. | `/plugin install pr-review-toolkit` |
| **visual-explainer** | Plugin | Generates HTML diagrams, architecture overviews, diff reviews, and plan reviews as standalone browser-viewable files. | `/plugin install visual-explainer` |

## Notes

- **MCP server management:** list installed MCPs with `claude mcp list`; remove with `claude mcp remove <name>`.
- **Plugin management:** list with `/plugin list`; remove with `/plugin remove <name>`.
- **Security:** MCP servers run with your local permissions. Only install servers from sources you trust.
- **Scope:** MCPs installed via `claude mcp add` are local to your machine. For team-wide MCPs, add a project-scoped `.mcp.json` and commit it.
