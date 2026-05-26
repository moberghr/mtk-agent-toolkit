---
name: repo-health
description: Periodic AI-readiness report — scorecard against 12 named assets plus PR review mining from the last N merged PRs.
type: skill
license: MIT
compatibility:
  - claude-code
user-invocable: false
---

# Repo health

## Overview

Single periodic command that combines:

1. The **12-asset readiness scorecard** (`scripts/repo-health-score.sh`) — bounded checklist with `🟩🟨⬜` icons and a medal (🥉🥈🥇🏆).
2. **PR review mining** (`scripts/pr-review-mine.sh`) — repeated reviewer-feedback phrases from the last N merged PRs, suggest-only.
3. A **top-3 actionable changes** summary derived from the two above.

Writes the combined report to `.claude/repo-health-latest.md` (always) and `.claude/repo-health-latest.json` (with `--json`). Both files are gitignored.

Patterns borrowed from `github.com/johnpapa/ai-ready` (scorecard + PR mining).

## When To Use

- The engineer asks: "is this repo AI-ready?", "repo health", "readiness scorecard", "what should we improve?", "mine our PRs".
- As a periodic check (weekly / monthly retro) — no schedule enforcement, run when useful.
- Before a major release — confirm baseline hasn't drifted.
- After running `/mtk-setup --audit` — see whether tagged principles bumped asset #2.

### When NOT To Use

- For toolkit *adoption* analytics (who's using which MTK skills) → that's `toolkit-health`.
- During implementation of a feature — this is a diagnostic, not part of the build loop.
- When a repo is brand new with <3 merged PRs — mining will be empty and the scorecard will mostly fail. Run `/mtk-setup` first.

## Workflow

1. **Parse flags.** Accept:
   - `--prs N` (1..50, default 10) — number of merged PRs the mining step scans.
   - `--json` — also write `.claude/repo-health-latest.json`.
   - `--no-mining` — skip the PR mining step (scorecard only).

2. **Run the scorecard.** Always.

   ```bash
   bash scripts/repo-health-score.sh
   ```

   Capture stdout — this is the first half of the report.

2b. **Run audit-drift check** on stamped docs. Best-effort, non-blocking.

   ```bash
   for doc in CLAUDE.md .claude/references/architecture-principles.md .claude/references/conventions.md; do
     [ -f "$doc" ] || continue
     bash scripts/audit-drift-check.sh "$doc" || true   # exit 1 = drift, captured for report
   done
   ```

   The script reads each doc's `audited-against:` stamp, intersects `git diff --name-only <sha>..HEAD` with file paths cited in the doc, and prints a markdown table of stale citations. If any doc reports drift, the AI Context bucket in the scorecard is annotated `🟨 audit drift: N citations` (do not change `pass` to `fail` — drift is a warning, not a regression).

   Skip silently for unstamped docs (no warning — older audits pre-v7.8.0 have no stamp).

3. **Run PR mining.** Unless `--no-mining` is set.

   ```bash
   bash scripts/pr-review-mine.sh --prs <N>
   ```

   The script is fail-soft: when `gh` is missing or unauthenticated, it emits a `Skipped:` block and exits 0. Capture stdout — this is the second half of the report.

4. **Derive top-3 actionable changes.** Read both outputs:

   - Every `⬜` asset in the scorecard is a candidate.
   - Every mined phrase with ≥3 PR citations is a candidate.

   Rank by: fail in AI Context bucket > fail in Dev Workflow > fail in Onboarding > mined phrase. Pick the top 3, each phrased as a single sentence with the file path or action to take.

5. **Write the report.** Concatenate into `.claude/repo-health-latest.md`:

   ```markdown
   # Repo health report — <ISO date>

   <scorecard output>

   <mining output>

   ## Top 3 actionable changes

   1. ...
   2. ...
   3. ...
   ```

   With `--json`, also write `.claude/repo-health-latest.json` containing `{ "scorecard": {...}, "mining": {...}, "top3": [...] }`.

6. **Present to the engineer.** Echo the report path and the medal + top-3 in chat. Do not dump the full report inline unless asked.

## Verification

- `.claude/repo-health-latest.md` exists and contains a `Medal:` line, a 12-row asset table, and a "Top 3 actionable changes" section.
- The mining section either lists phrases with PR citations OR an explicit `Skipped: <reason>` line — never fabricated phrases.
- No edits were made to `.claude/references/architecture-principles.md`.
- `bash scripts/repo-health-score.sh --json | jq .medal` returns a non-empty string.

## Red Flags

| Rationalization | Reality |
|---|---|
| "I'll auto-promote the mined phrases to principles since they're already cited." | Mining is always suggest-only. Promotion is a separate, manual step with `[MINED:feedback]` tagging. |
| "The scorecard medal is 🥉 — I'll skip the report and just fix things." | The report IS the next action. Don't suppress the artifact. |
| "`gh` failed, so I'll guess what reviewers usually say." | Mining is fail-soft — leave the section empty rather than fabricate. |
| "I'll add new assets on the fly to make the score look better." | The 12 assets are canonical (see `repo-health-assets.md`). Don't extend without updating the reference. |
| "Repo-health and toolkit-health are basically the same — I'll merge them." | They're different: repo-health = readiness of this repo as an AI work surface; toolkit-health = how the team uses MTK. Keep them separate. |
