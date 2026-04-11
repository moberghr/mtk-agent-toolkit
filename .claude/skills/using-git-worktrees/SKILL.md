---
name: using-git-worktrees
description: Use when creating an isolated workspace for feature work, experiments, or parallel development to avoid contaminating the main branch.
license: MIT
compatibility:
  - claude-code
  - cursor
  - codex
trigger: feature-isolation|parallel-development|experiment|clean-rollback
skip_when: quick-single-file-fix|explicit-current-branch
---

# Using Git Worktrees

## Overview

Git worktrees provide isolated workspaces without the overhead of multiple clones. This skill ensures worktrees are created safely, dependencies are installed, and baseline tests pass before work begins.

## When To Use

- Feature implementation that should not contaminate the main branch
- Parallel development on multiple features
- Experimentation that needs a clean rollback path
- Any work where isolation reduces risk

### When NOT To Use

- Quick single-file fixes on the current branch
- When the engineer explicitly wants to work on the current branch

## Workflow

1. **Determine worktree location:**
   - Check for `.worktrees/` or `worktrees/` directories in the repo
   - Check `CLAUDE.md` for worktree preferences
   - If neither exists, ask the engineer where to place worktrees
   - Default: `.worktrees/` in the repo root

2. **Verify gitignore safety:**
   - Check if the worktree directory is listed in `.gitignore`
   - If not, add it and commit the `.gitignore` change before creating the worktree
   - Never create a worktree in a directory that would be tracked by git

3. **Create the worktree:**
   ```bash
   git worktree add <path> -b <branch-name>
   ```
   - Branch naming: `feature/<slug>` or `fix/<slug>` matching the task
   - Announce: "Creating isolated worktree at `<path>` on branch `<branch-name>`"

4. **Install dependencies:**
   Auto-detect and install based on project files:
   - `*.csproj` / `*.sln` -> `dotnet restore`
   - `package.json` -> `npm install` or equivalent
   - `requirements.txt` / `pyproject.toml` -> `pip install` or `poetry install`
   - `go.mod` -> `go mod download`
   - `Cargo.toml` -> `cargo fetch`

5. **Run baseline tests:**
   - Execute the project's test command to confirm a clean starting state
   - If baseline tests fail, report the failures before starting work
   - This prevents blaming new work for pre-existing failures

6. **Report setup complete:**
   - Worktree location
   - Branch name
   - Dependency installation result
   - Baseline test results (pass count, any pre-existing failures)

## Finishing A Worktree

When work is complete, present these options:

1. **Merge locally** — integrate into the base branch, then clean up the worktree
2. **Push and create PR** — push the branch, open a pull request, keep the worktree for follow-up
3. **Keep as-is** — preserve for later work
4. **Discard** — permanently delete (requires typed confirmation "discard")

Clean up worktrees only for options 1 and 4:
```bash
git worktree remove <path>
git branch -d <branch-name>  # only if merged
```

## Rules

- Never create a worktree without verifying gitignore status first.
- Always install dependencies before running tests.
- Always run baseline tests before starting work.
- Never force-delete a worktree without explicit engineer confirmation.
- Resolve the lessons path (`tasks/lessons.md`) using the main worktree when working in a worktree.

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "I'll just work on the main branch, it's faster" | Faster until you need to undo half-finished work blocking someone else. |
| "The gitignore is probably fine" | Committing a worktree directory is a mess that wastes everyone's time. Verify. |
| "Dependencies are already installed" | The worktree is a fresh checkout. It has no node_modules, no bin/obj, no venv. |
| "I'll skip baseline tests, I know the tests pass" | Pre-existing failures get blamed on your changes. Prove the starting state. |

## Red Flags

- Worktree created in a tracked directory
- Dependencies not installed before testing
- Baseline tests not run before starting work
- Worktree discarded without engineer confirmation

## Verification

- [ ] Worktree directory is gitignored
- [ ] Dependencies installed successfully
- [ ] Baseline tests ran and results are documented
- [ ] Engineer was informed of the worktree location and branch name
