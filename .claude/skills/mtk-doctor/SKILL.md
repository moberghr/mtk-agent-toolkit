---
name: mtk-doctor
description: Run an MTK install health check (core files, components, hooks, integrity, environment fit) with PASS/WARN/FAIL diagnostics, --json for CI, and --fix for safe auto-repairs.
type: skill
allowed-tools: Read, Bash
argument-hint: "[--json] [--fix] [--strict]"
user-invocable: true
---

# MTK Doctor

## Overview

`mtk-doctor` is the holistic health check for an MTK installation. Where `validate-toolkit.sh` checks structural integrity (manifest matches files, frontmatter shape), the doctor catches runtime rot: deprecated model IDs in agents, an oversized constitution, settings keys Claude Code ignores, missing gitignore entries, stale analytics, dangling hook registrations.

The script ships with the plugin, so run it from `${CLAUDE_PLUGIN_ROOT}`. It diagnoses two trees: toolkit checks run against the plugin's own files, project checks (constitution, `.claude/settings*.json`, `.gitignore`, lessons, context baseline, environment) against the repo it was run for (`$CLAUDE_PROJECT_DIR`, else the current directory).

## When To Use

- Periodically (e.g. before bumping the toolkit version)
- When the engineer asks "is the toolkit healthy?" or "is anything broken?"
- After upgrading MTK in a target repo (catch deprecated IDs and hook drift)
- In CI as `bash scripts/mtk-doctor.sh --strict --json` for dashboards

### When NOT To Use

- For structural validation in tight loops — use `validate-toolkit.sh` (faster, focused).
- To debug a specific failing skill — use `context-report` instead.

## Workflow

1. **Run the script.** Default: human-readable output.
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/mtk-doctor.sh"
   ```

2. **Apply safe fixes.** Auto-fix gitignore additions, chmod issues, and the invalid `permissions.allowedTools` key:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/mtk-doctor.sh" --fix
   ```
   The `allowedTools` migration is the only FAIL `--fix` repairs (a lossless key move). Every other FAIL is reported, not fixed.

3. **CI mode.** Strict + JSON:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/mtk-doctor.sh" --strict --json
   ```
   Strict treats WARN as failure (exit 1). JSON output suits dashboards.

4. **Triage failures.** Each FAIL entry includes a `detail` field pointing at the fix path. Common cases:
   - "version mismatch" → bump both manifest.json and plugin.json (and marketplace.json) to the same value
   - "deprecated model" → update agent frontmatter to a current model ID or alias; "previous-generation model pinned" (WARN) → the alias already follows the current generation
   - "uses permissions.allowedTools" → Claude Code has no such key (valid: `permissions.allow` / `deny` / `ask`), so the list was ignored; `--fix` runs `scripts/migrate-settings-permissions.sh` on `.claude/settings.json` and `.claude/settings.local.json`
   - "hook missing" → either add the hook script or remove its registration from settings.json
   - "skill name mismatch" → rename the directory or update frontmatter `name:` to match
   - "hook basename also wired globally" → confirm the collision is intended; two scripts sharing a filename both run and log indistinguishably
   - "hook collision check skipped" → set `CLAUDE_PLUGIN_ROOT` so the check can see MTK's hooks; it compared nothing, which is not the same as finding nothing
   - "formatter missing" → install the stack's formatter, or accept that edits go unformatted (the hook never blocks)

## Categories Checked

- **CORE** — required toolkit files (manifest, plugin.json, README, AGENTS, validate-toolkit); the project's resolved constitution line budget
- **COMPONENTS** — version sync, skill counts, skill name/directory consistency, deprecated model detection
- **HOOKS** — hooks registered in the project's settings.json exist and are executable, event names are documented Claude Code events, all MTK hooks use `set -euo pipefail`
- **PERMISSIONS** — the project's `.claude/settings.json` / `settings.local.json` carry no `permissions.allowedTools` (FAIL; `--fix` migrates it)
- **INTEGRITY** — manifest paths exist, gitignore coverage, analytics freshness, validate-toolkit passes
- **CONTEXT** — always-on context baseline (CLAUDE.md + a loaded AGENTS.md + alwaysApply refs, in tokens/bytes), MCP schema count from the project's own `.mcp.json`, `ENABLE_TOOL_SEARCH` state (report-only, never WARN/FAIL)
- **ENVIRONMENT** — fit between the install and the machine, which structural checks cannot see: MTK hook basenames also wired in the user's global `settings.json`, and whether the active stack's formatter binary is actually on PATH. WARN at most — an environment mismatch is never a broken install

## Verification

- [ ] Output shows non-zero PASS in every category (no empty section)
- [ ] Summary line printed last
- [ ] Exit code 1 on any FAIL
- [ ] `--strict` exits 1 on WARN
- [ ] `--json` output is valid JSON parseable by `jq`
- [ ] `--fix` only modifies gitignore, file permissions, and the `allowedTools` → `allow` key move; never edits source files

## Red Flags

- Doctor reports PASS when validate-toolkit.sh fails — checks are out of sync
- `--fix` modifies source code or skill content (it shouldn't — only gitignore, chmod, and the settings key move)
- New checks added that overlap with validate-toolkit.sh — keep validator structural, doctor holistic
- Deprecated model list goes stale — update `DEPRECATED_MODELS` in scripts/mtk-doctor.sh when Anthropic deprecates more
