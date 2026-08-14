---
name: mtk-doctor
description: Run an MTK install health check (core files, components, hooks, integrity, environment fit) with PASS/WARN/FAIL diagnostics, --json for CI, and --fix for safe auto-repairs.
type: skill
allowed-tools: Read, Bash
argument-hint: [--json] [--fix] [--strict]
user-invocable: true
---

# MTK Doctor

## Overview

`mtk-doctor` is the holistic health check for an MTK installation. Where `validate-toolkit.sh` checks structural integrity (manifest matches files, frontmatter shape), the doctor catches runtime rot: deprecated model IDs in agents, oversized CLAUDE.md, missing gitignore entries, stale analytics, dangling hook registrations.

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
   bash scripts/mtk-doctor.sh
   ```

2. **Apply safe fixes.** Auto-fix gitignore additions and chmod issues:
   ```bash
   bash scripts/mtk-doctor.sh --fix
   ```
   FAILs are never auto-fixed. Auto-fix is for known-safe items only.

3. **CI mode.** Strict + JSON:
   ```bash
   bash scripts/mtk-doctor.sh --strict --json
   ```
   Strict treats WARN as failure (exit 1). JSON output suits dashboards.

4. **Triage failures.** Each FAIL entry includes a `detail` field pointing at the fix path. Common cases:
   - "version mismatch" → bump both manifest.json and plugin.json (and marketplace.json) to the same value
   - "deprecated model" → update agent frontmatter to a current model ID
   - "hook missing" → either add the hook script or remove its registration from settings.json
   - "skill name mismatch" → rename the directory or update frontmatter `name:` to match
   - "context budget miscalibrated" → set `MTK_CONTEXT_WINDOW_TOKENS` in `.claude/settings.local.json` `env` to the model's real window
   - "hook basename also wired globally" → confirm the collision is intended; two scripts sharing a filename both run and log indistinguishably
   - "formatter missing" → install the stack's formatter, or accept that edits go unformatted (the hook never blocks)

## Categories Checked

- **CORE** — required files (manifest, plugin.json, README, AGENTS, validate-toolkit), CLAUDE.md line budget if present
- **COMPONENTS** — version sync, skill counts, skill name/directory consistency, deprecated model detection
- **HOOKS** — registered hooks exist and are executable, event names valid, all hooks use `set -euo pipefail`
- **INTEGRITY** — manifest paths exist, gitignore coverage, analytics freshness, validate-toolkit passes
- **CONTEXT** — always-on context baseline (CLAUDE.md + rules/INDEX.md + alwaysApply refs, in tokens/bytes), MCP schema count from `.mcp.json`, `ENABLE_TOOL_SEARCH` state (report-only, never WARN/FAIL)
- **ENVIRONMENT** — fit between the install and the machine, which structural checks cannot see: `MTK_CONTEXT_WINDOW_TOKENS` calibration against the model in use, MTK hook basenames also wired in the user's global `settings.json`, and whether the active stack's formatter binary is actually on PATH. WARN at most — an environment mismatch is never a broken install

## Verification

- [ ] Output shows non-zero PASS in every category (no empty section)
- [ ] Summary line printed last
- [ ] Exit code 1 on any FAIL
- [ ] `--strict` exits 1 on WARN
- [ ] `--json` output is valid JSON parseable by `jq`
- [ ] `--fix` only modifies gitignore and file permissions; never edits source files

## Red Flags

- Doctor reports PASS when validate-toolkit.sh fails — checks are out of sync
- `--fix` modifies source code or skill content (it shouldn't — only gitignore + chmod)
- New checks added that overlap with validate-toolkit.sh — keep validator structural, doctor holistic
- Deprecated model list goes stale — update `DEPRECATED_MODELS` in scripts/mtk-doctor.sh when Anthropic deprecates more
