---
description: Install the moberg toolkit — globally for user or locally for a project. Handles first-time setup and re-installation.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
argument-hint: [--global | --project] [--auto]
---

# Moberg Install — Toolkit Setup

You are installing the Moberg Claude Code toolkit. This command places commands,
agents, settings, and references into the correct location so the engineer can
use `/project:moberg-*` or `/user:moberg-*` commands.

## STEP 1: DETERMINE INSTALL MODE

If the argument includes `--global` or `--project`, use that. Otherwise, ask:

> **Where should I install the moberg toolkit?**
>
> 1. **Global (user-level)** — Install commands and agents to `~/.claude/`.
>    Available as `/user:moberg-*` in every repo. Recommended for individual use.
>
> 2. **Project (repo-level)** — Install everything to this repo's `.claude/`.
>    Available as `/project:moberg-*` in this repo only. Recommended for team repos
>    where the toolkit should be committed and shared.
>
> Which do you prefer? (1 or 2)

Wait for the engineer's response before proceeding.

## STEP 2: DETERMINE SOURCE

Find the toolkit source, in priority order:

1. **Current directory**: If the current directory IS the claude-helpers repo
   (check for `.claude/manifest.json` with `"source": "https://github.com/moberghr/claude-helpers"`),
   use local files directly.

2. **Environment variable**: If `MOBERG_HELPERS_PATH` is set and valid, use that.
   ```bash
   echo $MOBERG_HELPERS_PATH
   ```

3. **GitHub**: Fetch from `https://raw.githubusercontent.com/moberghr/claude-helpers/main/.claude/`

If none work, tell the engineer:
> "Cannot reach the toolkit source. Options:
> - Clone the repo: `git clone git@github.com:moberghr/claude-helpers.git ~/Dev/claude-helpers`
> - Then either set `MOBERG_HELPERS_PATH=~/Dev/claude-helpers` or cd into it and re-run."

## STEP 3: FETCH MANIFEST

Read/fetch `manifest.json` from the source. Parse the file list and version.

```bash
# From GitHub:
curl -sL https://raw.githubusercontent.com/moberghr/claude-helpers/main/.claude/manifest.json

# Or from local:
cat $SOURCE_PATH/.claude/manifest.json
```

## STEP 4: INSTALL FILES

### Global install (`~/.claude/`)

For each file in `manifest.files`:

| File type | Source key pattern | Target |
|-----------|-------------------|--------|
| Commands | `commands/*.md` | `~/.claude/commands/{filename}` |
| Agents | `agents/*.md` | `~/.claude/agents/{filename}` |
| Settings | `settings.json` | `~/.claude/settings.json` (MERGE) |
| References | `references/*.md` | Skip — these are project-specific |

**Settings merge strategy** (same as moberg-update):
- If `~/.claude/settings.json` exists, merge:
  - `permissions.deny`: union
  - `permissions.allowedTools`: union
  - `hooks`: upstream wins
- If it doesn't exist, write directly
- **Never overwrite `~/.claude/settings.local.json`**

**Create directories if needed:**
```bash
mkdir -p ~/.claude/commands ~/.claude/agents
```

**Write version marker:**
```bash
echo "[version]" > ~/.claude/.moberg-version
```

### Project install (`<repo>/.claude/`)

For each file in `manifest.files`:
- Read the `target` field from the manifest entry
- Fetch the source file
- Write to the target path

This is identical to what `moberg-update` does. Follow the same sync/merge logic:
- **sync** files: overwrite
- **merge** files (settings.json): merge as described above
- **protected** files: never touch

**Create directories if needed:**
```bash
mkdir -p .claude/commands .claude/agents .claude/references
```

**Write version marker:**
```bash
echo "[version]" > .claude/.moberg-version
```

## STEP 5: VERIFY

Check that files were written correctly:

### For global install:
```bash
ls ~/.claude/commands/moberg-*.md
ls ~/.claude/agents/*.md
```

### For project install:
```bash
ls .claude/commands/moberg-*.md
ls .claude/agents/*.md
ls .claude/references/*.md
```

## STEP 6: REPORT

### Global install report:
```
MOBERG TOOLKIT INSTALLED (global)

Version: v[version]
Location: ~/.claude/

Installed:
  Commands: [N] files → ~/.claude/commands/
  Agents:   [N] files → ~/.claude/agents/
  Settings: ~/.claude/settings.json [created | merged]

Commands are now available in ALL repos as:
  /user:moberg-init       — Bootstrap a repo (generates CLAUDE.md + references)
  /user:moberg-implement  — Full feature implementation loop
  /user:moberg-fix        — Lightweight fix/task
  /user:moberg-update     — Update the toolkit
  /user:moberg-scan       — Extract architecture principles
  /user:moberg-merge      — Unify architecture scans
  /user:quick-check       — Pre-commit security scan

Next steps:
  1. Open any project repo in Claude Code
  2. Run /user:moberg-init to bootstrap it
  3. Start building with /user:moberg-implement
```

### Project install report:
```
MOBERG TOOLKIT INSTALLED (project)

Version: v[version]
Location: .claude/

Installed:
  Commands:   [N] files → .claude/commands/
  Agents:     [N] files → .claude/agents/
  References: [N] files → .claude/references/
  Settings:   .claude/settings.json [created | merged]

Commands are available in THIS repo as:
  /project:moberg-init       — Bootstrap (generates CLAUDE.md)
  /project:moberg-implement  — Full feature implementation loop
  /project:moberg-fix        — Lightweight fix/task
  /project:moberg-update     — Update the toolkit
  /project:moberg-scan       — Extract architecture principles
  /project:moberg-merge      — Unify architecture scans
  /project:quick-check       — Pre-commit security scan

Next steps:
  1. Run /project:moberg-init to generate CLAUDE.md for this repo
  2. Commit .claude/ to share with the team: git add .claude/ && git commit -m "chore: add moberg toolkit"
  3. Start building with /project:moberg-implement
```

## IMPORTANT

- **Never overwrite existing files without showing what changed** (unless --auto)
- **Always create directories before writing files**
- **Settings are always merged, never overwritten** — the engineer may have local additions
- **References are project-specific** — skip them for global install
- For global install, remind the engineer that per-project setup (moberg-init) is still needed
- If files already exist at the target, show the version diff and ask to proceed (unless --auto or --force)
