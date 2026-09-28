# Batch — Claude directory submission prep — 2026-09-28

Scope: no new public contract; no architectural change. Goal: pass
`claude plugin validate --strict`, keep the plugin folder ≤512 files, and leave
`dist/mtk-mcp-server.cjs` as the only file over 256 KiB (accepted reviewer hold).

Gate: satisfied by the engineer's explicit go-ahead ("ok, lets do this") on the
enumerated list, plus AskUserQuestion answers for the three open choices.

1. Remove the unknown `settings.json` key from `.claude-plugin/plugin.json` — mechanical.
2. Move the GitHub Pages site (`docs/index.html`, `docs/how-it-works.*`,
   `docs/build-how-it-works.py`, `docs/.nojekyll`, site-only SVGs) to the `gh-pages`
   branch; switch the Pages source to it — mechanical, crosses the deploy boundary.
3. Archive completed `docs/specs` + `docs/plans` to `archive/design-history`; keep
   `docs/specs/baseline/`, anything still referenced, and September 2026 work — mechanical.
4. Add a README "What MTK runs" disclosure section for the directory security scan — docs.

Dropped: the `mtk-context` MCP connection failure is a dev-checkout artifact (the repo-root
`.mcp.json` loads as a project server where `${CLAUDE_PLUGIN_ROOT}` is empty); plugin
installs are unaffected.
