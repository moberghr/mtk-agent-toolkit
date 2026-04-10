# claude-helpers

Shared Claude Code toolkit for consistent AI-assisted development across Moberg HR.

**Quick start** — install via the Claude Code plugin marketplace:

```
/plugin marketplace add moberghr/claude-helpers
/plugin install moberg-toolkit@moberghr
```

Then bootstrap your repo: `/moberg-toolkit:moberg-init`

---

This repository is the single source of truth for commands, agents, settings, and references that get distributed to all Moberg project repositories. It grows over time as the team adds new skills, plugins, and knowledge.

## What's Inside

| Type | Path | Description |
|------|------|-------------|
| Command | `commands/moberg-implement.md` | Full feature loop: plan → implement → verify → review → fix → cleanup → learn |
| Command | `commands/moberg-fix.md` | Lightweight fix/task — skip planning and review for small changes |
| Command | `commands/moberg-init.md` | Bootstrap a repo — scans codebase, pulls guidelines, generates CLAUDE.md |
| Command | `commands/quick-check.md` | Fast pre-commit security review |
| Command | `commands/moberg-scan.md` | Extract architecture principles from a codebase |
| Command | `commands/moberg-merge.md` | Unify architecture scans from multiple repos into one document |
| Command | `commands/moberg-install.md` | Install toolkit manually — globally for user or locally for a project |
| Command | `commands/moberg-update.md` | Pull latest toolkit (manual installs only — plugin handles this automatically) |
| Agent | `agents/compliance-reviewer.md` | Adversarial code reviewer for fintech compliance (96-item checklist) |
| Reference | `references/coding-guidelines.md` | Moberg C# coding style guide |
| Settings | `settings.json` | Shared permissions, hooks, and tool configuration |
| Plugin | `.claude-plugin/plugin.json` | Plugin manifest for marketplace distribution |
| Plugin | `.claude-plugin/marketplace.json` | Marketplace catalog |
| Manifest | `manifest.json` | Distribution manifest for manual installs — defines what gets synced and how |

All files live under `.claude/` and get distributed via the Claude Code plugin marketplace or manually into each project's `.claude/` directory.

## Installation

### Option A: Plugin Marketplace (recommended)

The fastest way. Two commands in Claude Code:

```
/plugin marketplace add moberghr/claude-helpers
/plugin install moberg-toolkit@moberghr
```

This installs all commands, agents, and settings. Commands appear as `/moberg-toolkit:moberg-implement`, `/moberg-toolkit:moberg-fix`, etc.

To update later:

```
/plugin update moberg-toolkit@moberghr
```

### Option B: Manual install (more control)

For teams that want to commit the toolkit to each repo or need the settings merge behavior.

| Mode | Location | Commands appear as | Best for |
|------|----------|-------------------|----------|
| **Global** | `~/.claude/` | `/user:moberg-*` | Individual engineers — available in every repo |
| **Project** | `<repo>/.claude/` | `/project:moberg-*` | Team repos — committed and shared with the team |

Clone and run the install command:

```bash
git clone git@github.com:moberghr/claude-helpers.git ~/Dev/claude-helpers
```

Then open Claude Code in the cloned repo and run:

```
/project:moberg-install
```

This walks you through the interactive flow — choose global or project, review files, install.

Optionally set the environment variable for offline updates:

```bash
# Add to your shell profile (~/.zshrc or ~/.bashrc)
export MOBERG_HELPERS_PATH=~/Dev/claude-helpers
```

### After installation

Bootstrap your project repo (required for both install methods):

```
/moberg-toolkit:moberg-init        # if you used the plugin
/user:moberg-init                  # if you installed globally
/project:moberg-init               # if you installed per-project
```

This scans your codebase, fetches coding guidelines, and generates a tailored `CLAUDE.md` with numbered rules that the implementation and review commands reference.

### Start building

```
/moberg-toolkit:moberg-implement Add payment reconciliation endpoint
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

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guide on adding commands, agents, references, and writing effective anti-rationalization tables.

## Repo Structure

```
claude-helpers/
  .claude-plugin/
    plugin.json                            # Plugin manifest (for marketplace distribution)
    marketplace.json                       # Marketplace catalog
  .claude/
    manifest.json                          # Distribution manifest (for manual install — version, files, protected list)
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
  CONTRIBUTING.md                          # Guide for extending the toolkit
  README.md
```

## Distribution Models

This toolkit supports two distribution paths that coexist:

| | Plugin Marketplace | Manual (manifest) |
|---|---|---|
| **Install** | `/plugin marketplace add moberghr/claude-helpers` | `/project:moberg-install` |
| **Update** | `/plugin update moberg-toolkit@moberghr` | `/project:moberg-update` |
| **Settings** | Delivered as-is | Merged (union deny lists, preserve local additions) |
| **Versioning** | Automatic via plugin cache | Manual via `.moberg-version` marker |
| **Best for** | Quick onboarding, individual engineers | Team repos needing committed config |

Both read from the same source files. Bump `version` in both `plugin.json` and `manifest.json` when releasing.

## Roadmap

This repo is designed to grow. Planned additions:

- **Skills** — reusable prompt templates for common tasks (PR descriptions, release notes, incident summaries)
- **MCP servers** — shared MCP server configurations for team tools
- **Hooks** — shared pre/post-commit hooks for quality gates
- **Project templates** — starter CLAUDE.md templates for different project types (API, Lambda, CDK)
