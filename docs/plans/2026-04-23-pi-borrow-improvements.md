# Pi Borrow Improvements — Implementation Plan

- **Spec:** `docs/specs/2026-04-23-pi-borrow-improvements.md`
- **Date:** 2026-04-23
- **Version target:** 7.1.0
- **Scope:** 3 independent feature improvements (skills + bash)

---

## Batch 1 — Feature 1: Versioned Specs (Skills only)

**Files:** `.claude/skills/spec-driven-development/SKILL.md`, `.claude/skills/planning-and-task-breakdown/SKILL.md`, `.claude/skills/handoff/SKILL.md`, `.claude/skills/context-report/SKILL.md`

**Work:**

1.1 `spec-driven-development/SKILL.md` — In the "Persist the spec to disk" step (Phase 1), add version detection before writing:
  - Compute `target = docs/specs/<date>-<slug>.md`
  - If target does not exist → write as-is (no suffix)
  - If target exists → find highest existing `-vN` suffix via `ls docs/specs/<date>-<slug>*.md | grep -oE 'v[0-9]+' | sort -V | tail -1`; write as `-v(N+1)`. Default to `-v2` if no existing `-vN` found.
  - JSON sidecar gets the same version suffix.
  - Emit "Writing spec as \<path\>" so the engineer sees which version was chosen.

1.2 `planning-and-task-breakdown/SKILL.md` — In the "Write both files" step, add:
  - When a spec path is provided (from Phase 1), extract the full filename including any `-vN` suffix.
  - Use that same suffix for the plan file: `docs/plans/<same-stem>.md`.
  - If no spec path available (standalone planning run), use no suffix.

1.3 `handoff/SKILL.md` — In the artifact schema section, add `spec_path` field:
  - Capture the full spec path (with version suffix) if a spec is active in the current session.
  - On resume, read `spec_path` and restore the correct versioned spec as context.

1.4 `context-report/SKILL.md` — In the spec listing section, add:
  - Group spec files by slug (strip `-vN` and `.json` suffixes).
  - For each slug with multiple versions, list all: `[v1] 2026-04-23-foo.md`, `[v2] 2026-04-23-foo-v2.md`.
  - Mark the active version (from handoff artifact or most recent mtime) with `← active`.

**Checkpoint:** Read all 4 edited skill files. Confirm version detection language is unambiguous, backward-compatible (no suffix for first version), and the handoff artifact schema is documented.

**SC covered:** SC1, SC2, SC3, SC4

---

## Batch 2 — Feature 2: Context Load Estimator (Bash)

**Files:** `hooks/lib/hook-io.sh`, `hooks/context-budget.sh`, `hooks/session-analytics.sh`, `scripts/analytics-report.sh`, `tests/hooks/test-context-estimator.sh`

**Work:**

2.1 `hooks/lib/hook-io.sh` — Extend session state schema:
  - Add `bytes_read=0` to `mtk_load_session_state` defaults (alongside existing `reads=0`, `mods=0`, etc.)
  - `mtk_save_session_state` already writes all variables — no change needed there if `bytes_read` is in scope.
  - Verify `mtk_session_file` and lock functions are unchanged.

2.2 `hooks/context-budget.sh` — In the `Read` case:
  - After the existing dedup check (`if ! echo "$files" | grep -qF "$FILE_PATH"`), add byte accumulation for new files only:
    ```bash
    file_bytes=$(wc -c < "$FILE_PATH" 2>/dev/null | tr -d ' ' || echo 0)
    # Cap at 100k to avoid inflating from incidentally-read large files
    [ "$file_bytes" -gt 100000 ] && file_bytes=100000
    bytes_read=$((bytes_read + file_bytes))
    ```
  - If `FILE_PATH` is already in `$files` (duplicate read), skip — bytes already counted.

2.3 `hooks/session-analytics.sh` — Add after existing counter reads:
  - Read `bytes_read` from session state (via `mtk_load_session_state`).
  - Compute `estimated_tokens=$((bytes_read / 4))`.
  - Add two new fields to `analytics.json`:
    - `"bytes_read": <cumulative across sessions>`
    - `"estimated_context_tokens": <cumulative>`
  - Update the `read_field` / write section to handle both new fields.
  - Initialize both to `0` in the new-file template.

2.4 `scripts/analytics-report.sh` — Add after existing stats output:
  - Read `estimated_context_tokens` from analytics.json.
  - Format: `Estimated context tokens: 142,800 (~35.7k avg/session)`.
  - If `0`, omit the line (no data yet).

2.5 `tests/hooks/test-context-estimator.sh` — New benchmark script:
  - Setup: create temp session state dir; create 3 test fixture files with known sizes.
  - Fire mock `Read` events against the hook (source the hook or call it with mock stdin).
  - Assert `bytes_read > 0` in session state after 3 unique files.
  - Assert `bytes_read` does NOT increase when the same file is "read" twice (dedup works).
  - Assert `bytes_read` is capped at 100000 for files > 100k.
  - Trigger `session-analytics.sh`; assert `estimated_context_tokens` field present and non-zero in analytics.json.
  - Teardown: remove temp files.

**Checkpoint:** Run `bash tests/hooks/test-context-estimator.sh`. Assert green. Spot-check that a real session-analytics.sh run (dry-run with fake session state) produces the new fields.

**SC covered:** SC5, SC6, SC7

---

## Batch 3 — Feature 3: Context Footprint Reporting (Skills)

**Files:** `.claude/skills/context-engineering/SKILL.md`, `.claude/skills/context-report/SKILL.md`

**Work:**

3.1 `context-engineering/SKILL.md` — After each phase's reference loading block, add a "Context Footprint" output step:

  - Template (to be inserted after loading references in Phase 0, and each subsequent phase):
    ```
    **Context Footprint (Phase 0):**
    Run: wc -l <file1> <file2> ... 2>/dev/null
    Output each file as:   <filename>   <lines> lines  (~<lines*13> tokens)
    Sum all lines and tokens.
    Format: ─── Total: <N> files, <sum_lines> lines (~<sum_tokens> tokens)
    ```
  - Token estimate: 1 line ≈ 13 tokens (conservative median for reference docs at ~65 chars/line / 5 chars/token ≈ 13).
  - The model executes the `wc -l` Bash call and formats the output inline.
  - If no references were loaded in a phase, omit the footprint block for that phase.
  - Keep it skimmable: use a tight block, not a section header. Engineers can ignore it if needed.

3.2 `context-report/SKILL.md` — Add "Reference footprint" section:
  - Identify which references are currently loaded (from active tech stack and any path-scoped matches).
  - Run `wc -l` on each.
  - Output as a table: `| File | Lines | Est. tokens |`
  - Include a totals row.
  - Place this section after the existing "Active references" list, before the "Hooks" section.

**Checkpoint:** Read both edited skill files. Confirm footprint step is present and instructions are unambiguous. Check that the wc-l format works on both macOS and Linux (BSD vs GNU wc both support `-l`).

**SC covered:** SC8, SC9

---

## Batch 4 — Manifest + Version Bump

**Files:** `.claude/manifest.json`, `.claude-plugin/plugin.json`, `CHANGELOG.md`

**Work:**

4.1 `.claude/manifest.json`:
  - Add entry for `tests/hooks/test-context-estimator.sh` (action: sync, description: "Benchmark test for context load estimator — SC5+SC6 for pi-borrow-improvements")
  - Bump `version` to `7.1.0`
  - Update `updated` date to `2026-04-23`

4.2 `.claude-plugin/plugin.json`:
  - Bump `version` to `7.1.0` (C0.1 sync)

4.3 `CHANGELOG.md`:
  - Add `## [7.1.0] - 2026-04-23` section with three bullet points (one per feature)

**Checkpoint:** `bash scripts/validate-toolkit.sh` → "Toolkit validation passed"

**SC covered:** SC10

---

## Post-Implementation Review

- [ ] Phase 3.5 — spec-drift-detection vs sidecar JSON
- [ ] Phase 4 Stage 1 — compliance-reviewer
- [ ] Phase 4 Stage 2 — architecture-reviewer + test-reviewer (parallel)
- [ ] Phase 6 — code-simplification
- [ ] Phase 7 — capture learnings; update `tasks/lessons.md`

---

## Batch Sequence Rationale

Batches 1 and 3 are skills-only (no bash); Batch 2 is bash-only. They're fully independent — any order works. Batch 4 always last (manifest + version). The suggested order (1 → 2 → 3 → 4) groups by type for easier review.

## Behavioral Diff

**Before:**
- Spec revision silently overwrites existing spec file — no history
- Session analytics shows operations and modifications but no context cost signal
- Phase 0 context loading happens invisibly — engineers can't see what was loaded or how much

**After:**
- Spec revision creates a new versioned file; old version preserved; handoff artifacts point to the right version
- Session analytics tracks bytes read and estimated token cost per session
- Phase 0 outputs a context footprint block; `context-report` includes a reference cost table
