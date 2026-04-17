# Changelog

All notable changes to MTK are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/).

## [6.3.0] - 2026-04-17

### Changed (breaking for muscle memory, not for functionality)
- **Consolidated to two user-invocable entry points:** `/mtk` (natural-language router) and `/mtk-setup` (bootstrap + audit dispatcher). Previous slash commands (`/mtk:implement`, `/mtk:fix`, `/mtk:pre-commit-review`, `/mtk:setup-bootstrap`, `/mtk:setup-audit`) are now workflow skills reached through the `/mtk` router — e.g., `/mtk fix the null check`, `/mtk review before commit`.
- `setup-bootstrap` and `setup-audit` merged behind the new `/mtk-setup` entry point (`--audit` flag re-runs audit, `--merge` unifies multi-repo audits).
- Pre-commit git hook still works unchanged — it invokes the linter directly, not the skill.

### Removed
- **`/mtk:setup-update` skill** — updates now flow through the Claude Code plugin manager, not an in-repo command. Removed associated pressure test.

### Migration
- Old: `/mtk:setup-bootstrap` → new: `/mtk-setup`
- Old: `/mtk:setup-audit [--merge]` → new: `/mtk-setup --audit [--merge]`
- Old: `/mtk:implement <feature>` → new: `/mtk <feature>`
- Old: `/mtk:fix <description>` → new: `/mtk fix <description>`
- Old: `/mtk:pre-commit-review` → new: `/mtk review before commit`
- Old: `/mtk:setup-update` → use the plugin marketplace to upgrade

## [Unreleased]

### Added
- **Deterministic analysis layer** (Wave 4): Roslyn/ruff/tsc analyzer configuration references, build output parser (`hooks/parse-build-diagnostics.sh`), severity mapping files. Four finding sources now merge uniformly: linter, analyzer, ai, drift.
- **Distribution & updates** (Wave 5): Version stamps (`.claude/mtk-version.json`), settings.json merge script, version drift detection in session-start.
- **MCP codebase intelligence** (Wave 6): Optional MCP server for deterministic reference resolution and solution structure awareness. Bash fallbacks for all MCP tools.
- **Cross-agent portability** (Wave 2): `scripts/generate-agents-md.sh` generates portable AGENTS.md for Cursor, Copilot, Gemini, Codex.
- **CI pipeline** (Wave 3): GitHub Actions workflow for automated validation on PRs.
- **Strengthened reviewers** (Wave 1): test-reviewer and architecture-reviewer now have confidence scoring, anti-rationalization tables, and anti-inflation rules matching compliance-reviewer rigor.
- Stale evidence threshold in verification-before-completion (timestamp-based, not gut feel)
- Behavioral diff advisory hook
- Pressure tests for test-reviewer and architecture-reviewer

## [6.1.3] - 2026-04-14

### Fixed
- Use user-invocable frontmatter to control skill visibility
- Improve setup-bootstrap precision and limit user-invocable skills to 6
- Remove duplicate hooks key from plugin.json

## [6.1.0] - 2026-04-13

### Changed
- Commands merged into skills per Claude Code v2.1.101
- All entry points now live in `.claude/skills/`
