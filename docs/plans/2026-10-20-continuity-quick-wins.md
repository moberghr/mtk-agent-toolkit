# Plan — Continuity quick wins (PR-1, 9.3.0) — 2026-10-20

Spec: `docs/specs/2026-10-20-continuity-quick-wins.md` (+ `.json`). Program: `docs/plans/2026-10-20-auto-continuation.md`.
Branch: `feat/continuity-quick-wins` from `origin/main` @ 1523a72 (9.2.0). Rigor: HIGH (5 batches ⇒ hard-trigger floor).

## Waves

- **Wave 1:** B1 ∥ B4. These are file-disjoint.
- **Wave 2:** B2. It shares `scripts/mtk-doctor.sh` with B1.
- **Wave 3:** B3. It shares `env-knobs.md` with B2.
- **Wave 4:** B5. Release, inline, last.

## B1 — Compaction window in the settings baseline (R0.1)

- **Files:**
  - `.claude/references/settings-baseline.md`
  - `scripts/settings-baseline.sh`
  - `scripts/mtk-doctor.sh`
  - `.claude/skills/setup-bootstrap/SKILL.md`
  - `.claude/skills/setup-refresh/SKILL.md`
  - `tests/hooks/test-settings-baseline.sh`
- **Do:**
  - Add a `### settings` section to the baseline: `` - `autoCompactWindow: 300000` `` plus a note. That note says Claude Code otherwise compacts at about 967k on 1M models, that the engineer's existing value always wins, and that the value is capped at the model window.
  - In the parser, collect `### settings` bullets as `key: value` and turn integer-looking values into ints.
  - `--json` puts them at the top level.
  - `--missing` emits `settings\t<key>: <value>` for absent keys.
  - `--merge` needs no special code, since the source JSON carries the keys and the target wins.
  - Doctor: generalise the PASS/WARN/--fix wording from "deny/ask rule(s)" to "baseline rule(s)/setting(s)".
  - Bootstrap's *Settings Merge* names the new section. Refresh's `permissions-baseline` step lists a `settings` hunk.
- **Acceptance:** SC1, SC2. **Boundary:** the deny/ask output lines and semantics stay byte-identical.

## B2 — PostCompact archive and session-start offers (R0.2, R0.3)

- **Files:**
  - `hooks/compact-archive.sh` (new)
  - `hooks/hooks.json`
  - `hooks/lib/hook_registry.py`
  - `scripts/mtk-doctor.sh`
  - `hooks/session-start`
  - `tests/hooks/test-compact-archive.sh` (new)
  - `tests/hooks/test-hook-registry.sh`
  - `tests/hooks/test-session-start-compact-framing.sh`
  - `.claude/references/env-knobs.md`
  - `.claude/manifest.json` (file entries only)
- **Hook contract** (spec R0.2):
  - The archive guard is `git check-ignore -q .mtk/sessions/x`. Not a git repo means write. A git repo where `.mtk` is not ignored means skip silently.
  - Use `mtk_repo_root` for the root, `active_workflow.py <wf_dir> 7 path` for `workflow`, and `umask 077` for the file mode.
  - Prune with `find .mtk/sessions -mindepth 1 -maxdepth 1 -type d -mtime +14`, deleting under `.mtk/sessions/` only.
  - Register it under `"PostCompact"` with `async: true` and `timeout: 5`.
- **Registry:** `rarity` is `rare` for `event in ("SubagentStart", "PostCompact")` or `cond`. Update the docstring, and the doctor line that says "(SubagentStart or if-filtered)".
- **session-start:**
  - Change the condition from `[ "$SS_SOURCE" = "startup" ]` to startup|clear.
  - After the handoff block, if no offer was emitted, run a python3 one-shot that lists `.mtk/sessions/*/compact-*.md`. It keeps files whose frontmatter `branch` matches and whose mtime is within 24h, and takes the newest.
  - It emits `COMPACTION OFFER: summary of an earlier compacted session on this branch at <rel path> (<HH:MM date>) — a historical snapshot; read it only if you are picking that work up.`
  - Without python3, nothing is offered (fail open).
- **Acceptance:** SC3, SC4. **Boundary:** runtime diet; the compact-source output and the existing startup offer text are unchanged.

## B3 — Bounded implementers (R0.4)

- **Files:**
  - `.claude/references/subagent-implementer-prompt.md`
  - `.claude/skills/subagent-implementation/SKILL.md`
  - `.claude/references/subagent-dynamic-workflow.md`
  - `.claude/references/env-knobs.md`
  - `tests/pressure-tests/subagent-implementation-pressure.md`
- **Do:**
  - Add a numbered TASK rule:
    - The budget is `<max_calls>`, from `MTK_IMPLEMENTER_MAX_CALLS`, default 120.
    - Stop when over budget, or after two verify failures on the same error with no new approach.
    - On stopping, return `partial` with `resume_note` {done, left, next, files}.
  - Add a result-size rule: JSON ≤ ~60 lines, with the rest in `.mtk/workflows/<uuid>/batches/<id>/report.md`.
  - Add to the schema: the `partial` status and an optional `resume_note`.
  - Skill step 3/4: `partial` → respawn a fresh implementer with the existing `RESUME:` preamble plus `resume_note`, at most 2 per batch, then halt. It is never a pass. Count it in `results.dispatch_incidents[]` with `kind:"partial"`.
  - The dynamic-workflow reference gets the same rule.
  - Add one pressure scenario.
- **Acceptance:** SC5. **Boundary:** killed and inconclusive semantics are unchanged; the SKILL.md diff stays at or under about 600 chars.

## B4 — Typable workflow skills (R0.5)

- **Files:** the frontmatter of `implement`, `fix` and `batch-fix`; `AGENTS.md`; `docs/agent-routing-guide.md`.
- **Do:**
  - In each frontmatter, set `user-invocable: true`, `allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion` (the same as `/mtk`), and an `argument-hint`.
  - AGENTS.md: rewrite the "Five skills are user-invocable" sentence to list the 3 direct shortcuts, and add one Skill Routing row.
  - In the routing guide, change "Reached via `/mtk <description>`…" to name the direct shortcuts.
- **Acceptance:** SC6. **Boundary:** no body or description changes.

## B5 — Release 9.3.0 (inline)

- Set the version to 9.3.0 in `.claude/manifest.json`, `.claude-plugin/plugin.json` and `marketplace.json`, and set `updated`.
- Add a CHANGELOG `## [9.3.0] - 2026-10-20` entry with the hook-process table:
  - +0 on every hot path;
  - `PostCompact` gets 1, async, once per compaction.
- Run `bash scripts/build-references-index.sh` locally. The index is a gitignored build artifact; the "out of sync" failure was a stale local copy, not a repo defect.
- Run `bash scripts/generate-checksums.sh` last.
- **Acceptance:** SC7.

## After all batches

- Run the full hook suite, `run-fixtures.sh`, `validate-toolkit.sh` and `claude plugin validate . --strict`.
- Run the spec-drift check against the sidecar.
- Run the review lanes for HIGH on Sonnet, at most 2 rounds.
- Push and open the PR **only after the engineer's explicit OK**, with `--assignee @me` and `--body-file`.
