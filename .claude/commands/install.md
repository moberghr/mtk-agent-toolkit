---
description: Install the moberg toolkit — globally for user or locally for a project. Handles first-time setup and re-installation.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
argument-hint: [--global | --project] [--auto]
---

# Moberg Install — Toolkit Setup

You are installing the Moberg Claude Code toolkit. This command places commands,
skills, agents, settings, references, and routing assets into the correct location so the engineer can
use `/moberg:*` commands.

## STEP 1: DETERMINE INSTALL MODE

If the argument includes `--global` or `--project`, use that. Otherwise, use AskUserQuestion:

```
question: "Where should I install the moberg toolkit?"
header: "Install mode"
options:
  - label: "Global (user-level) (Recommended)"
    description: "Install commands and agents to ~/.claude/. Available as /moberg:* in every repo. Best for individual use."
  - label: "Project (repo-level)"
    description: "Install everything to this repo's .claude/. Available as /moberg:* in this repo only. Best for team repos where the toolkit should be committed."
```

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

3. **GitHub**: Fetch from `https://raw.githubusercontent.com/moberghr/claude-helpers/main/`

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
| Skills | `skills/*/SKILL.md` | `~/.claude/skills/{skill-name}/SKILL.md` |
| Agents | `agents/*.md` | `~/.claude/agents/{filename}` |
| Settings | `settings.json` | `~/.claude/settings.json` (MERGE) |
| References | `references/*.md` | Skip — these are project-specific |
| Root assets | `AGENTS.md`, `docs/*`, `scripts/*` | Skip — these are project/project-tooling assets |

**Settings merge strategy** (same as update):
- If `~/.claude/settings.json` exists, merge:
  - `permissions.deny`: union
  - `permissions.allowedTools`: union
  - `hooks`: upstream wins
- If it doesn't exist, write directly
- **Never overwrite `~/.claude/settings.local.json`**

**Create directories if needed:**
```bash
mkdir -p ~/.claude/commands ~/.claude/agents ~/.claude/skills
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

This is identical to what `update` does. Follow the same sync/merge logic:
- **sync** files: overwrite
- **merge** files (settings.json): merge as described above
- **protected** files: never touch

**Create directories if needed:**
```bash
mkdir -p .claude/commands .claude/agents .claude/references .claude/skills docs scripts
```

**Write version marker:**
```bash
echo "[version]" > .claude/.moberg-version
```

## STEP 5: VERIFY

Check that files were written correctly:

### For global install:
```bash
ls ~/.claude/commands/*.md
ls ~/.claude/agents/*.md
```

### For project install:
```bash
ls .claude/commands/*.md
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
  Skills:   [N] files → ~/.claude/skills/
  Agents:   [N] files → ~/.claude/agents/
  Settings: ~/.claude/settings.json [created | merged]

Commands are now available in ALL repos as:
  /moberg:init       — Bootstrap a repo (generates CLAUDE.md + references)
  /moberg:implement  — Full feature implementation loop
  /moberg:fix        — Lightweight fix/task
  /moberg:update     — Update the toolkit
  /moberg:scan       — Extract architecture principles
  /moberg:merge      — Unify architecture scans
  /moberg:quick-check       — Pre-commit security scan

Next steps:
  1. Open any project repo in Claude Code
  2. Run /moberg:init to bootstrap it
  3. Start building with /moberg:implement
```

### Project install report:
```
MOBERG TOOLKIT INSTALLED (project)

Version: v[version]
Location: .claude/

Installed:
  Commands:   [N] files → .claude/commands/
  Skills:     [N] files → .claude/skills/
  Agents:     [N] files → .claude/agents/
  References: [N] files → .claude/references/
  Settings:   .claude/settings.json [created | merged]
  Routing:    AGENTS.md [project install]

Commands are available in THIS repo as:
  /moberg:init       — Bootstrap (generates CLAUDE.md)
  /moberg:implement  — Full feature implementation loop
  /moberg:fix        — Lightweight fix/task
  /moberg:update     — Update the toolkit
  /moberg:scan       — Extract architecture principles
  /moberg:merge      — Unify architecture scans
  /moberg:quick-check       — Pre-commit security scan

Next steps:
  1. Run /moberg:init to generate CLAUDE.md for this repo
  2. Commit .claude/ to share with the team: git add .claude/ && git commit -m "chore: add moberg toolkit"
  3. Start building with /moberg:implement
```

## IMPORTANT

- **Never overwrite existing files without showing what changed** (unless --auto)
- **Always create directories before writing files**
- **Settings are always merged, never overwritten** — the engineer may have local additions
- **References are project-specific** — skip them for global install
- **Skills are reusable workflow assets** — install them globally and per-project
- **Root-level assets like `AGENTS.md` are project-only** unless explicitly designed for user scope
- For global install, remind the engineer that per-project setup (init) is still needed
- If files already exist at the target, show the version diff and use AskUserQuestion to ask whether to proceed (unless --auto or --force):
  ```
  question: "Files already exist at the target (version [old] → [new]). Proceed with install?"
  header: "Overwrite"
  options:
    - label: "Yes, proceed"
      description: "Overwrite existing files with the new version"
    - label: "Cancel"
      description: "Keep existing files unchanged"
  ```
