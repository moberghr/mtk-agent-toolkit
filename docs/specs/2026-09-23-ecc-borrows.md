# Spec — Six borrows from ECC (affaan-m/ECC v2.2.2)

- **Date:** 2026-09-23
- **Slug:** `ecc-borrows`
- **Scope:** `new-feature`
- **Branch:** `feat/ecc-borrows` (from `origin/main` @ 1156520)
- **Security impact:** `none` (new tooling guards; no auth, secrets, audited state)
- **Source:** ECC clone at commit `bf70150` (2026-09-21), studied read-only. Design ported, no code copied.

## Summary

Port six ideas from ECC into MTK in MTK's own idiom: bash hooks, `hook-io.sh` helpers, `MTK_*` knobs, and honest `not recorded` bookkeeping.

1. **config-guard.** A PreToolUse hook that denies edits which *weaken* linter, analyzer or formatter config. Examples: adding `NoWarn` codes, setting severity to `none`, `TreatWarningsAsErrors=false`, a rule set to `"off"`, lines added to an ignore file. Edits to protected files that don't weaken anything pass silently.
2. **fact-force-guard.** On the first Edit/Write of an existing code file, checks that the session searched for the file's dependents: a Grep, Glob or grep-style Bash command mentioning the file's stem. It advises by default. With `MTK_FACT_FORCE_ENFORCE=1` it denies, once per file.
3. **mcp-health.** Records failing MCP tool calls per server (from `PostToolUseFailure`) with exponential backoff, and clears the record on success. While a server is in backoff, a PreToolUse call to it gets advice by default, or a denial with `MTK_MCP_HEALTH_ENFORCE=1`, pointing the model at non-MCP fallbacks.
4. **cost-tracker.** A Stop hook that turns token counts from the transcript (deduplicated by `message.id`, subagent transcripts included) into per-Stop delta rows in `.mtk/metrics/costs.jsonl`, with an API-equivalent USD estimate. `scripts/session-cost.sh window` sums a time window, and the implement receipt gains a cost section from it.
5. **Harness adapter reference.** `docs/ecc-harness-adapters-2026-09.md` records ECC's adapter layout, capability map and Memory Vault trust model. The multi-harness migration plan links to it from WS2, WS3, WS6 and WS7.
6. **lesson-score.** `scripts/lesson-score.sh` computes a staleness/confidence score for each lesson from signals already stored: recurrence, reconfirmation, recalls, age decay, expiry and stale anchors. `lesson-refresh` ranks its triage by this score, lowest first.

## Decisions (ambiguity gate, answered 2026-09-23)

| # | Question | Answer |
|---|---|---|
| D1 | Default guard stance | **Mixed.** config-guard hard-denies weakening edits only. fact-force and mcp-health are advisory, with `MTK_*_ENFORCE=1` to deny. Every guard has an off-switch. |
| D2 | Cost units | **Tokens + an estimated USD figure**, labelled "API-equivalent estimate", from a dated pricing table. |
| D3 | Reference doc home | **`docs/` (flat, beside `competitive-analysis-*.md`)**, maintainer-only and not shipped, linked from the migration plan. |
| D4 | PR shape | **One branch, one PR**, one commit per borrow, minor bump to **7.36.0**. |

## Success criteria

| ID | Criterion | Verification | Channel |
|---|---|---|---|
| SC1 | config-guard exits 2 when an Edit adds a `NoWarn` code to `Directory.Build.props`, sets a `dotnet_diagnostic.*.severity` to `none`/`silent`/`suggestion` in `.editorconfig`, flips `TreatWarningsAsErrors` to `false`, adds `"off"` to an eslint config, adds a code to a ruff `ignore`, or adds a line to `.eslintignore`. | `bash tests/hooks/test-config-guard.sh` | test-run |
| SC2 | config-guard exits 0 for: a non-weakening edit to a protected file (adding a stricter rule, bumping a version), creating a new config file, any non-protected file, the path on the engineer approval list, `MTK_CONFIG_GUARD=0`, and an unparseable payload. | same | test-run |
| SC3 | A config-guard deny carries the `mtk_deny` continuation suffix and tells the model to stop and ask the engineer. It never prints a self-approval command. An Edit/Write to the approval list file itself is denied. | same + `bash tests/hooks/test-deny-ergonomics.sh` | test-run |
| SC4 | fact-force-guard emits advisory `additionalContext` on the first Edit of an existing `.cs`/`.py`/`.ts`/`.sh` file whose stem appears in no search recorded this session. The second Edit of the same file is silent. It is silent when a prior Grep, Glob or `grep`/`rg` Bash search mentioned the stem, and silent for new files, docs, tests, paths outside the repo and `MTK_FACT_FORCE=0`. | `bash tests/hooks/test-fact-force-guard.sh` | test-run |
| SC5 | With `MTK_FACT_FORCE_ENFORCE=1`, the same first-edit case exits 2 with the deny suffix and toggle hint, and the retry of that file exits 0. | same | test-run |
| SC6 | mcp-health: a `PostToolUseFailure` payload for `mcp__srv__x` with a transport/auth/429/503 error puts `srv` into backoff. A following PreToolUse for `mcp__srv__y` emits advisory context naming the server and its retry time (exit 2 under `MTK_MCP_HEALTH_ENFORCE=1`). A successful PostToolUse clears the record. A non-matching error (for example input validation) records nothing. After backoff expires the call is allowed. The branch is chosen from the payload's `hook_event_name`. | `bash tests/hooks/test-mcp-health.sh` | test-run |
| SC7 | cost-tracker, given a fixture transcript with duplicated usage lines and a subagent transcript, writes a delta row whose token totals equal the per-`message.id` deduplicated sums. A second run with no new messages writes no row. An unknown model records tokens with `est_usd: null`. A missing or unreadable transcript writes nothing and exits 0. | `bash tests/hooks/test-cost-tracker.sh` | test-run |
| SC8 | `bash scripts/session-cost.sh window --since T1 --until T2 --json` sums exactly the rows inside the window and prints `not recorded` when no rows exist. | same | test-run |
| SC9 | `bash scripts/lesson-score.sh --json` scores every entry in `learnings.jsonl` between 0.05 and 0.95. A lesson with recurrence 3, a recent reconfirmation and recalls outranks an old, never-recalled, expired lesson with a stale anchor. The default output lists lowest scores first. | `bash tests/hooks/test-lesson-score.sh` | test-run |
| SC10 | `docs/ecc-harness-adapters-2026-09.md` exists, and the migration plan's WS2, WS3, WS6 and WS7 sections each link to it. | `grep -c 'ecc-harness-adapters' docs/plans/2026-09-21-multi-harness-migration.md` ≥ 4 | cli-stdout |
| SC11 | All new hooks are wired in both `hooks/hooks.json` and `.claude/settings.json`, every new file is in the manifest, the three version files read 7.36.0, and the toolkit validator passes. | `bash scripts/validate-toolkit.sh` → "Toolkit validation passed" | script-output |
| SC12 | Every existing hook test still passes after the wiring change. | `for t in tests/hooks/test-*.sh; do bash "$t" >/dev/null || echo "FAIL $t"; done` prints nothing | test-run |

## Architecture and design

### B1 — `hooks/config-guard.sh` (PreToolUse `Edit|Write`)

- **Protected basenames** (matched case-insensitively):
  - .NET: `.editorconfig`, `.globalconfig`, `*.globalconfig`, `Directory.Build.props`, `Directory.Build.targets`, `*.csproj`, `*.fsproj`, `*.vbproj`, `*.ruleset`, `stylecop.json`
  - JS/TS: `.eslintrc*`, `eslint.config.*`, `biome.json`, `biome.jsonc`, `tsconfig.json`, `tsconfig.*.json`, `.stylelintrc*`
  - Python: `ruff.toml`, `.ruff.toml`, `pyproject.toml`, `setup.cfg`, `.flake8`, `tox.ini`, `mypy.ini`, `.mypy.ini`, `.pylintrc`, `pylintrc`
  - Other: `.shellcheckrc`, `.markdownlint*`
  - Ignore files: `.eslintignore`, `.prettierignore`, `.stylelintignore`, `.markdownlintignore`
- **Before and after text:**
  - Edit: before = `old_string`, after = `new_string`.
  - Write to an existing file: before = contents on disk, after = `content`.
  - Write to a missing file: allowed.
- **Weakening signals.** Each is counted on both texts; the edit is denied when the after-count exceeds the before-count.
  - **W1, suppression codes.** Tokens shaped like rule IDs (`[A-Za-z]{1,6}[0-9]{2,5}`) on lines whose key names a suppression list: `NoWarn`, `WarningsNotAsErrors`, `ignore`, `extend-ignore`, `per-file-ignores`, `disable`, `suppress`.
  - **W2, disabled values:**
    - `dotnet_(diagnostic|analyzer_diagnostic)….severity = none|silent|suggestion`
    - quoted `"off"` / `'off'`
    - `TreatWarningsAsErrors|EnforceCodeStyleInBuild|RunAnalyzers|RunAnalyzersDuringBuild|EnableNETAnalyzers|strict|noImplicitAny|strictNullChecks|warn_unused_ignores|disallow_untyped_defs` followed by `false`
    - `AnalysisLevel`/`AnalysisMode` set to `none`
    - `ignore_errors = true`
    - `"recommended": false`
    - `<WarningLevel>0`
    - `<Nullable>disable`
  - **W3, ignore files.** Non-blank, non-comment lines added.
- **Engineer approval list:** `.mtk/config-guard-allow`, one repo-relative path per line, honoured only if modified within the last 24h. The deny message tells the model to stop and ask the engineer. Following `read-guard`, it does not print how to approve, and Edit/Write to the list file is denied. A Bash write to the list is out of reach; this guard targets drift, not a determined adversary, and that gap goes in the Not-Proved ledger.
- **Knobs:** `MTK_CONFIG_GUARD=0` turns it off.
- **Failure handling:** fails open on an empty or unparseable payload. This is a drift guard, not a security gate.

### B2 — `hooks/fact-force-guard.sh`

- **Two modes, chosen from `hook_event_name`:**
  - **Record** (PostToolUse `Grep|Glob|Bash`): appends the search text, lowercased, to a session file. Grep records `pattern`, `path` and `glob`; Glob records `pattern` and `path`. Bash is recorded only when the command runs `grep`, `rg`, `ag`, `git grep`, `git log -S/-G` or `find` at command position.
  - **Check** (PreToolUse `Edit|Write`): applies only to an existing, in-repo file with a code extension. Covered extensions: `.cs .fs .vb .py .ts .tsx .js .jsx .mjs .cjs .go .rs .java .kt .swift .rb .php .sh`. Skipped: test paths (`test/`, `tests/`, `*Tests.cs`, `*.test.*`, `*.spec.*`, `test_*.py`, `*_test.*`), `.mtk/`, `tasks/`, `docs/`.
- **Evidence:** the lowercased stem (basename minus its last extension, at least 3 characters) appears in any recorded search text. Shorter stems skip the check.
- **No evidence and not yet nudged for this file:** advisory `additionalContext` naming the file and the grep to run. With `MTK_FACT_FORCE_ENFORCE=1`, `mtk_deny` instead. Either way the file is marked, so the retry passes; the model is never looped (ECC #2142).
- **Session files:** `$TMPDIR/mtk-factforce-<project-cksum>-<session-key>.{search,nudged}`. The session key is `session_id` from the payload, sanitized, or today's date when absent.
- **Knobs:**
  - `MTK_FACT_FORCE=0` turns it off.
  - `MTK_FACT_FORCE_MAX_NUDGES` (default 5) caps advisory nudges per session.

### B3 — `hooks/mcp-health.sh` (PreToolUse, PostToolUse and PostToolUseFailure, matcher `mcp__.*`)

- **Server name:** the second `__` segment of `tool_name`, validated against `^[A-Za-z0-9_-]{1,64}$`.
- **PostToolUseFailure:** classifies `error` by regex:
  - `auth`: 401, unauthorized, auth failed, token expired
  - `forbidden`: 403
  - `rate-limit`: 429, rate limit
  - `unavailable`: 503, unavailable, overloaded
  - `transport`: ECONNREFUSED, ENOTFOUND, timed out, socket hang up, connection closed, not connected
  - Anything else records nothing (a tool-level error is not a server-health problem).
  - On a match: `failures += 1`, `next_retry = now + min(base × 2^(failures-1), max)`.
- **PostToolUse:** deletes the server's record.
- **PreToolUse:** when `now < next_retry`, emits advisory context: server, failure count, code, seconds until retry, and "prefer non-MCP fallbacks (Bash/scripts) meanwhile". With `MTK_MCP_HEALTH_ENFORCE=1` it denies instead. Once backoff has expired, the call is allowed as a probe.
- **State:** `$TMPDIR/mtk-mcp-health-<project-cksum>`, tab-separated. Written tmp-then-rename.
- **Knobs:** `MTK_MCP_HEALTH=0`, `MTK_MCP_HEALTH_ENFORCE=1`, `MTK_MCP_HEALTH_BACKOFF_BASE_SECS` (30), `MTK_MCP_HEALTH_BACKOFF_MAX_SECS` (600).
- **Not ported:** ECC's probing and reconnect, because spawning arbitrary MCP commands from a hook breaks S3.3 and is unsafe.

### B4 — cost tracking

- **`hooks/cost-tracker.sh` (Stop, async):**
  - Reads `transcript_path` and `session_id` from the payload, then calls `scripts/session-cost.sh record`.
  - Off with `MTK_COST_TRACKER=0`.
  - Fails silent: the transcript format is internal to Claude Code and not a stable contract (verified from the hooks/sessions docs, 2026-09-23).
- **`scripts/session-cost.sh`:**
  - A bash wrapper around embedded python3, which S3.3 allows.
  - **`record`:**
    1. Parse the main transcript plus `<transcript-dir>/<session_id>/subagents/*.jsonl` (layout verified on this machine).
    2. Keep `type=="assistant"` lines that have `message.usage`, deduplicated by `message.id` (last line wins).
    3. Sum `input_tokens`, `output_tokens`, and `cache_read_input_tokens`. Cache writes come from `cache_creation.ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`; when that split is absent, all of `cache_creation_input_tokens` counts as the 5-minute tier.
    4. Compare with the per-transcript cumulative totals in `.mtk/metrics/sessions/<session>.json`, and append one delta row per source to `.mtk/metrics/costs.jsonl`: `{ts, session_id, source, model, tokens{…}, est_usd, unpriced_tokens, pricing_as_of}` (`unpriced_tokens` > 0 when part of a delta used an unpriced model; *amended 2026-09-23*). If a cumulative total goes down (a rewritten transcript), the new total is taken as the delta.
    5. When no delta is non-zero, write no row.
  - **`window --since --until [--json]`:** sums rows inside the window, or prints `not recorded`.
  - **`--help`**.
- **`hooks/lib/model-pricing.tsv`:** `model_id` (exact match after stripping a trailing `[…]` context suffix and `-YYYYMMDD` date suffix; *amended 2026-09-23 — longest-prefix matching would price `claude-fable-5-1` as `claude-fable-5`*), then per-MTok `input`, `output`, `cache_write_5m`, `cache_write_1h` and `cache_read`, with an `# as_of: YYYY-MM-DD` header. Prices are taken from the `claude-api` skill's pricing reference at implementation time, not from memory. An unknown model gets `est_usd: null`; ECC's silent default to Sonnet pricing is not ported.
- **`.claude/references/implement-archive-receipt.md`:** the receipt gains a **cost** field. It holds `session-cost.sh window` output over the workflow's first→last event timestamps, labelled "API-equivalent estimate; attribution granularity is one Stop". It is `not recorded` when there are no rows.

### B5 — `scripts/lesson-score.sh` (bash + embedded python3)

Inputs:
- `.mtk/learnings.jsonl`
- `.mtk/recall-log.jsonl` (the `surfaced[]` ids)
- `lesson-anchors.sh` stale findings, mapped to lessons by title

Score, clamped to [0.05, 0.95]:
- **Base by `recurrence.count`:** 1 → 0.30, 2 → 0.50, 3–5 → 0.70, 6+ → 0.85
- **+0.05 per recall** in the last 90 days (cap +0.15)
- **+0.10** if `validity.reconfirmed_at` is within 180 days
- **−0.02 per week** since the last signal (max of `captured_at`, `recurrence.last_seen_at`, `reconfirmed_at` and the last recall), after a 4-week grace
- **−0.20** if `validity.expired` is true or `expires_at` has passed
- **−0.20** if it has a stale anchor

Output: a table with `due` lessons first, then ascending score (`--json` for machines). Each row gives `id`, `title`, `score`, the signals behind it, and `due` when the score is below 0.40 **and** the last signal is older than the 4-week grace period, so a fresh lesson is never due. *(Amended 2026-09-23 after Stage 1 review F004, engineer-approved: without the grace condition every new one-off lesson was due on day 0 and refresh triaged newest-first.)*

`lesson-refresh` step 2 runs it and triages from the top. The score only ranks; it never decides a verdict.

### B6 — reference doc

`docs/ecc-harness-adapters-2026-09.md` covers:
- **Adapter layout:** a single source tree with a per-harness adapter per target (`rootSegments`, install-state, `planOperations`); module manifest and install profiles; hand-curated skill subset for Codex.
- **Capability map.**
- **Memory Vault trust model:**
  - `project`/`team`/`user` scopes
  - create-only, `trust: unreviewed`
  - fail-closed `.gitignore`
  - `source_harness` identity bound at server launch
  - an incomplete scan is an error, never an absence
- **What MTK should and should not take** for WS2 (paths/env), WS3 (hook protocols), WS6 (packaging) and WS7 (setup/doctor).

The migration plan's four WS sections each get a one-line "Reference:" link.

### B7 — wiring and release

- **Hook wiring:** `hooks/hooks.json` and `.claude/settings.json` gain:
  - config-guard and the fact-force check under PreToolUse `Edit|Write`
  - the fact-force record under PostToolUse `Grep|Glob|Bash`
  - mcp-health under PreToolUse, PostToolUse and PostToolUseFailure `mcp__.*`
  - cost-tracker under Stop, async
- **Documentation:**
  - `env-knobs.md` gets a row for each new knob.
  - `docs/how-it-works.data.json` gains feature entries for the four hooks and two scripts; `docs/how-it-works.html` is regenerated with `python3 docs/build-how-it-works.py`. `docs/harness-support-matrix.md` is deliberately untouched: its hook table records hooks observed firing in the WS0 Codex spike, and these hooks were not observed.
- **Release bookkeeping:**
  - manifest entries for every new shipped file
  - versions bumped to 7.36.0 in all three files
  - a CHANGELOG entry
  - `checksums.sha256` regenerated last

## Security and compliance impact

`none`. These are toolkit guards and telemetry.
- **cost-tracker** writes only token counts and model IDs to gitignored `.mtk/metrics/`. It copies no transcript content.
- **fact-force** stores search strings in `$TMPDIR` for the day. They are already present in the session transcript.
- **config-guard** strengthens a quality gate, and its approval path is human-only by construction (no self-approval hint).

## Constitution Check

- **C0.2:** every new file under `hooks/`, `scripts/`, `tests/` and `.claude/` gets a manifest entry. The `docs/ecc-harness-adapters-2026-09.md` note follows the precedent of the untracked `docs/competitive-analysis-*.md` notes; B7 confirms the validator's coverage rule accepts it.
- **C0.5 / S3.1 / S3.2:** new hooks and scripts use `#!/usr/bin/env bash` and `set -euo pipefail`, and are `chmod +x`.
- **S3.3:** coreutils, grep, sed, awk and git only, plus python3 (accepted baseline) in the two scripts, with a clear exit-2 message when python3 is missing. There is no jq and no node.
- **S3.4:** every knob is read as `"${VAR:-}"`.
- **S3.6:** hooks are wired in both `hooks.json` (`${CLAUDE_PLUGIN_ROOT}`) and `settings.json` (`$CLAUDE_PROJECT_DIR`). The double-run guard is `mtk_is_redundant_plugin_invocation`.
- **S3.13:** all new hooks are Tier 1 (advisory context or exit 2). None writes queue entries.
- **S3.17:** there are no pipes into early-exiting consumers under pipefail. The code uses `grep -q … <(…)` or captured-variable `case` matching.
- **S1.17:** repo-relative paths go through `mtk_repo_relative_path`, never a bare prefix strip.
- **C0.8:** `validate-toolkit.sh` must pass (SC11).
- **C0.1 / S4.6 / S4.7:** versions bumped in all three files, with `manifest.updated` set.
- **S4.11:** checksums regenerated as the last change.

## Change manifest

| Path | Action | Batch |
|---|---|---|
| `hooks/config-guard.sh` | create | B1 |
| `tests/hooks/test-config-guard.sh` | create | B1 |
| `tests/hooks/test-deny-ergonomics.sh` | modify | B1 |
| `hooks/fact-force-guard.sh` | create | B2 |
| `tests/hooks/test-fact-force-guard.sh` | create | B2 |
| `hooks/mcp-health.sh` | create | B3 |
| `tests/hooks/test-mcp-health.sh` | create | B3 |
| `hooks/cost-tracker.sh` | create | B4 |
| `scripts/session-cost.sh` | create | B4 |
| `hooks/lib/model-pricing.tsv` | create | B4 |
| `tests/hooks/test-cost-tracker.sh` | create | B4 |
| `.claude/references/implement-archive-receipt.md` | modify | B4 |
| `scripts/lesson-score.sh` | create | B5 |
| `tests/hooks/test-lesson-score.sh` | create | B5 |
| `.claude/skills/lesson-refresh/SKILL.md` | modify | B5 |
| `docs/ecc-harness-adapters-2026-09.md` | create | B6 |
| `docs/plans/2026-09-21-multi-harness-migration.md` | modify | B6 |
| `hooks/hooks.json` | modify | B7 |
| `.claude/settings.json` | modify | B7 |
| `.claude/references/env-knobs.md` | modify | B7 |
| `docs/how-it-works.data.json` | modify | B7 |
| `docs/how-it-works.html` (regenerated) | modify | B7 |
| `.claude/manifest.json` | modify | B7 |
| `.claude-plugin/plugin.json` | modify | B7 |
| `.claude-plugin/marketplace.json` | modify | B7 |
| `CHANGELOG.md` | modify | B7 |
| `checksums.sha256` | modify | B7 |

## Test manifest

| Test | Covers |
|---|---|
| `tests/hooks/test-config-guard.sh` | SC1, SC2, SC3 |
| `tests/hooks/test-deny-ergonomics.sh` | SC3 |
| `tests/hooks/test-fact-force-guard.sh` | SC4, SC5 |
| `tests/hooks/test-mcp-health.sh` | SC6 |
| `tests/hooks/test-cost-tracker.sh` | SC7, SC8 |
| `tests/hooks/test-lesson-score.sh` | SC9 |
| `grep -c ecc-harness-adapters docs/plans/2026-09-21-multi-harness-migration.md` | SC10 |
| `scripts/validate-toolkit.sh` | SC11 |
| full `tests/hooks/test-*.sh` loop | SC12 |

## Implementation batches

The per-file detail is in the plan. B1–B6 create disjoint files and can run in parallel (wave 0). B7 runs alone (wave 1) because it touches every shared file.

## Requirements

### Ubiquitous
- The config-guard hook shall deny an Edit or Write to a protected config file when the edit increases the count of suppression codes, disabled-value settings, or ignore-file entries.
- The config-guard hook shall allow an edit to a protected config file that increases none of those counts.
- The cost tracker shall count each `message.id` exactly once per transcript.
- The lesson scorer shall emit a score between 0.05 and 0.95 for every lesson in `learnings.jsonl`.

### Event-driven
- When an Edit or Write targets an existing in-repo code file whose stem appears in no search recorded this session, the fact-force guard shall emit an advisory naming the file, once per file.
- When a `PostToolUseFailure` event reports a transport, auth, forbidden, rate-limit or unavailable error for an MCP tool, the mcp-health hook shall record a failure for that server and set its next retry time with exponential backoff.
- When a PostToolUse event succeeds for an MCP tool, the mcp-health hook shall clear that server's failure record.
- When the Stop hook runs with a readable transcript, the cost tracker shall append one delta row per transcript source whose token totals changed since the previous Stop.
- When the Phase 7.5 receipt is written, the receipt shall include the cost-window output for the workflow's event time range, or `not recorded`.

### State-driven
- While a server's next retry time is in the future, the mcp-health hook shall emit an advisory on PreToolUse calls to that server.
- While `MTK_FACT_FORCE_ENFORCE=1`, the fact-force guard shall deny the first unevidenced edit of each file instead of advising.
- While `MTK_MCP_HEALTH_ENFORCE=1`, the mcp-health hook shall deny calls to a server in backoff instead of advising.

### Optional
- Where `MTK_CONFIG_GUARD=0`, `MTK_FACT_FORCE=0`, `MTK_MCP_HEALTH=0` or `MTK_COST_TRACKER=0` is set, the corresponding hook may exit 0 without reading its payload.

### Unwanted behaviours
- If the hook payload is empty or unparseable, then config-guard, fact-force-guard and mcp-health shall exit 0.
- If the transcript is missing, unreadable or unparseable, then the cost tracker shall write no row and exit 0.
- If a model has no pricing entry, then the cost tracker shall record `est_usd` as null rather than applying another model's price.
- If an Edit or Write targets `.mtk/config-guard-allow`, then config-guard shall deny it.

## Risks and assumptions

- **R1 — false positives in config-guard.** A W1 token-shape match on a non-code value (for example `ignore = ["build2020"]`) could deny a harmless edit. *Mitigation:* codes are counted only on suppression-key lines, the approval list plus off-switch exist, and allow cases are pinned in tests (lesson L-020: a flaky gate gets skipped).
- **R2 — ECC-style fact-force loops (#2142).** *Mitigation:* advisory by default, once per file, capped per session, and a retry always passes under enforce.
- **R3 — transcript format drift.** *Mitigation:* the parser is defensive, and failures record nothing rather than zeros. The receipt says `not recorded`.
- **R4 — PostToolUseFailure payload.** Verified against the hooks docs 2026-09-23: fields `tool_name`, `tool_input`, `tool_use_id`, `error`, `hook_event_name`. *Not proved live* until a real MCP failure fires on this machine; the Not-Proved ledger records this.
- **R5 — pricing staleness.** *Mitigation:* the table carries `as_of`, rows carry `pricing_as_of`, and the output is labelled an estimate.
- **R6 — dirty worktree.** None at spec time (`git status --porcelain` empty).
- **A1** Parallel-batch partial application (ECC #3136) does not apply to the advisory default. Under enforce, the deny message carries the standard "batched calls were CANCELLED" suffix from `mtk_deny`.

## Out of scope

- ECC's MCP probe and reconnect
- GateGuard's Bash destructive-command gate (security-gate covers it)
- An instinct auto-extraction observer
- A Memory Vault implementation (reference doc only)
- README feature copy
- A per-model context-tier price (the >200K 2× tier)

## Open questions

None. The ambiguity gate was answered (D1–D4).

## Prior Work Check

- **Grep results:** `grep -rliE 'cost_usd|pricing|input_tokens' hooks scripts` found no hits. `mcp__|PostToolUseFailure` hits only `scripts/repomap.sh`, and that is unrelated. `NoWarn|TreatWarningsAsErrors|severity *= *none` found no hits.
- **Scoring:** `learnings.sh query` has a *relevance* score (severity, recurrence, proximity) for retrieval. It is not a staleness/confidence score, so B5 does not duplicate it.
- **Receipt timing:** already present in `implement-archive-receipt.md` (event-timestamp derived). B4 adds only cost, not timing.
- **Result:** no BLOCK; one FLAG, the receipt timing overlap, which was acknowledged and scoped out.
