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
   find ~/.claude/plugins -maxdepth 8 -name "SKILL.md" -path "*/mtk/*/context-engineering/*" -type f 2>/dev/null | head -1 | sed 's|/.claude/skills/context-engineering/SKILL.md||'
   ```
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
4. **Merge files** (`action: "merge"`): Compare source to target.
   - For `settings.json`: use `hooks/merge-settings.sh` to compute the merged result.
   - For other merge files: mark for manual review if they differ.

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
3. Run `hooks/merge-settings.sh` for settings.json merges.
4. Update `.claude/mtk-version.json` with the new version and date.
5. If `CHANGELOG.md` exists in the source, read entries between the installed and current versions and display them.

### Phase 5: Report

List every file touched with a one-line description of the change. Note any files that were protected or stack-filtered.

## Verification

- [ ] Version stamp updated to new version
- [ ] Protected files untouched
- [ ] Settings.json merged (not overwritten)
- [ ] Stack-filtered files skipped for non-matching stacks
- [ ] New files created
