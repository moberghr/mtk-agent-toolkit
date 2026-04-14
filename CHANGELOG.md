# Changelog

All notable changes to MTK are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- **Deterministic analysis layer** (Wave 4): Roslyn/ruff/tsc analyzer configuration references, build output parser (`hooks/parse-build-diagnostics.sh`), severity mapping files. Four finding sources now merge uniformly: linter, analyzer, ai, drift.
- **Distribution & updates** (Wave 5): `/mtk:setup-update` skill for updating bootstrapped repos. Version stamps (`.claude/mtk-version.json`), settings.json merge script, version drift detection in session-start.
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
