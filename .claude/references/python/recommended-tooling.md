# Recommended Tooling — Python

> Stack-specific MCP servers, plugins, and integrations that noticeably improve Claude Code productivity on Python projects. Pair with `.claude/references/recommended-tooling.md` (shared).
>
> MTK does not auto-install anything on this list.

## Strongly Recommended

| Tool | Kind | Why it matters | Install |
|---|---|---|---|
| **context7** | MCP (shared) | Critical for Python because package APIs move fast (FastAPI, Pydantic v2, SQLAlchemy 2.0, Django 5). Fetches current docs for any library instead of relying on training-data knowledge. See shared `recommended-tooling.md`. | See shared file |
| **Pyright / basedpyright (LSP via editor)** | Editor LSP | Full semantic type checking — catches bugs Claude can't see from reading files alone. Run through the VS Code Pylance extension or JetBrains Python plugin; surfaces real-time diagnostics Claude can query via editor integration. | VS Code Marketplace → "Pylance"; JetBrains bundled |
| **Ruff LSP (editor)** | Editor LSP | Fast Python linter + formatter exposed as an LSP. Surfaces style + correctness findings instantly. MTK already runs `ruff check` at build/pre-commit time; the LSP gives same feedback interactively. | `pip install ruff-lsp` + VS Code "Ruff" extension |

## Nice to Have

| Tool | Kind | Why it matters | Install |
|---|---|---|---|
| **playwright (shared)** | MCP | For FastAPI/Django apps with a web frontend, pairs with pytest-asyncio to verify UI flows. See shared `recommended-tooling.md`. | See shared file |
| **Jupyter MCP** | MCP | If the project uses notebooks (data science, ML prototyping), lets Claude execute cells and read outputs. Skip if no `.ipynb` files. | Check `modelcontextprotocol.io/servers` |

## Notes

- **No dominant Python LSP MCP yet** — as of 2026, Python LSPs (Pyright, Ruff) run best through editor extensions, not standalone MCP servers. When a production-quality Python LSP MCP emerges, add it here.
- **Framework-specific MCPs:** Django, FastAPI, and SQLAlchemy don't have dedicated MCPs. `context7` covers their docs; MTK's scan recipes handle codebase analysis.
- **Testcontainers:** no MCP — run via `pytest` directly. The MTK `testing-supplement` covers patterns.
- **Poetry / uv:** package managers run fine as Bash commands; no MCP needed.
