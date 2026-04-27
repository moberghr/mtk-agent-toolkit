# Pi Borrow Improvements

- **Date:** 2026-04-23
- **Slug:** pi-borrow-improvements
- **Scope:** new-feature
- **Status:** draft

## Summary

Three targeted improvements drawn from a competitive analysis of pi.dev (mariozechner's minimal terminal coding harness). Each addresses a real gap in MTK without compromising its enforcement-first philosophy.

| # | Feature | What changes | Why |
|---|---------|-------------|-----|
| 1 | **Versioned specs** | Specs get `-v2`, `-v3` suffixes on revision instead of overwriting; plans align; handoff captures spec version | Engineers can compare what they planned vs. what they revised; audit trail |
| 2 | **Context load estimator** | `context-budget.sh` accumulates bytes read per session; `session-analytics.sh` reports estimated tokens; `analytics-report.sh` surfaces the number | Teams can see their AI context spend per session; helps diagnose bloated sessions |
| 3 | **Context footprint reporting** | `context-engineering` reports lines/tokens loaded at phase end; `context-report` includes footprint summary | Pi tracks token cost; MTK should track reference load cost — same visibility, applicable to the reference system |

> **Note on Feature 3 vs "lean CLAUDE.md":** The original comparison proposed a `--lean` flag for `setup-bootstrap`. On inspection, `setup-bootstrap` already enforces 60–80 line targets (hard cap 120) backed by Anthropic + ETH Zurich research. The actual gap is visibility — engineers don't see what the reference loading phase cost them in context tokens. Feature 3 addresses that directly.

---

## Success Criteria

| ID | Description | Verification |
|----|-------------|-------------|
| SC1 | When `spec-driven-development` writes a spec and a file with that date+slug already exists, the new file gets a `-v2` (or `-vN+1`) suffix — the old file is untouched | Manual: run spec-driven-development twice for the same slug on the same day; verify two files |
| SC2 | Plan files use the same version suffix as the spec that created them (e.g., plan `-v2` when spec is `-v2`) | Manual: inspect docs/plans after SC1 |
| SC3 | `handoff` artifact JSON includes `spec_path` field with the full versioned path | Manual: trigger handoff after a versioned spec; read the artifact |
| SC4 | `context-report` lists all spec versions for a slug when multiple exist; marks the active one | Manual: with two spec versions on disk, run context-report |
| SC5 | `context-budget.sh` accumulates `bytes_read` from unique files read in the session | Benchmark: `tests/hooks/` shell test that fires mock Read events and asserts `bytes_read > 0` in session state |
| SC6 | `session-analytics.sh` writes `estimated_context_tokens` field to `analytics.json` | Benchmark: trigger session end; assert field present and `> 0` |
| SC7 | `scripts/analytics-report.sh` shows "Estimated context tokens" in its output | Manual: run `bash scripts/analytics-report.sh`; assert field visible |
| SC8 | `context-engineering` skill outputs a "Context footprint" summary after reference loading (lines + estimated tokens per file) | Manual: run a session through Phase 0; confirm footprint block in output |
| SC9 | `context-report` output includes a "Reference footprint" section | Manual: run `/mtk status`; confirm section present |
| SC10 | `bash scripts/validate-toolkit.sh` passes — manifest entries correct, versions synced, no regressions | `bash scripts/validate-toolkit.sh` → "Toolkit validation passed" |

---

## Architecture and Design

### Feature 1 — Versioned Specs

**Mechanism:** `spec-driven-development` checks for existing files before writing. Algorithm:

```
target = "docs/specs/YYYY-MM-DD-<slug>.md"
if target does not exist → write to target (no version suffix, backward compat)
if target exists → find highest existing vN suffix → write to target + "-v(N+1)"
  e.g., if -v2 and -v3 exist → write -v4
```

The JSON sidecar gets the same version suffix. Plan files in `planning-and-task-breakdown` mirror the spec version. Handoff artifacts store the full `spec_path` (with suffix) so sessions resume against the right version. `context-report` scans `docs/specs/` for slug groups and lists all versions.

**No behavioral change for new specs** — only affects re-runs of the same slug. Fully backward compatible with existing specs on disk.

### Feature 2 — Context Load Estimator

**Mechanism:** `context-budget.sh` already tracks which files were read (pipe-separated `$files` in session state). Extend it to also accumulate byte counts:

```bash
# On every Read event with a non-empty FILE_PATH:
if [ -f "$FILE_PATH" ]; then
  file_bytes=$(wc -c < "$FILE_PATH" 2>/dev/null || echo 0)
  bytes_read=$((bytes_read + file_bytes))
fi
```

Only unique files are tracked (already deduped by the `$files` pipe-separated list — skip if `FILE_PATH` already in `$files`). This means `bytes_read` never double-counts a file re-read.

`session-analytics.sh` reads `bytes_read` from session state, computes `estimated_context_tokens = bytes_read / 4` (1 token ≈ 4 bytes, conservative), and writes both fields to `analytics.json`.

**S3.3 compliance:** `wc -c` is coreutils — works on macOS and Linux. Handles missing files with `|| echo 0`.

### Feature 3 — Context Footprint Reporting

**Mechanism:** In `context-engineering/SKILL.md`, add a "Context Footprint" step at the end of each phase's reference loading section. After loading references, the skill runs:

```bash
wc -l .claude/references/security-checklist.md .claude/references/testing-patterns.md ...
```

And outputs a formatted block:
```
Context footprint (Phase 0):
  coding-guidelines.md         84 lines  (~1.1k tokens)
  architecture-principles.md   42 lines  (~560 tokens)
  ─────────────────────────────────────────────────────
  Total loaded this phase:    126 lines  (~1.7k tokens)
```

Estimate: 1 line ≈ 13 tokens (conservative median for reference docs). This isn't exact but gives engineers an order-of-magnitude signal.

`context-report` calls `wc -l` on currently-loaded references and surfaces the same table as a "Reference footprint" section.

---

## Change Manifest

### Feature 1 — Versioned Specs (Skills)
| Path | Action | Purpose |
|------|--------|---------|
| `.claude/skills/spec-driven-development/SKILL.md` | modify | Add version detection step before writing spec |
| `.claude/skills/planning-and-task-breakdown/SKILL.md` | modify | Align plan filename to spec version suffix |
| `.claude/skills/handoff/SKILL.md` | modify | Add `spec_path` field to handoff artifact schema |
| `.claude/skills/context-report/SKILL.md` | modify | Add spec version listing in spec section |

### Feature 2 — Context Load Estimator (Bash)
| Path | Action | Purpose |
|------|--------|---------|
| `hooks/context-budget.sh` | modify | Accumulate `bytes_read` per unique file read |
| `hooks/lib/hook-io.sh` | modify | Add `bytes_read` to session state schema (init + load + save) |
| `hooks/session-analytics.sh` | modify | Read `bytes_read`, compute `estimated_context_tokens`, write to analytics.json |
| `scripts/analytics-report.sh` | modify | Show estimated context tokens in report output |
| `tests/hooks/test-context-estimator.sh` | create | SC5+SC6 benchmark: mock Read events, assert bytes_read and estimated_context_tokens |

### Feature 3 — Context Footprint Reporting (Skills)
| Path | Action | Purpose |
|------|--------|---------|
| `.claude/skills/context-engineering/SKILL.md` | modify | Add "Context Footprint" output step after each phase's reference loading |
| `.claude/skills/context-report/SKILL.md` | modify | Add "Reference footprint" section with wc-l table |

### Cross-cutting
| Path | Action | Purpose |
|------|--------|---------|
| `.claude/manifest.json` | modify | Register `tests/hooks/test-context-estimator.sh`; bump version to 7.1.0; update date |
| `.claude-plugin/plugin.json` | modify | Bump version to 7.1.0 (C0.1 sync) |
| `CHANGELOG.md` | modify | Add v7.1.0 entry |

---

## Test Manifest

| Path | Covers | Type |
|------|--------|------|
| `tests/hooks/test-context-estimator.sh` | SC5, SC6 | bash benchmark |
| Manual spec revision run (same slug, same day) | SC1, SC2, SC3 | manual |
| `context-report` run with multiple spec versions on disk | SC4, SC9 | manual |
| `context-engineering` session Phase 0 output | SC8 | manual |
| `bash scripts/analytics-report.sh` | SC7 | manual |
| `bash scripts/validate-toolkit.sh` | SC10 | deterministic |

---

## Out of Scope

- True token counting from Claude Code API (requires Claude Code to expose session metadata — no hook API for this today)
- Spec branching UI / tree navigation (Pi's `/tree` command) — requires Claude Code TUI investment beyond markdown skills
- npm package distribution — separate initiative
- Session export / share — separate initiative
- Multi-provider support — architectural decision, not an improvement to plan now

---

## Assumptions

1. `wc -c` and `wc -l` produce consistent output on macOS (BSD) and Linux (GNU) — both strip leading whitespace differently, but the `tr -d ' '` normalization already used in context-budget.sh handles this.
2. The `$files` pipe-separated list in session state is the canonical unique-file tracker — appending `bytes_read` to the same session state file is safe.
3. `hook-io.sh` load/save functions use a consistent key=value format that can be extended with new fields without breaking existing readers.
4. Context-engineering skill output is seen by the engineer (not silenced or overridden) — footprint block will be visible in Claude Code's chat output.
5. Version suffix `-vN` is lexicographically orderable (v2 < v3 < v10 when sorted numerically) — `ls -v` or `sort -V` handles this on both platforms.

---

## Risks

| ID | Risk | Mitigation |
|----|------|-----------|
| R1 | `wc -c` on large files (e.g. a .sln or lockfile accidentally read) inflates `bytes_read` — tokens estimate becomes misleading | Cap per-file contribution at 100k bytes in the estimator; flag files over cap |
| R2 | Spec versioning fires when an unrelated spec with similar slug exists on the same date | Slug must be exact match (date + full kebab slug); document that engineers control the slug |
| R3 | `hook-io.sh` extension breaks existing session state readers if fields are added without defaults | Initialize all new fields with `0` in `mtk_load_session_state`; existing code won't reference unknown fields |
| R4 | Context footprint output adds noise to Phase 0 — engineers may find it distracting | Format as a collapsible block (``` section header + indented lines ```); can be skimmed |
| R5 | `context-report` is slow if it runs `wc -l` on many files | Limit to currently-loaded references (those matching active tech stack globs) |
