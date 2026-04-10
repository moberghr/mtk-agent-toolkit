# claude-helpers

Shared Claude Code toolkit for consistent AI-assisted development across Moberg HR.

**Quick start**

```text
/plugin marketplace add moberghr/claude-helpers
/plugin install moberg@moberghr
```

Then bootstrap your repo: `/moberg:init`

This repository is the single source of truth for commands, skills, agents, settings, and references distributed to Moberg project repositories.

## Architecture Model

- Commands are stable entry points.
- Skills are reusable workflow building blocks.
- Agents are specialized reviewer personas.
- References hold durable standards and checklists.
- `AGENTS.md` routes OpenCode-style agents into the right skills.

## Current Skill Set

Core workflow skills:

- `context-engineering`
- `spec-driven-development-dotnet`
- `planning-and-task-breakdown`
- `incremental-implementation-dotnet`
- `test-driven-development-dotnet`
- `debugging-and-error-recovery`
- `code-review-and-quality-fintech`
- `security-and-hardening-fintech`
- `source-driven-development`
- `code-simplification`

## Command Model

- `implement` composes context, spec, planning, implementation, TDD, source verification, review, security checks, and simplification.
- `fix` composes context, debugging, regression-focused TDD, and targeted security/source checks when needed.
- `init` bootstraps repo-specific `CLAUDE.md` and project references.
- `validate` validates the toolkit repo itself.

## Review Model

- `compliance-reviewer` for security and compliance risk
- `test-reviewer` for test completeness and verification quality
- `architecture-reviewer` for architectural fit and slice boundaries

## References

- `coding-guidelines.md`
- `testing-patterns.md`
- `security-checklist.md`
- `performance-checklist.md`
- `ef-core-checklist.md`
- `mediatr-slice-patterns.md`

## Distribution

This repo supports both plugin and manual distribution.

- Plugin: fastest onboarding
- Manifest/manual install: controlled rollout, merge semantics, committed toolkit assets

Manual distribution ships:

- commands
- skills
- agents
- references
- `AGENTS.md`
- `docs/skill-anatomy.md`
- `scripts/validate-toolkit.sh`

## Repo Structure

```text
claude-helpers/
  .claude/
    commands/
    skills/
    agents/
    references/
    manifest.json
    settings.json
  .claude-plugin/
    plugin.json
    marketplace.json
  AGENTS.md
  docs/
    skill-anatomy.md
  scripts/
    validate-toolkit.sh
```

## Validation

Run:

```bash
bash scripts/validate-toolkit.sh
```

## Contributing

See `CONTRIBUTING.md` and `docs/skill-anatomy.md`.
