# MTK MCP Server (`mtk-context`)

A read-only stdio MCP server that exposes canonical MTK state to agents (Claude, Codex, any MCP-aware LLM). Bundled to `dist/mtk-mcp-server.cjs` by `scripts/build-mcp.sh`. The bundle is **tracked in git and ships with the plugin** (S3.12: it is the only runtime artifact, so users never run `npm install`). In a checkout with `mcp/` sources, `hooks/session-start` rebuilds it when `mcp/src/**` is newer than the bundle; commit the rebuilt bundle with the source change.

## Tools

All tools return JSON in the standard MCP `content[0].text` shape. Read-only by construction — enforced by `scripts/validate-toolkit.sh` (no `fs.write*`, no `child_process`, no shell exec in `mcp/src/tools/`).

| Tool | What it returns | Bash fallback |
|---|---|---|
| `mtk_resolve_references` | Reference docs that match given file paths via `applyTo` globs | `bash scripts/build-references-index.sh && cat .claude/references.index` |
| `mtk_solution_structure` | Project graph (.NET/.sln, Python/pyproject, TS/package.json) | `find . -name '*.csproj' -o -name 'pyproject.toml' -o -name 'package.json'` |
| `mtk_manifest` | Parsed `.claude/manifest.json` | `cat .claude/manifest.json` |
| `mtk_analytics` | Parsed `.claude/analytics.json` | `cat .claude/analytics.json` |
| `mtk_audit` | `architecture-principles.md` parsed into `{tag, confidence, statement, evidence}` plus raw markdown | `cat .claude/references/architecture-principles.md` |
| `mtk_references_index` | Parsed `.claude/references.index` (path, alwaysApply, description, globs) | `cat .claude/references.index` |
| `mtk_active_stack` | Active tech stack from `.claude/tech-stack` | `cat .claude/tech-stack` |

Skills should call the MCP tool when available and fall through to the bash command otherwise. The fallbacks are intentionally simple — they operate on the same source files the MCP tools wrap.

## Registering with Claude

Nothing to register in a target repo. The plugin declares the server in its own root `.mcp.json`, and Claude Code starts it for every project where the `mtk` plugin is enabled:

```json
{
  "mcpServers": {
    "mtk-context": {
      "type": "stdio",
      "command": "node",
      "args": ["${CLAUDE_PLUGIN_ROOT}/dist/mtk-mcp-server.cjs"]
    }
  }
}
```

`${CLAUDE_PLUGIN_ROOT}` is set only for servers a plugin declares, so do not copy this block into a project `.mcp.json`: there it expands to nothing and the server fails to start. When developing MTK itself, load the checkout as the plugin (`claude --plugin-dir .`, see CONTRIBUTING.md) and the same declaration points at your working copy. If the bundle is missing, run `bash scripts/build-mcp.sh` once.

## Threat model

- **Read-only.** No file writes, no shell exec, no network. The validator's grep gate enforces this on every commit; CI fails if `mcp/src/tools/` adds a write API.
- **Scoped.** All reads are confined to `.claude/` and project-root files (`pyproject.toml`, `*.csproj`, `package.json`).
- **No secrets.** The server reads JSON/markdown that is checked into git. It will not read environment variables, dotfiles, or credentials.

## Build, test, run

```bash
bash scripts/build-mcp.sh        # rebuild dist/mtk-mcp-server.cjs
cd mcp && npm test               # run vitest suite
node dist/mtk-mcp-server.cjs     # serve over stdio
```

## Versioning

`mcp/package.json` `version` and `mcp/src/index.ts` server `version` are kept in sync. Bump on tool surface changes (added/removed/renamed tools, schema changes). Patch bumps are fine for bug fixes; minor for additive tools; major reserved for removals or breaking schema changes.
