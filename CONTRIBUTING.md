# Contributing to claude-helpers

This toolkit is the shared source of truth for AI-assisted development at Moberg HR.
Anyone on the team can extend it — add commands, skills, agents, references, or validation rules.

## How the Toolkit Works

```text
This repo                       install/update                 Target repos
  .claude/commands/*.md   ───────────────────────────>        .claude/commands/*.md
  .claude/skills/*/SKILL.md                                   .claude/skills/*/SKILL.md
  .claude/agents/*.md                                         .claude/agents/*.md
  .claude/references/*.md                                     .claude/references/*.md
  AGENTS.md                                                   AGENTS.md
  docs/*                                                      docs/*
  scripts/*                                                   scripts/*
  .claude/settings.json          (merge, not overwrite)       .claude/settings.json
  .claude/manifest.json          (controls what ships)
```

`manifest.json` is the registry. It lists every file that gets distributed, where it comes from, how it gets distributed (`sync` = overwrite, `merge` = intelligent union), and which files are `protected`.

## Architecture Guidelines

- Commands are entry points.
- Skills hold reusable workflow logic.
- Agents are specialized personas, usually for review.
- References hold durable standards and checklists.
- If a command section could be reused elsewhere, extract a skill instead of growing the command.

## Adding a New Command

1. Create `.claude/commands/your-command.md` with this structure:

```yaml
---
description: One-line description shown in the command list
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
argument-hint: [optional] <expected arguments>
---

# Command Title

## Workflow

## Critical Rules
```

2. Keep command-specific orchestration in the command.
3. Put reusable workflow rules in a skill.
4. Register the command in `manifest.json`.
5. Bump the `version` in `manifest.json`.

## Adding a New Skill

1. Create `.claude/skills/<skill-name>/SKILL.md`
2. Follow `docs/skill-anatomy.md`
3. Use this minimum structure:

```yaml
---
name: skill-name
description: Short description of the reusable workflow
---

# Skill Title

## Overview

## When To Use

## Workflow

## Verification
```

4. Register the skill in `manifest.json`
5. Reference it from a command or `AGENTS.md`
6. Bump the `version` in `manifest.json`

## Adding a New Agent

Agents are standalone personas invoked by commands or used in review routing.

1. Create `.claude/agents/your-agent.md`
2. Keep agent tools narrow, usually read-only
3. Use `model: sonnet` unless there is a clear reason not to
4. Register the agent in `manifest.json`
5. Bump the version

## Adding References

References are shared documents that commands, skills, and agents read.

1. Place the file in `.claude/references/your-reference.md`
2. Register it in `manifest.json` with `"action": "sync"`
3. If it is repo-specific and should never be overwritten, add it to `protected` instead

## Writing Anti-Rationalization Tables

This is still one of the highest-value prompt patterns in the repo.

Good rationalizations are:

- specific
- realistic
- paired with sharp rebuttals
- domain-aware

Bad rationalizations are:

- generic advice
- rule restatements with no consequence
- hypothetical cases the model never actually uses

## Testing Changes Locally

Before pushing changes:

1. Verify command or agent syntax in Claude Code if applicable
2. Check the manifest — every new shipped file must be registered
3. Check protected files — generated repo-local assets should not be overwritten later
4. Bump the version in `manifest.json`
5. Run `bash scripts/validate-toolkit.sh`
6. If the workflow logic is reusable, update `AGENTS.md` and the relevant commands to compose the new skill

## Style Guidelines

- Be opinionated.
- Be concrete.
- Be brief.
- Number rules when they need to be cited.
- Match existing patterns.
- Prefer extraction over growth when a workflow is reusable.
