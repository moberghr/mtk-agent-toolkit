---
name: mtk-setup
description: One-stop setup entry point that bootstraps a repo or re-runs architecture audit
type: skill
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
argument-hint: [--audit|--audit-only] [--merge] [--preview] [--non-interactive]
---

# MTK Setup — Unified Entry Point for Bootstrap and Audit

You are the single setup entry point for MTK. You dispatch to the right workflow skill based on the engineer's argument and the current state of the repo.

## Overview

MTK distinguishes between two setup tasks:

- **Bootstrap (first-time setup):** Detect tech stack, pull coding guidelines, audit the codebase once, generate `CLAUDE.md`, `.claude/tech-stack`, and `.claude/references/architecture-principles.md`. This is the one-time preparation.
- **Re-audit:** Re-run the architectural audit only. Regenerates `.claude/references/architecture-principles.md` (and `conventions.md`) to reflect current reality. Use after significant architectural change.
- **Merge:** Unify architecture audits from multiple repos (e.g., a team hub repo that aggregates `payfac`, `collection-system`, etc.) into a single team-wide document.

## When To Use

- First time onboarding a repo → run `/mtk-setup` with no flags.
- Architecture has drifted and you want `architecture-principles.md` refreshed → `/mtk-setup --audit`.
- You have audit files from multiple repos in `.claude/references/audits/` and want one unified doc → `/mtk-setup --merge`.

## Workflow

### STEP 0: Parse Arguments

Parse the argument string into a mode and flags:

| Flag | Meaning |
|---|---|
| `--audit` or `--audit-only` | Run audit workflow only (skip stack detection, CLAUDE.md generation) |
| `--merge` | Multi-repo unification mode (implies audit) |
| `--preview` | Show proposed changes, ask before writing (bootstrap only) |
| `--non-interactive` | Skip interview questions (bootstrap only) |

Default mode (no flags): **bootstrap**.

### STEP 1: Decide the Target Skill

| Argument pattern | Invoke |
|---|---|
| `--merge` present | `.claude/skills/setup-audit/SKILL.md` (pass `--merge`) |
| `--audit` or `--audit-only` present | `.claude/skills/setup-audit/SKILL.md` (no flags) |
| None of the above | `.claude/skills/setup-bootstrap/SKILL.md` (pass `--preview` / `--non-interactive` through) |

**Ambiguity check:** if the repo has no `.claude/tech-stack` file and the engineer passed `--audit`, warn:

> "No tech stack detected — this looks like a first-time setup. Audit alone won't generate CLAUDE.md. Run `/mtk-setup` with no flags to do a full bootstrap. Proceed with audit only? [y/N]"

Use `AskUserQuestion` for this prompt.

### STEP 2: Read and Follow the Target Skill

Read the target SKILL.md (paths resolved per the MTK File Resolution section below). Follow every step of that skill inline — do NOT summarize or skip steps. The target skill owns its own verification section; run those checks before reporting back.

### STEP 3: Report

When the target skill completes, print a one-line summary:

```
✅ MTK Setup: [mode] complete in [duration]. See [output file(s)].
```

Where `[mode]` is one of: `bootstrap`, `audit`, `merge`.

## MTK File Resolution

MTK skills and shared references live either in the project (local install) or the plugin cache (marketplace install). Resolve once:

1. If `$CLAUDE_PLUGIN_ROOT` is set, prefix `.claude/skills/` and `.claude/references/` reads with it.
2. Otherwise, if `.claude/skills/context-engineering/SKILL.md` exists locally → project-relative paths work as-is.
3. Otherwise, fall back to `find ~/.claude/plugins -maxdepth 8 -name "SKILL.md" -path "*/mtk/*/context-engineering/*" -type f 2>/dev/null | head -1 | sed 's|/.claude/skills/context-engineering/SKILL.md||'`. If empty, MTK skills are unavailable — warn the engineer and proceed with `CLAUDE.md` only.

Always project-relative (never prefixed): `CLAUDE.md`, `.claude/tech-stack`, `.claude/rules/`, `tasks/`, `docs/`, `.claude/references/architecture-principles.md`, `.claude/references/pre-commit-review-list.md`.

## Verification

- [ ] Correct target skill selected based on flags
- [ ] Target skill's verification section was executed
- [ ] All files the target skill was supposed to create exist
- [ ] Bootstrap mode: `CLAUDE.md`, `.claude/tech-stack`, and `.claude/references/architecture-principles.md` exist
- [ ] Audit mode: `.claude/references/architecture-principles.md` updated
- [ ] Merge mode: unified `.claude/references/architecture-principles.md` written; source audits in `.claude/references/audits/` untouched
