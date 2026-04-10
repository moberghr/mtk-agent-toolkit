---
description: Pull latest moberg toolkit (commands, skills, agents, settings) from the central claude-helpers repo. Run periodically or when notified of updates.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
argument-hint: [--auto] [--force]
---

# Moberg Update — Sync Toolkit from Central Repo

Pull the latest commands, skills, agents, settings, references, and routing assets from the moberg
`claude-helpers` repository into this project's `.claude/` directory.

## SOURCE RESOLUTION

Determine the source for upstream files, in priority order:

1. **Environment variable**: If `MOBERG_HELPERS_PATH` is set, use that local path.
   ```bash
   echo $MOBERG_HELPERS_PATH
   ```

2. **GitHub raw files**: Fetch from `https://raw.githubusercontent.com/moberghr/claude-helpers/main/`

If neither works (no env var, network restricted), tell the engineer:
> "Cannot reach the claude-helpers repo. Either:
> - Set MOBERG_HELPERS_PATH to a local clone: `export MOBERG_HELPERS_PATH=~/Dev/claude-helpers`
> - Or ensure network access to github.com"

## PHASE 1: FETCH MANIFEST

Fetch `manifest.json` from the source.

```bash
# From GitHub:
curl -sL https://raw.githubusercontent.com/moberghr/claude-helpers/main/.claude/manifest.json

# Or from local path:
cat $MOBERG_HELPERS_PATH/.claude/manifest.json
```

Parse the manifest. Read the local version from `.claude/.moberg-version` (if it exists).

If versions match and `--force` is not set:
> "Already up to date (v[version]). Use `--force` to re-fetch anyway."

## PHASE 2: DIFF

For each file in `manifest.files`:

1. Fetch the upstream version (to memory, NOT to disk yet).
   **Path mapping:** use the manifest entry's `source` field.
   When fetching:
   - GitHub: `https://raw.githubusercontent.com/moberghr/claude-helpers/main/{source}`
   - Local: `$MOBERG_HELPERS_PATH/{source}`
2. Read the local version at the `target` path (if it exists)
3. Compare and classify:
   - **unchanged** — identical content
   - **updated** — upstream differs from local
   - **new** — exists upstream, not locally
   - **local-only** — exists locally, not in manifest (warn, don't delete)

Also check the `protected` list from the manifest — these files are NEVER touched:
- `.claude/settings.local.json`
- `CLAUDE.md`
- `tasks/lessons.md`
- `tasks/todo.md`
- `.claude/references/architecture-principles.md`
- `.claude/references/quick-check-list.md`

### Show summary:

```
update: v[old] → v[new]

Will update (upstream changed):
  .claude/commands/implement.md  ([old-lines] → [new-lines] lines)
  .claude/agents/compliance-reviewer.md ([old-lines] → [new-lines] lines)

Will add (new in upstream):
  .claude/commands/new-command.md

Unchanged:
  .claude/commands/quick-check.md
  .claude/references/coding-guidelines.md

Protected (never touched):
  CLAUDE.md
  .claude/settings.local.json
  tasks/lessons.md

Local-only (not in upstream — review manually):
  .claude/commands/custom-local-command.md
```

If nothing to update:
> "All files are up to date."

## PHASE 3: APPLY

### Check for --auto flag
If `--auto` is set, apply immediately. Otherwise, use AskUserQuestion:

```
question: "Apply these updates?"
header: "Update"
options:
  - label: "Yes, apply all"
    description: "Apply all listed updates to local files"
  - label: "Show diffs first"
    description: "Show the full diff for each changed file before applying"
  - label: "Cancel"
    description: "Don't apply any changes"
```

If the engineer picks "Show diffs first", display the diffs and then ask again with just "Apply" and "Cancel".

### For each file classified as `updated` or `new`:

**If action is `sync`** (commands, skills, agents, references, root assets):
- Overwrite the local file with the upstream version

**If action is `merge`** (settings.json):
- Read local `.claude/settings.json`
- Read upstream `settings.json`
- Merge strategy:
  - `permissions.deny`: **union** — upstream deny rules cannot be removed locally
  - `permissions.allowedTools`: **union** — keep both upstream and local additions
  - `hooks`: **upstream wins** — hooks are integral to command behavior
  - Any other keys: **upstream wins** unless local has custom additions
- Show the merged result before writing (unless --auto)

### For files classified as `local-only`:
- Do NOT delete
- Warn: "File [path] exists locally but is not in the upstream manifest. Review manually."

### Write version
Write the new version to `.claude/.moberg-version`:
```
[version]
```

## PHASE 4: POST-UPDATE

1. **Verify build** (if this is a .NET project):
   ```bash
   dotnet build 2>&1 | tail -5
   ```
   If build fails, the update may have changed hooks that affect the build. Report the error.

2. **Check CLAUDE.md compatibility**:
   If CLAUDE.md exists, scan the updated commands for §X.Y rule references.
   If any referenced rules don't exist in CLAUDE.md, warn:
   > "Updated commands reference §X.Y rules not found in CLAUDE.md.
   > Consider running `/moberg:init` to regenerate CLAUDE.md."

3. **Report**:
```
MOBERG UPDATE COMPLETE

Version: v[old] → v[new]
Updated: [N] files
Added:   [N] files
Merged:  settings.json [if applicable]

Next steps:
  - Review changes: git diff
  - If CLAUDE.md is outdated: /moberg:init
  - Commit: git add .claude/ && git commit -m "chore: update moberg toolkit to v[new]"
```

---

## IMPORTANT
- **Never touch protected files** — especially CLAUDE.md, settings.local.json, and lessons.md
- **Never delete local-only files** — they may be project-specific customizations
- **Show merge results** before writing settings.json (unless --auto)
- **The manifest.json in the source repo is the single source of truth** for what gets distributed
