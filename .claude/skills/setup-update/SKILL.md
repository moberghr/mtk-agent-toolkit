---
name: setup-update
description: Update a bootstrapped repo to the latest MTK version — syncs non-protected files, merges settings, preserves local customizations.
type: skill
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion
argument-hint: "[--preview] [--source <path>]"
user-invocable: true
---

# MTK Update

## MTK File Resolution

MTK skills and shared references may be in the project (local install) or the plugin cache (marketplace install). Resolve once before loading any skill:

1. Check: does `.claude/skills/context-engineering/SKILL.md` exist in the project root?
2. If yes → **local install**. All `.claude/skills/` and `.claude/references/` paths work as-is.
3. If no → **marketplace install**. Find the MTK plugin root:
   ```bash
   MTK_ROOTS=$(find ~/.claude/plugins -maxdepth 8 -name "SKILL.md" -path "*/mtk/*/context-engineering/*" -type f 2>/dev/null | sed 's|/.claude/skills/context-engineering/SKILL.md||' | sort -u)
   ```
   If multiple roots are found, warn the engineer: "Multiple MTK plugin versions detected: {paths}. Using the first match. Use `--source <path>` to specify explicitly." Use the first result.
   Prefix all `.claude/skills/...` and `.claude/references/{stack}/...` reads with the resolved root path.
4. If the find returns nothing → MTK skills are unavailable. Warn the engineer and proceed with `CLAUDE.md` only.

**Always project-relative** (never prefixed): `CLAUDE.md`, `.claude/tech-stack`, `.claude/rules/`, `tasks/`, `docs/`, `.claude/references/architecture-principles.md`, `.claude/references/pre-commit-review-list.md`.

---

## Overview

Update a previously bootstrapped repo to the latest MTK version. Syncs non-protected files, merges settings.json intelligently, and preserves local customizations (CLAUDE.md, architecture-principles, lessons, tech-stack).

## When To Use

- When session-start reports "MTK update available"
- After the team ships a new MTK version
- Periodically, to pick up new skills, references, and analyzer configs

## Process

### Phase 1: Version Check

1. Read `.claude/mtk-version.json` in the target repo. If missing, treat as version `0.0.0` (bootstrapped before version tracking).
2. Resolve the MTK source (plugin cache or `--source` override).
3. Read the source `manifest.json` version.
4. If versions match, report "Already up to date (v{version})" and exit.
5. If the target version is **newer** than the source version, warn: "Target repo (v{target}) is newer than source (v{source}). This would downgrade. Aborting." Do NOT apply changes.

### Phase 2: Change Plan

For each file in the source manifest's `files` section:

1. **Protected files** (listed in manifest `protected` array): Skip. Report "Protected, not updated: {path}".
2. **Stack-filtered files** (have a `stack` field): Skip if the stack doesn't match `.claude/tech-stack`. Report "Stack-filtered, skipped: {path}".
3. **Sync files** (`action: "sync"`): Compare source to target.
   - If target doesn't exist: mark for creation.
   - If target exists and differs from source: mark for overwrite.
   - If target matches source: skip (already current).
4. **Protected files with drift**: For files in the `protected` array that also exist in the source manifest, compare source to target.
   - If they differ: show a unified diff so the engineer can manually apply relevant additions.
   - Specifically for `settings.json`: show the diff of new permissions or hooks from the source that the engineer may want to adopt. Do NOT auto-merge — settings contain repo-specific structure (nested matchers, custom hooks, `$schema`) that automated merging cannot safely preserve.

### Phase 3: Approval

Present the change plan:

```
MTK update: {installed_version} → {source_version}

Sync (overwrite):  {count} files
Create (new):      {count} files
Merge:             {count} files
Protected (skip):  {count} files
Stack-skip:        {count} files
Already current:   {count} files
```

If `--preview` flag is set, show the plan and exit without applying.

Otherwise, use AskUserQuestion:
- **[Apply]** — apply all changes
- **[Details]** — list every file and its action before deciding
- **[Cancel]** — abort without changes

### Phase 4: Apply

1. Copy sync files from source to target.
2. Create new files.
3. For protected files with drift (e.g., `settings.json`): display the diff and let the engineer decide which additions to adopt manually.
4. Regenerate `AGENTS.md` by running `bash scripts/generate-agents-md.sh` (if the script exists). This picks up any new or changed references. Custom sections (`## Custom:`) are preserved automatically.
5. Update `.claude/mtk-version.json` with the new version and date.
6. If `CHANGELOG.md` exists in the source, read entries between the installed and current versions and display them.

### Phase 5: Report

List every file touched with a one-line description of the change. Note any files that were protected or stack-filtered.

## Verification

- [ ] Version stamp updated to new version
- [ ] Protected files untouched (settings.json, AGENTS.md, CLAUDE.md, etc.)
- [ ] Settings.json drift shown as diff for manual review (not auto-merged)
- [ ] AGENTS.md regenerated from current references (if generate-agents-md.sh exists)
- [ ] Stack-filtered files skipped for non-matching stacks
- [ ] New files created
