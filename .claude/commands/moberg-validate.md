---
description: Validate the toolkit structure, manifest metadata, and skill anatomy before release.
allowed-tools: Read, Bash, Glob, Grep
---

# Moberg Validate — Toolkit Integrity Check

Validate this repository as a toolkit source of truth.

## Checks

1. `AGENTS.md` exists
2. `.claude/skills/` exists and every `SKILL.md` has the required sections
3. `manifest.json` sources point to real files
4. `plugin.json` version matches `manifest.json`
5. Commands, agents, and skills have frontmatter
6. Shared references named in docs actually exist

## Run

Execute:

```bash
bash scripts/validate-toolkit.sh
```

## Output

- If the script passes, report success.
- If it fails, report the exact missing file or malformed asset.
