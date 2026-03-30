---
description: Merge architecture principles from multiple repo scans into a unified document. Place individual scan outputs in .claude/references/scans/ then run this command.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
---

# Moberg Merge — Unify Architecture Across Projects

You have scanned multiple repositories with `/project:moberg-scan` and now need a
single, unified architecture principles document.

## Input

Read all files in `.claude/references/scans/`:
```bash
ls -la .claude/references/scans/
```

Each file is an architecture scan from a different project (e.g., `payfac.md`,
`collection-system.md`, `bnpl.md`).

If the directory is empty or doesn't exist, tell the engineer:
> "No scan files found. To use this command:
> 1. Run `/project:moberg-scan` in each repo (payfac, collection-system, etc.)
> 2. Copy each generated `architecture-principles.md` into this repo at:
>    `.claude/references/scans/payfac.md`
>    `.claude/references/scans/collection-system.md`
>    etc.
> 3. Run `/project:moberg-merge` again."

## Analysis

For each section of the architecture doc, compare across all scans:

### What's Consistent (standardize on this)
- Patterns used the same way across all projects → these are your team's actual standards
- Same tools and frameworks → these are your tech stack

### What's Different (team needs to decide)
- Different patterns for the same concern → flag as "needs alignment"
- Different conventions → flag with a recommendation

### What's Unique (project-specific)
- Patterns that only appear in one project → document as project-specific, not team-wide

## Output

Generate `.claude/references/architecture-principles.md`:

```markdown
# Moberg Architecture Principles

> Unified from scans of: [list repos]
> Generated: [date]
>
> This document defines team-wide architectural standards.
> Project-specific patterns are noted where they differ.

---

## Team-Wide Standards
[Patterns consistent across ALL scanned projects]

## Recommended Alignments
⚠️ [Patterns that differ between projects — with recommendation on which to standardize]

## Project-Specific Patterns
### PayFac
[Unique patterns]
### Collection System
[Unique patterns]
[etc.]
```

Present the unified doc and highlight the key decisions the team needs to make.
