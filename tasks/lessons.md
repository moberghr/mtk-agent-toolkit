# Lessons Learned

> This file captures patterns and mistakes discovered during AI-assisted development.
> It is read at the start of every `/mtk` workflow.
> Commit this file — it is institutional memory for the team.
>
> **Structured mirror (v7.5.0+):** every lesson here is also stored in
> `.mtk/learnings.jsonl` (gitignored, machine-readable) for 5-layer retrieval
> at the start of specs and fixes. New lessons added via `correction-capture`
> or `promote-lesson` flow through `scripts/learnings.sh add` and write to
> both stores. Manual edits to this markdown file remain canonical for the
> team; the JSON store is rebuildable. See
> `.claude/references/learnings-schema.md`.

## 2026-04-23 — marketplace.json is a third version file the validator checks

**What happened:** After bumping `manifest.json` and `plugin.json` to 7.1.0, `validate-toolkit.sh` still failed with "Version mismatch: manifest=7.1.0 marketplace=7.0.0". The `.claude-plugin/marketplace.json` is a third file that must stay in sync.

**Rule:** When bumping version, update all three: `manifest.json`, `plugin.json`, AND `marketplace.json`. The spec change manifest must list all three.

**Why:** The validator checks all three version fields. Omitting one from the spec/plan means the bump is incomplete.

**Applies to:** Any version bump task — add `marketplace.json` to the change manifest alongside manifest.json and plugin.json.

---

## 2026-04-23 — Hook test assertions inside subshells lose their counters

**What happened:** The first version of `test-context-estimator.sh` used `(...)` subshells to isolate `source "$HOOK_IO"`. Assertions inside those subshells incremented local `pass`/`fail` counters that were never seen by the parent, producing "4/4 passed" despite 7 assertions running.

**Rule:** Hook benchmark tests must use exit-1-on-failure patterns (like existing tests), not accumulating counters. Any counter-based approach requires writing counts to a temp file and reading them back in the parent.

**Why:** Bash subshells don't propagate variable changes to the parent. Sourcing hook-io inside a subshell correctly isolates namespace but silently loses counters.

**Applies to:** Any new test in `tests/hooks/` that needs to source `hook-io.sh` and assert results.

---

## 2026-04-11 — TaskCompleted hook blocks task completion

**What happened:** The `TaskCompleted` prompt hook in `settings.json` prevents tasks from being marked `completed`. The hook fires on the event and its evaluation interferes with the state transition. Tasks stayed stuck at `in_progress` despite repeated `TaskUpdate(completed)` calls. `deleted` worked because no hook fires on deletion.

**Rule:** Do not use prompt hooks on `TaskCompleted` events — they block completion state transitions. Use the `Stop` hook for verification reminders instead, which fires on agent response completion without interfering with task state.

**Why:** Prompt hooks on state-change events can interfere with the state change itself. The `TaskCompleted` hook was designed to be informational but it silently prevents tasks from reaching `completed` status.

**Applies to:** Any settings.json configuration that uses hooks on TaskCompleted events.

## 2026-05-19 — Quoted heredoc in $(...) still tokenizes backticks

**What happened:** `$(python3 - <<'PY' ... PY)` with backticks inside the PY heredoc body caused bash on macOS to fail with "unexpected EOF while looking for matching `". Even though `<<'PY'` (quoted delimiter) should suppress expansion, the tokenizer inside `$(...)` still trips on raw backticks in the body.

**Rule:** Avoid literal backticks inside any heredoc nested in `$(...)`. Use `BT = chr(96)` in Python or write the script to a temp file with `cat > "$f" <<'PY'` and `python3 "$f"` instead of inlining.

**Why:** Triggers a confusing failure that looks like a heredoc-termination bug but is actually `$(...)` tokenization. Cost ~15 minutes of debugging.

**Applies to:** Any bash script that embeds Python or shell snippets containing backticks via heredoc within command substitution.

## Idempotency guards on JSON trails must match structurally, not by grep
- **What happened:** `spec-archive.sh` used `grep -q "\"slug\":\"$SLUG\""` to detect already-archived slugs. `$SLUG` is a regex to grep, so a slug with a metachar (e.g. `a.b`) could falsely match a different slug (`aXb`) and silently drop the archive — caught in compliance review.
- **Rule:** When checking "did I already process X?" against a JSON/JSONL trail, match with `jq -e --arg s "$X" 'select(.field == $s)'`, not `grep`. If grep is unavoidable, use `grep -F`.
- **Why it matters:** Silent NO-OP on a divergent match breaks the audit trail the feature exists to guarantee — a data-integrity failure, not a cosmetic one.
- **When it applies:** Any idempotency/dedup guard that scans a structured log keyed by a user-supplied identifier.
