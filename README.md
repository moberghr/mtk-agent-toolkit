# claude-helpers

Shared Claude Code toolkit for consistent AI-assisted development across Moberg HR.

This repository is the single source of truth for commands, agents, settings, and references that get distributed to all Moberg project repositories. It grows over time as the team adds new skills, plugins, and knowledge.

## What's Inside

| Type | Path | Description |
|------|------|-------------|
| Command | `commands/moberg-install.md` | Install toolkit — globally for user or locally for a project |
| Command | `commands/moberg-init.md` | Bootstrap a repo — scans codebase, pulls guidelines, generates CLAUDE.md |
| Command | `commands/moberg-implement.md` | Full feature loop: plan → implement → verify → review → fix → cleanup → learn |
| Command | `commands/moberg-scan.md` | Extract architecture principles from a codebase |
| Command | `commands/moberg-merge.md` | Unify architecture scans from multiple repos into one document |
| Command | `commands/moberg-fix.md` | Lightweight fix/task — skip planning and review for small changes |
| Command | `commands/moberg-update.md` | Pull latest toolkit into a project repo |
| Command | `commands/quick-check.md` | Fast pre-commit security review |
| Agent | `agents/compliance-reviewer.md` | Adversarial code reviewer for fintech compliance (96-item checklist) |
| Reference | `references/coding-guidelines.md` | Moberg C# coding style guide |
| Settings | `settings.json` | Shared permissions, hooks, and tool configuration |
| Manifest | `manifest.json` | Distribution manifest — defines what gets synced and how |

All files live under `.claude/` and get distributed into each project's `.claude/` directory.

## Installation

The toolkit can be installed in two ways:

| Mode | Location | Commands appear as | Best for |
|------|----------|-------------------|----------|
| **Global** | `~/.claude/` | `/user:moberg-*` | Individual engineers — available in every repo |
| **Project** | `<repo>/.claude/` | `/project:moberg-*` | Team repos — committed and shared with the team |

Both modes work identically. The only difference is scope and how commands are invoked.

### Option A: Ask Claude to install it (recommended)

Open Claude Code in any directory and paste this:

```
Install the moberg Claude Code toolkit from https://github.com/moberghr/claude-helpers.
Fetch .claude/manifest.json from the repo's main branch, then install all commands,
agents, and settings listed in it.

Ask me whether I want global install (~/.claude/) or project install (.claude/ in this repo).

For each file in manifest.files:
- Fetch from: https://raw.githubusercontent.com/moberghr/claude-helpers/main/.claude/{key}
- Commands (commands/*.md) → target commands/ directory
- Agents (agents/*.md) → target agents/ directory
- Settings (settings.json) → merge into existing settings.json (union permissions, don't overwrite)
- References (references/*.md) → target references/ directory (project install only)

Create directories as needed. Show me what will be installed before writing files.
After install, tell me to run moberg-init in my project repo to generate CLAUDE.md.
```

Claude will fetch the manifest, show you what it found, ask where to install, and do the rest.

### Option B: Clone and run the install command

```bash
git clone git@github.com:moberghr/claude-helpers.git ~/Dev/claude-helpers
```

Then open Claude Code in the cloned repo and run:

```
/project:moberg-install
```

This walks you through the same interactive flow — choose global or project, review files, install.

### Option C: Manual setup

```bash
# Clone
git clone git@github.com:moberghr/claude-helpers.git ~/Dev/claude-helpers

# Global install (copy to user-level Claude config)
mkdir -p ~/.claude/commands ~/.claude/agents
cp ~/Dev/claude-helpers/.claude/commands/*.md ~/.claude/commands/
cp ~/Dev/claude-helpers/.claude/agents/*.md ~/.claude/agents/

# OR project install (copy to your repo)
cd /path/to/your/repo
mkdir -p .claude/commands .claude/agents .claude/references
cp ~/Dev/claude-helpers/.claude/commands/*.md .claude/commands/
cp ~/Dev/claude-helpers/.claude/agents/*.md .claude/agents/
cp ~/Dev/claude-helpers/.claude/references/*.md .claude/references/
cp ~/Dev/claude-helpers/.claude/settings.json .claude/settings.json
```

### After installation

Regardless of install method, set up the environment variable for offline updates:

```bash
# Add to your shell profile (~/.zshrc or ~/.bashrc)
export MOBERG_HELPERS_PATH=~/Dev/claude-helpers
```

Then bootstrap your project repo:

```
/user:moberg-init          # if you installed globally
/project:moberg-init       # if you installed per-project
```

This scans your codebase, fetches coding guidelines, and generates a tailored `CLAUDE.md` with numbered rules that the implementation and review commands reference.

### Start building

```
/user:moberg-implement Add payment reconciliation endpoint
# or
/project:moberg-implement Add payment reconciliation endpoint
```

## Command Reference

### `/project:moberg-install`

Interactively installs the toolkit. Asks whether you want global (`~/.claude/`) or project (`.claude/`) installation, fetches all files from the manifest, and places them in the correct location. Supports `--global`, `--project`, and `--auto` flags to skip prompts.

### `/project:moberg-scan`

Analyzes a repository and generates `.claude/references/architecture-principles.md` documenting actual patterns found in the code. Run this in each repo you want to source.

### `/project:moberg-merge`

Takes scan outputs from multiple repos (placed in `.claude/references/scans/`) and produces a unified architecture principles document. Highlights what's consistent, what differs, and what's project-specific.

### `/project:moberg-init`

Bootstraps a repo for the full workflow. Pulls coding guidelines, reads architecture principles, scans the codebase, and generates a comprehensive `CLAUDE.md`. Run once per repo, re-run to merge updates into an existing `CLAUDE.md`.

### `/project:moberg-implement`

The main workhorse. Executes a 9-phase loop:

1. **Bootstrap** — reads CLAUDE.md, coding guidelines, architecture principles, and past lessons
2. **Plan** — produces a detailed executable specification with file-level change manifest
3. **Implement** — executes in batches with build/test checkpoints after each
4. **Verify** — proves correctness with tests, behavioral diff, and staff engineer test
5. **Review** — delegates to the adversarial compliance-reviewer agent
6. **Fix** — addresses review findings (up to 3 iterations)
7. **Cleanup** — behavior-preserving simplification pass
8. **Lessons** — captures patterns and mistakes to `tasks/lessons.md`
9. **Done** — checks CLAUDE.md drift and produces completion report

Supports `--auto` flag for unattended execution.

### `/project:moberg-fix`

The fast path for small, well-scoped changes: bug fixes, validation rules, query tweaks, config changes. Reads standards, implements directly (no plan approval gate), runs build/test, and reports. Has a scope guard — if the change grows beyond 3 files, it stops and recommends switching to `moberg-implement`.

### `/project:moberg-update`

Pulls the latest toolkit from this repo into a project. Compares versions, shows a diff summary, and applies changes. Commands and agents are overwritten (sync), while `settings.json` is merged to preserve local additions. Protected files (CLAUDE.md, lessons.md, architecture-principles.md) are never touched.

### `/project:quick-check`

Lightweight pre-commit security scan. Checks staged changes for hardcoded secrets, SQL injection, PII in logs, missing auth, missing audit trails, and IAM blast radius issues.

## Workflow

### First-time setup

```
One-time:                 Per repo (once):           Per repo (ongoing):
  moberg-install      -->   moberg-init          -->   moberg-implement
  (global or project)       (generate CLAUDE.md)       (build features)
                                                       moberg-fix
                                                       (small fixes)
                                                       moberg-update
                                                       (pull toolkit updates)
```

### Cross-repo pattern extraction (optional)

```
Per repo:                 Central:                   Per repo:
  moberg-scan         -->   moberg-merge         -->   moberg-init
  (extract patterns)        (unify principles)         (regenerate CLAUDE.md)
```

## How Updates Work

This repo uses a manifest-based distribution model defined in `manifest.json`:

- **Sync** files (commands, agents, references) are overwritten with the upstream version
- **Merge** files (settings.json) preserve local additions while upstream controls deny rules and hooks
- **Protected** files (CLAUDE.md, settings.local.json, lessons.md, todo.md, architecture-principles.md) are never modified by updates

When you make changes here, bump the version in `manifest.json`. Engineers pull updates by running `/project:moberg-update` in their repos.

## Contributing

### Adding a new command

1. Create `.claude/commands/your-command.md` with frontmatter:
   ```yaml
   ---
   description: One-line description shown in command list
   allowed-tools: Read, Write, Edit, Bash, Glob, Grep
   ---
   ```
2. Add an entry to `manifest.json` under `files` with `"action": "sync"`
3. Bump the version in `manifest.json`

### Adding a new agent

1. Create `.claude/agents/your-agent.md` with frontmatter:
   ```yaml
   ---
   name: your-agent
   description: What it does and when to use it
   allowed-tools: Read, Glob, Grep, Bash
   model: sonnet
   ---
   ```
2. Add to `manifest.json`
3. Bump the version

### Adding references

Place shared reference documents in `.claude/references/` and add them to the manifest.

### Protected files

If a file should never be overwritten by `moberg-update`, add it to the `protected` array in `manifest.json`.

## Repo Structure

```
claude-helpers/
  .claude/
    manifest.json                          # Distribution manifest (version, files, protected list)
    settings.json                          # Shared permissions, hooks, tool config
    settings.local.json                    # Local overrides (not distributed)
    commands/
      moberg-install.md                    # Install toolkit (global or project)
      moberg-init.md                       # Bootstrap a project repo
      moberg-implement.md                  # Full feature implementation loop
      moberg-scan.md                       # Extract architecture principles
      moberg-merge.md                      # Unify scans across repos
      moberg-fix.md                        # Lightweight fix/task loop
      moberg-update.md                     # Pull latest toolkit
      quick-check.md                       # Pre-commit security scan
    agents/
      compliance-reviewer.md               # Adversarial fintech code reviewer
    references/
      coding-guidelines.md                 # Moberg C# coding style guide
  README.md
```

## Roadmap

This repo is designed to grow. Planned additions:

- **Skills** — reusable prompt templates for common tasks (PR descriptions, release notes, incident summaries)
- **Plugins** — MCP server configurations for team tools
- **Hooks** — shared pre/post-commit hooks for quality gates
- **Project templates** — starter CLAUDE.md templates for different project types (API, Lambda, CDK)
