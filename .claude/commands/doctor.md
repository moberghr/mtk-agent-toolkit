---
description: Quick health check for toolkit setup — verifies CLAUDE.md, references, toolkit version, and common issues. Run when onboarding or troubleshooting.
allowed-tools: Read, Glob, Grep, Bash
argument-hint:
---

# Moberg Doctor — Toolkit Health Check

Run this when something feels wrong, when onboarding a new repo, or when the toolkit was recently updated.

## Checks

Run ALL of these checks and report results:

### 1. CLAUDE.md Present
- Check if `CLAUDE.md` exists in the repo root
- If missing: "Run `/moberg:init` to generate CLAUDE.md from codebase scan."

### 2. Tech Stack Detected
- Read `.claude/tech-stack` (single word: `dotnet`, `python`, etc.)
- If missing: "Run `/moberg:init` to detect the tech stack and bootstrap the repo."
- If present, verify `.claude/skills/tech-stack-{stack}/SKILL.md` exists.

### 3. References Valid

Always-required (any stack):
- `.claude/references/security-checklist.md`
- `.claude/references/testing-patterns.md`
- `.claude/references/performance-checklist.md`

Stack-specific (read paths from the active tech stack skill's `## Reference Files`):
- For `dotnet`: `.claude/references/dotnet/coding-guidelines.md`, `ef-core-checklist.md`, `mediatr-slice-patterns.md`, `testing-supplement.md`, `performance-supplement.md`
- For `python`: `.claude/references/python/coding-guidelines.md`, `sqlalchemy-checklist.md`, `fastapi-patterns.md`, `testing-supplement.md`, `performance-supplement.md`

For each missing file: report it and suggest running `/moberg:update`.

### 3. Toolkit Version
- Read `.claude/manifest.json` and report the version and last-updated date.
- If the file is missing: "Toolkit not installed. Run `/moberg:install`."

### 4. Skills Integrity
- Check that every skill directory under `.claude/skills/` has a `SKILL.md` file.
- Check that each SKILL.md has frontmatter with `name` and `description`.
- Report any skills with missing or malformed SKILL.md.

### 5. Agents Present
- Check that `.claude/agents/compliance-reviewer.md` exists.
- Check for `test-reviewer.md` and `architecture-reviewer.md`.
- Report any missing agents.

### 6. Settings Health
- Check that `.claude/settings.json` exists.
- Verify it has `permissions.deny` entries (blocks dangerous operations).
- Verify hooks are configured.

### 7. Lessons Freshness
- Check if `tasks/lessons.md` exists.
- If it exists, report the line count and last modification date.
- If it has more than 50 entries, suggest reviewing and promoting recurring patterns to CLAUDE.md.

### 8. In-Progress Work
- Check for incomplete tasks in `tasks/todo.md` (lines with `[ ]`).
- Check for recent specs in `docs/specs/`.
- Check for recent plans in `docs/plans/`.
- Report any in-progress work found.

## Output Format

```
Moberg Doctor — Health Check Results

  CLAUDE.md .............. [OK | MISSING]
  References ............. [6/6 | X/6 — list missing]
  Toolkit version ........ [X.Y.Z, updated YYYY-MM-DD | NOT INSTALLED]
  Skills integrity ....... [N skills, all valid | issues found]
  Agents ................. [3/3 | X/3 — list missing]
  Settings ............... [OK | issues found]
  Lessons ................ [N entries, last updated DATE | none]
  In-progress work ....... [none | found — details]

  Overall: [HEALTHY | N issues found]
```

## Rules

- Report every check, even if it passes.
- Do not fix issues — only diagnose and report.
- Suggest the specific command to fix each issue.
