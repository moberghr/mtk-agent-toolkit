---
name: toolkit-health
description: Use when the engineer asks for toolkit usage stats, adoption signals, or wants to diagnose whether MTK is being used as intended — reads analytics.json and surfaces anomalies with suggested actions.
type: skill
license: MIT
compatibility:
  - claude-code
trigger: toolkit-health-check|adoption-audit|analytics-review
skip_when: no-analytics-file|first-session
user-invocable: false
---

# Toolkit Health

## Current Analytics Snapshot

```!
echo "--- Analytics file ---"
if [ -f .claude/analytics.json ]; then cat .claude/analytics.json; else echo "(not yet created — needs at least one non-trivial session)"; fi
echo "--- Specs on disk ---"
if [ -d docs/specs ]; then find docs/specs -name '*.md' 2>/dev/null | wc -l | tr -d ' '; else echo "0"; fi
echo "--- Lessons captured ---"
if [ -f tasks/lessons.md ]; then grep -c '^## ' tasks/lessons.md 2>/dev/null || echo "0"; else echo "0 (file missing)"; fi
```

## Overview

`hooks/session-analytics.sh` persists session stats to `.claude/analytics.json`. This skill reads that file plus on-disk artifacts (specs, lessons, MTK-related commits) and produces a human-readable health report with anomaly flags and suggested actions. Read-only — never mutates state.

## When To Use

- Engineer asks "how are we using MTK?" / "toolkit health" / "usage stats"
- Periodic team review of adoption (weekly/monthly retro)
- Before promoting a lesson to a CLAUDE.md rule — sanity-check that it reflects real usage
- After a big change to skill routing, to see whether the new routes are firing

### When NOT To Use

- As part of a regular build/test loop (this is a diagnostic, not a gate)
- When `.claude/analytics.json` has fewer than 3 sessions — not enough data
- As a substitute for `/mtk status` / context-report (that skill reports *current* config, this skill reports *historical* usage)

## Workflow

1. **Load the data sources in parallel** (independent reads — see `docs/parallelism-patterns.md`):
   - `.claude/analytics.json` (session counts, ops, mods, specs_created, lessons_captured, scope_guard_warnings)
   - `tasks/lessons.md` if present (count `^## ` entries)
   - `docs/specs/` and `docs/plans/` directory listings
   - `git log --since="30 days ago" --oneline --grep='mtk\|MTK\|toolkit'` for MTK-related commits

2. **Graceful degradation:**
   - If `.claude/analytics.json` is missing → report "No analytics yet. Run a non-trivial `/mtk` session to populate."
   - If the JSON is corrupt (parse fails) → report the error, suggest `rm .claude/analytics.json` to reset (file is gitignored per `setup-bootstrap`).
   - If `sessions < 3` → report "Insufficient data (fewer than 3 sessions). Report will be unreliable."

3. **Compute ratios:**
   - Average ops per session: `total_operations / sessions`
   - Specs-per-session: `specs_created / sessions`
   - Lessons-per-spec: `lessons_captured / max(1, specs_created)`
   - Scope-guard warning rate: `scope_guard_warnings / sessions`

4. **Flag anomalies** against these thresholds (tunable as the team learns more):

   | Signal | Healthy range | Anomaly |
   |---|---|---|
   | `specs_created / sessions` | ≥ 0.05 over 20+ sessions | "Very few specs — team may skip `/mtk implement` for features" |
   | `lessons_captured` | growing over time | "Lessons stagnant — Phase 7 compound step may be skipped" |
   | `scope_guard_warnings / sessions` | < 0.3 | "Frequent scope-guard warnings — specs may be too narrow or team is expanding scope inline" |
   | `total_modifications / total_operations` | 0.1–0.6 | "Very low mod ratio" → mostly reads (discovery-heavy); "very high" → little verification |
   | `benchmark_last_score` | matches latest baseline | stale score → benchmarks haven't been re-run after toolkit changes |

5. **Output format:**
   - Human-readable markdown section (sessions, date range, key ratios, anomaly flags).
   - A fenced JSON block with the raw computed metrics — so downstream tools (CI dashboards, other skills) can consume it.

6. **Suggested actions** — for each flagged anomaly, print one actionable next step. Examples:
   - "Run `/mtk-setup --audit` to refresh architecture principles" (if `sessions > 30` and `updated` date is old)
   - "Review `tasks/lessons.md` for promotion candidates to `CLAUDE.md`" (if `lessons_captured > 15`)
   - "Run `bash scripts/run-benchmarks.sh` to refresh the effectiveness baseline" (if benchmarks stale)

## Rules

- **Read-only.** Never modify `.claude/analytics.json`, `tasks/lessons.md`, or `docs/specs/`. Reports the engineer's state; doesn't change it.
- **Honest "insufficient data".** If the sample is too small, say so — do not produce spurious percentages that imply statistical weight.
- **No fabrication.** Every reported number must come from a cited source file. If something cannot be computed, omit it rather than guess.
- **Parallel loading.** Load all data sources in one message, per `docs/parallelism-patterns.md`.

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` for the shared table. Toolkit-health specific traps: "we've been busy, the numbers don't matter" (if numbers don't match activity, the hooks are broken — investigate); "the anomaly thresholds are arbitrary" (they are — say so in the report, but still flag).

## Red Flags

- Reporting ratios on fewer than 3 sessions as if meaningful
- Silently skipping missing files instead of reporting the gap
- Modifying `.claude/analytics.json` during a "health check"
- Claiming adoption success without citing specs_created / lessons_captured actuals

## Verification

- [ ] `.claude/analytics.json` was read (or its absence reported)
- [ ] At least one ratio was computed or graceful-degraded
- [ ] Anomaly flags map to concrete next actions
- [ ] Output includes a fenced JSON block for machine consumption
- [ ] No write operations against analytics/lessons/specs
