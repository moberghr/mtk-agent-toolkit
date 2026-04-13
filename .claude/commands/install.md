---
description: Install or update MTK — globally for the user (~/.claude/) or locally for a project (./.claude/). Idempotent: detects an existing install and switches to update mode automatically.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
argument-hint: [--global | --project] [--auto] [--force]
---

# MTK Install — Toolkit Setup (Idempotent)

This single command handles **first-time install** and **subsequent updates**.

If `.mtk-version` already exists at the target, it switches into **UPDATE MODE** (diff + apply, respecting protected files). Otherwise, it runs **INSTALL MODE** (fresh install of the full file set).

Use `--force` to re-fetch even when versions match. Use `--auto` to skip approval prompts.

---

## STEP 1: DETERMINE INSTALL MODE (Global vs Project)

If the argument includes `--global` or `--project`, use that. Otherwise, use AskUserQuestion:

```
question: "Where should I install MTK?"
header: "Install mode"
options:
  - label: "Global (user-level) (Recommended)"
    description: "Install commands and agents to ~/.claude/. Available as /mtk:* in every repo. Best for individual use."
  - label: "Project (repo-level)"
    description: "Install everything to this repo's .claude/. Available as /mtk:* in this repo only. Best for team repos where the toolkit should be committed."
```

Wait for the engineer's response before proceeding.

Set `TARGET_DIR`:
- Global: `~/.claude`
- Project: `./.claude`

## STEP 2: DETERMINE SOURCE

Find the toolkit source, in priority order:

1. **Current directory**: If the current directory IS the claude-helpers repo (check for `.claude/manifest.json` with `"source": "https://github.com/moberghr/claude-helpers"`), use local files directly.
2. **Environment variable**: If `MTK_HELPERS_PATH` is set and valid, use that.
   ```bash
   echo $MTK_HELPERS_PATH
   ```
3. **GitHub**: Fetch from `https://raw.githubusercontent.com/moberghr/claude-helpers/main/`

If none work, tell the engineer:
> "Cannot reach the toolkit source. Options:
> - Clone the repo: `git clone git@github.com:moberghr/claude-helpers.git ~/Dev/claude-helpers`
> - Then either set `MTK_HELPERS_PATH=~/Dev/claude-helpers` or cd into it and re-run."

## STEP 3: FETCH MANIFEST + DETECT EXISTING INSTALL

Read/fetch `manifest.json` from the source. Parse the file list and version.

```bash
# From GitHub:
curl -sL https://raw.githubusercontent.com/moberghr/claude-helpers/main/.claude/manifest.json

# Or from local:
cat $SOURCE_PATH/.claude/manifest.json
```

Check for an existing install at `TARGET_DIR/.mtk-version`:
- If it exists → set `MODE=update`, read the local version
- If it doesn't exist → set `MODE=install`

If `MODE=update` and the local version equals the upstream version and `--force` is not set:
> "Already up to date (v[version]). Use `--force` to re-fetch anyway."
> Exit cleanly.

## STEP 4: PLAN CHANGES

For each file in `manifest.files`:

1. Fetch the upstream version (to memory, not disk).
   - GitHub: `https://raw.githubusercontent.com/moberghr/claude-helpers/main/{source}`
   - Local: `$SOURCE_PATH/{source}`
2. Read the local version at the `target` path (if it exists).
3. Classify:
   - **unchanged** — identical content (skip)
   - **updated** — upstream differs from local (apply)
   - **new** — exists upstream, not locally (apply)
   - **local-only** — exists locally, not in manifest (warn, never delete)

For **global install**, restrict the file set:
- Apply: commands, skills, agents, settings (merge)
- Skip: references (project-specific), root assets (`AGENTS.md`, `docs/*`, `scripts/*`, `tests/*`, hooks)

For **project install**, apply every entry per the manifest's `target` field.

Always honor the `protected` list from the manifest — these files are NEVER touched in either mode:
- `.claude/settings.local.json`
- `.claude/tech-stack`
- `CLAUDE.md`
- `tasks/lessons.md`
- `tasks/todo.md`
- `.claude/references/architecture-principles.md`
- `.claude/references/quick-check-list.md`

### Show plan summary

```
[install | update]: [— → v[new] | v[old] → v[new]]
Mode: [global | project]
Target: [TARGET_DIR]

Will apply (updated):
  .claude/commands/implement.md  ([old-lines] → [new-lines] lines)
  .claude/agents/compliance-reviewer.md ([old-lines] → [new-lines] lines)

Will add (new):
  .claude/skills/handoff/SKILL.md

Unchanged:
  .claude/commands/quick-check.md

Protected (never touched):
  CLAUDE.md
  .claude/settings.local.json
  tasks/lessons.md

Local-only (not in upstream — review manually):
  .claude/commands/custom-local-command.md
```

If nothing to apply and `--force` is not set:
> "All files are up to date."

## STEP 5: APPROVE

If `--auto` is set, apply immediately. Otherwise use AskUserQuestion:

```
question: "Apply these changes?"
header: "[Install | Update]"
options:
  - label: "Yes, apply all"
    description: "Apply the listed changes"
  - label: "Show diffs first"
    description: "Show full diffs for changed files before applying"
  - label: "Cancel"
    description: "Don't apply any changes"
```

If "Show diffs first": display unified diffs for each `updated` file, then re-prompt with just "Apply" / "Cancel".

## STEP 6: APPLY

**Create directories first:**
```bash
# Global
mkdir -p ~/.claude/commands ~/.claude/agents ~/.claude/skills

# Project
mkdir -p .claude/commands .claude/agents .claude/references .claude/skills docs scripts hooks tests/pressure-tests
```

**For each `updated` or `new` entry, apply per `action`:**

- `sync` (commands, skills, agents, references, root assets): overwrite the target with the upstream version.
- `merge` (settings.json):
  - `permissions.deny`: **union** — upstream deny rules cannot be removed locally
  - `permissions.allowedTools`: **union** — keep both upstream and local additions
  - `hooks`: **upstream wins** — hooks are integral to command behavior
  - Any other keys: **upstream wins** unless local has custom additions
  - Show the merged result before writing (unless `--auto`)

**Local-only files:** never delete. Print a one-line warning per file.

**Write the version marker:**
```bash
# Global
echo "[version]" > ~/.claude/.mtk-version

# Project
echo "[version]" > .claude/.mtk-version
```

## STEP 7: POST-APPLY VERIFICATION

For project install/update only:

1. **Build sanity check** — run the active tech stack's compile-equivalent command. Read `.claude/tech-stack` and pick:
   ```bash
   case "$(cat .claude/tech-stack 2>/dev/null)" in
     dotnet) dotnet build 2>&1 | tail -5 ;;
     python) (mypy . 2>&1 || pyright 2>&1) | tail -5 ;;
     typescript)
       PM="$(cat .claude/tech-stack-pm 2>/dev/null || echo npm)"
       ("$PM" run typecheck 2>&1 || npx tsc --noEmit 2>&1) | tail -5 ;;
     *) echo "No tech stack configured; skipping build sanity check" ;;
   esac
   ```
   If the check fails, the change may have touched hooks. Report the error.

2. **CLAUDE.md compatibility:**
   If `CLAUDE.md` exists, scan the applied commands for `§X.Y` rule references. If any referenced rules don't exist in `CLAUDE.md`, warn:
   > "Updated commands reference §X.Y rules not found in CLAUDE.md. Consider running `/mtk:init` to regenerate CLAUDE.md."

## STEP 8: REPORT

### First-time install report:
```
MTK INSTALLED ([global | project])

Version: v[version]
Location: [TARGET_DIR]

Installed:
  Commands:   [N] files
  Skills:     [N] files
  Agents:     [N] files
  References: [N] files                   # project only
  Settings:   .claude/settings.json [created | merged]

Commands now available:
  /mtk:init        — Bootstrap a repo (generates CLAUDE.md + references)
  /mtk:implement   — Full feature implementation loop
  /mtk:fix         — Lightweight fix/task
  /mtk:scan        — Extract architecture (add --merge to unify multi-repo scans)
  /mtk:install     — Re-run to update (idempotent)
  /mtk:quick-check — Pre-commit security scan
  /mtk:validate    — Toolkit health and structural validation

Next steps:
  1. Run /mtk:init to bootstrap this repo (generates CLAUDE.md from your codebase)
  2. Project install: commit .claude/ to share with the team
  3. Start building with /mtk:implement
```

### Update report:
```
MTK UPDATED

Version: v[old] → v[new]
Mode: [global | project]
Target: [TARGET_DIR]

Updated: [N] files
Added:   [N] files
Merged:  settings.json [if applicable]
Skipped: [N] unchanged
Warning: [N] local-only files (review manually)

Next steps:
  - Review changes: git diff
  - If CLAUDE.md is outdated: /mtk:init
  - Commit: git add .claude/ && git commit -m "chore: update MTK to v[new]"
```

---

## IMPORTANT

- **Idempotent:** safe to re-run. Detects existing install via `.mtk-version`.
- **Never overwrite protected files** — especially `CLAUDE.md`, `settings.local.json`, `lessons.md`, `tech-stack`, `architecture-principles.md`, `quick-check-list.md`
- **Never delete local-only files** — they may be project-specific customizations
- **Settings are always merged, never overwritten** — the engineer may have local additions
- **References are project-specific** — skip them for global install
- **Show diffs / merge results** before writing (unless `--auto`)
- The `manifest.json` in the source repo is the single source of truth for what gets distributed
