# Recommended Tooling — .NET

> Stack-specific MCP servers, plugins, and integrations that noticeably improve Claude Code productivity on .NET projects. Pair with `.claude/references/recommended-tooling.md` (shared).
>
> MTK does not auto-install anything on this list.

## Strongly Recommended

| Tool | Kind | Why it matters | Install |
|---|---|---|---|
| **csharp-lsp** | MCP | Exposes Roslyn language-server features — go-to-definition, references, rename, hover, diagnostics, code actions. Huge productivity boost: Claude can navigate C# code semantically instead of grepping. Also handles XAML (for WPF/MAUI/Avalonia). | `claude mcp add csharp-lsp -- npx -y @microsoft/mcp-csharp-lsp` (check upstream for current package name) |
| **dotnet-claude-kit** | Plugin | 15 Roslyn-powered MCP tools — anti-pattern detection (AsyncVoid, BroadCatch, EfCoreNoTracking, etc.), circular dependency detection, dead code finder, project graph, type hierarchy. MTK integrates with it directly in the review pipeline. | `/plugin install codewithmukesh/dotnet-claude-kit` |
| **microsoft-learn** | MCP | Official Microsoft / Azure documentation search and fetch. Grounds Claude's answers in authoritative, current docs instead of training-data knowledge. Critical when working with Azure SDKs, .NET preview features, or migration guides. | `claude mcp add microsoft-learn -- npx -y @microsoft/mcp-docs` (check upstream) |

## Nice to Have

| Tool | Kind | Why it matters | Install |
|---|---|---|---|
| **dotnet-skills (Petabridge)** | Plugin | Large skill pack covering Akka.NET, EF Core patterns, Aspire, modern C# standards, package management, performance analysis, and more. Useful even if you don't use Akka — many skills are general .NET best practices. | `/plugin install petabridge/dotnet-skills` |
| **JetBrains MCP (Rider)** | MCP | If the team uses Rider, exposes Rider-specific features: Navigate, Inspect, Run Configurations, debugger integration. Complements (not replaces) csharp-lsp. | JetBrains Marketplace → "MCP Server" |
| **ILSpy CLI** | Tool | Decompile any .NET assembly — inspect framework internals, see how a NuGet package actually works, debug obscure behavior. Skill wrapper available via dotnet-skills. | `dotnet tool install -g ilspycmd` |

## Notes

- **Slopwatch:** dotnet-skills includes a "slopwatch" skill that detects LLM reward-hacking patterns (disabled tests, suppressed warnings, empty catches). Overlaps with MTK's own linter but catches different things — running both is fine.
- **Roslyn analyzers vs csharp-lsp MCP:** analyzers run at build time and surface findings via `dotnet build`; csharp-lsp MCP runs interactively during a session. They complement each other — MTK's `parse-build-diagnostics.sh` handles the first; csharp-lsp handles the second.
- **Test runners:** there's no MCP for `dotnet test` — use Bash directly. If a specialized .NET test-runner MCP emerges, add it here.
