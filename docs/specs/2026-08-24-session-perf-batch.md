# Batch: session performance fixes (2026-08-24)

Source: analysis of 16 sessions / 3,230 API requests from 2026-08-24 plus full
hook-timing history on disk. Scope note: **no new public contract; no
architectural change.** Findings are independent.

Measured mechanism: output throughput vs context size —
164 tok/s (<200k) → 129 (200-300k) → 119 (300-400k) → 87 (400-500k) → 83 (600-700k).
Every always-on token costs speed, so the batch targets always-on bytes and
per-tool-call hook wall time.

## Findings

| # | Finding | Files | Kind | Boundary |
|---|---|---|---|---|
| 1 | warp notification plugin costs 1,892s hook wall time (28,621 calls, ~66ms on every tool call, 435ms median per Stop) and fails on `/dev/tty` every time | `~/.claude/settings.json` | mechanical | env (outside repo) |
| 2 | `setup-bootstrap` writes `bash $CLAUDE_PLUGIN_ROOT/hooks/format-on-edit.sh` into the **project** `.claude/settings.json`, where that var is undefined → `bash: /hooks/format-on-edit.sh: No such file or directory`, 4,552 failed invocations; formatting never ran | `.claude/skills/setup-bootstrap/SKILL.md`, `scripts/validate-toolkit.sh` | behavioral | generator |
| 2b | Repair the 7 already-bootstrapped repos carrying the broken wiring | 7 × `<repo>/.claude/settings.json` | mechanical | outside repo |
| 3 | `setup-bootstrap` generates `.claude/rules/*.md` with **no `paths:`/`axes:` frontmatter** and never runs the shipped `build-rule-index.sh` → every rule file loads eagerly, forever. four bootstrapped repos measured at 7 files/30KB, 6/16KB, 8/13KB and 4/4.6KB — all with 0 files carrying frontmatter and no INDEX.md | `.claude/skills/setup-bootstrap/SKILL.md` | behavioral | generator |
| 3b | Backfill `paths:` frontmatter + INDEX.md in the affected repos | 4 repos × `.claude/rules/` | mechanical | outside repo |
| 4 | The largest bootstrapped repo's `CLAUDE.md` is 397 lines / 39.6KB against setup-bootstrap's own documented **120-line hard cap** ("refuse to proceed"). No overlap with its rules/, so this is relocation, not dedup: move sections into lazily-loaded `.claude/rules/` rather than delete knowledge | `<repo>/CLAUDE.md`, `<repo>/.claude/rules/` | editorial | outside repo |
| 5 | `hooks/capture-learnings.sh` has **no per-session nag budget** — fires on every Stop past the 20-op threshold. 805 injections / 275 sessions, median 1 but **max 63 in a single session** (~9k tokens of repeated identical text) | `hooks/capture-learnings.sh` | behavioral | — |
| 5b | Set `MTK_COMPRESS_MAX_NAGS=0` (personal preference) | `.claude/settings.local.json` | mechanical | — |
| 6 | `implement/SKILL.md` is 551 lines / 48KB and costs +17,160 tokens measured on load; violates S2.26 (navigation layer, not payload). Split phase detail into references | `.claude/skills/implement/SKILL.md`, new `.claude/references/implement-*.md`, manifest | mechanical | — |

## Corrections to the original analysis (verified this run)

- **compress-monitor's once-per-session budget WORKS.** Tested directly: run 1 nags,
  runs 2–3 silent, state file reads `1`. The observed median of 2/session comes from
  resumed sessions and TMPDIR reaping, not a leak. My earlier "budget isn't holding"
  claim was wrong; 5b is a preference, not a bug fix.
- **Finding 3 is the real root cause behind "cut that CLAUDE.md".** The lazy-rule
  machinery (`paths:` frontmatter + `build-rule-index.sh`) already exists and ships —
  bootstrap just never wires it up. That reframes finding 4 from deletion to relocation.

## Execution groups

- **A** — MTK generator fixes (F2, F3, F5) — verified by `validate-toolkit.sh` + hook tests
- **B** — implement/SKILL.md split (F6) — verified by `validate-toolkit.sh`
- **C** — environment + external repo repair (F1, F2b, F3b, F5b) — verified by re-running the hooks
- **D** — CLAUDE.md relocation in the affected repo (F4) — verified by line count + rules index
