---
description: Canonical four-step resolution of the MTK root (MTK_HELPER_ROOT → CLAUDE_PLUGIN_ROOT → local checkout → plugin-cache find) that every entry-point skill applies once before reading MTK skills, references, hooks, or scripts
globs: ["**/*"]
alwaysApply: false
---

# MTK File Resolution

MTK skills, shared references, hooks, and scripts live either in the project (local install) or in the plugin cache (marketplace install). The `/mtk` router resolves the root **once per session** and states it as a single line, `MTK_ROOT=<path>`; a dispatched skill that sees that line uses it and does not re-resolve. Resolve here only when no `MTK_ROOT` has been stated.

## Resolution order

1. If `$MTK_HELPER_ROOT` is set, prefix MTK-owned reads (`.claude/skills/`, `.claude/references/`, `hooks/`, `scripts/`, `.claude/review-config.json`) with it — a pinned checkout wins over every other source.
2. Otherwise, if `$CLAUDE_PLUGIN_ROOT` is set, prefix them with that.
3. Otherwise, if the probe file exists locally → project-relative paths work as-is. Probe: `.claude/skills/context-engineering/SKILL.md` (skill-family callers) or `hooks/pre-commit-linters.sh` (`pre-commit-review`, which needs hooks rather than skills).
4. Otherwise, fall back to the newest plugin-cache copy:

   ```bash
   # skill-family callers
   find ~/.claude/plugins -maxdepth 8 -name "SKILL.md" -path "*/mtk/*/context-engineering/*" -type f 2>/dev/null | sort -V | tail -1 | sed 's|/.claude/skills/context-engineering/SKILL.md||'
   # pre-commit-review
   find ~/.claude/plugins -maxdepth 8 -name "pre-commit-linters.sh" -path "*/mtk/*" -type f 2>/dev/null | sort -V | tail -1 | sed 's|/hooks/pre-commit-linters.sh||'
   ```

   If the result is empty, MTK files are unavailable. Degrade per skill: skill-family callers warn the engineer and proceed with `CLAUDE.md` only; `pre-commit-review` skips the linter pass and runs the AI review only.

## Always project-relative (never prefixed)

`CLAUDE.md`, `.claude/tech-stack`, `.claude/rules/`, `tasks/`, `docs/`, `.claude/references/architecture-principles.md`, `.claude/references/pre-commit-review-list.md`, `.mtk/` (workflow state). These belong to the target repo regardless of where MTK itself is installed.

## One root for skills and scripts

Resolve skills and scripts from the same root. A split (skills from a local dev checkout, scripts from the plugin cache) risks version drift between the instructions and the tooling they invoke — anchor both the same way.

## Companion files

Skills that defer detail to `.claude/references/*.md` companions resolve them through the same root. If a companion cannot be resolved at read time, stop the affected step and report the missing file path — do not reconstruct its content from memory.
