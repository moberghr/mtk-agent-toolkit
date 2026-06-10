---
name: pr-review-mining
description: Mine recurring reviewer-feedback phrases from the last N merged PRs and surface them as suggest-only [MINED:feedback] candidates.
type: skill
license: MIT
compatibility:
  - claude-code
user-invocable: false
---

# PR review mining

## Overview

Wraps `scripts/pr-review-mine.sh` (fetches merged PR review threads via `gh`, clusters repeated reviewer-feedback phrases). Output is always advisory — phrases tagged `[MINED:feedback]` and never auto-edited into `architecture-principles.md`.

## When To Use

- The engineer asks: "what are reviewers asking for repeatedly?", "mine our PRs", "what should we add to our rules?"
- As part of `/mtk repo-health` (periodic readiness report).
- As an optional step inside `setup-audit --mine-prs` to seed `architecture-principles.md` candidates.

### When NOT To Use

- The repo has fewer than 3 merged PRs — not enough signal.
- `gh` is unauthenticated and the engineer is offline — fail-soft will skip with a warning.
- The engineer wants to auto-edit principles — this skill never writes to `architecture-principles.md`.

## Workflow

1. **Pre-flight.** Confirm `gh` is installed and authenticated: `gh auth status >/dev/null 2>&1`. If not, report the warning and stop — do not attempt to fix `gh` auth from inside this skill.
2. **Run the miner.**

   ```bash
   bash scripts/pr-review-mine.sh --prs 10
   ```

   - `--prs N` (default 10, range 1..50) — number of merged PRs to scan.
   - `--json` — machine-readable output to stdout.

3. **Read the canonical patterns reference.** `.claude/references/pr-mining-patterns.md` defines what phrases mean and which are denylisted. If the engineer sees obvious noise (e.g., "looks good to me" sneaks through), append it to the `## Denylist` section of that file and re-run.
4. **Suggest-only.** Present each candidate phrase to the engineer with its PR citations. Do NOT modify `architecture-principles.md` automatically — the engineer must opt in per-phrase, prefixing the resulting principle with `[MINED:feedback]` and citing the PR numbers.
5. **Record the run.** If invoked from `repo-health`, the parent skill emits a "PR mining" section into `.claude/repo-health-latest.md` with the table.

## Verification

- The script exited 0 (mining is always advisory; non-zero only on argument validation error).
- The output references concrete PR numbers (`#<n>`) — fabricated phrases without citations are a red flag.
- No edits were made to `architecture-principles.md`.
- If `gh` was missing or unauthenticated, the output explicitly says `Skipped: <reason>` rather than fabricating phrases.

## Red Flags

| Rationalization | Reality |
|---|---|
| "This phrase appeared once but it's clearly a rule — I'll promote it." | The miner deliberately requires ≥2 distinct PRs. Single-PR feedback is one reviewer's preference, not a team norm. |
| "I'll just write the mined phrase straight into `architecture-principles.md`." | Always tag `[MINED:feedback]` and cite PRs. Untagged mined rules are indistinguishable from extracted ones. |
| "`gh` failed, I'll guess what reviewers usually say." | Mining is fail-soft — when `gh` is unavailable, the output is empty. Do not invent phrases. |
