# Plan — Six borrows from ECC

Spec: `docs/specs/2026-09-23-ecc-borrows.md` (+ `.json` sidecar)
Branch: `feat/ecc-borrows` · Scope: new-feature · security_impact: none

## Waves

- **W0 (parallel):** B1 · B2 · B3 · B4 · B5 · B6. Each creates or modifies only its own files, and no batch reads a type another creates.
- **W1:** B7. Wiring, manifest, versions, changelog and checksums, which touch every shared file.

B1–B6 do **not** wire hooks or add manifest entries. Their checkpoint is their own test. The validator runs in B7, because an unwired hook fails its wiring check.

## Conventions every batch follows

- **Hook skeleton:** copy the header of `hooks/interactive-guard.sh`: shebang, `set -euo pipefail`, the `_mtk_hook_diag` trap, sourcing `hooks/lib/hook-io.sh`, `mtk_is_redundant_plugin_invocation "$0" && exit 0`, the kill-switch check, then a bounded `mtk_read_payload`.
- **Output:** use `mtk_extract_tool_name` / `mtk_extract_file_path` / `mtk_extract_json_string`, `mtk_emit_additional_context <Event> <text>` for advice, and `mtk_deny` for blocks. No jq (S3.3).
- **Paths:** repo-relative via `mtk_repo_relative_path`, never a prefix strip (S1.17).
- **Pipes:** no pipes into `grep -q`/`head` under pipefail (S3.17). Use `grep -q … <<<"$var"` or `case`.
- **Tests:** follow `tests/hooks/test-interactive-guard.sh` (`run_guard` + `expect` label/want/got, `fails` counter in the parent shell, and `exit $fails`). Point `TMPDIR` at a `mktemp -d` so state never leaks between cases or into the real session.
- **Permissions:** `chmod +x` on every new hook, script and test.

## Batches

### B1 — config-guard

**Files:**
- `hooks/config-guard.sh`
- `tests/hooks/test-config-guard.sh`
- `tests/hooks/test-deny-ergonomics.sh` (add one case)

**Design:** spec §B1.
- Build the protected-name check as one lowercased-basename `case` (glob patterns work in `case`).
- Count W1/W2/W3 with `awk` on here-strings: one function `count_signals <text>` that prints `w1 w2 w3`.
- Before/after text: for Edit, extract `old_string` and `new_string` with `mtk_extract_json_string` (it handles escaped quotes). For Write, `content`, with the before text from disk when the file exists.
- `replace_all` needs no special case, because it scales both sides equally.
- **Deny text:** `CONFIG-GUARD: this edit weakens <file> (<signal>: <before>→<after>)`. Then: "Fix the code the analyzer flags instead of silencing it. If the engineer explicitly asked for this suppression, STOP and ask them to approve it — do not work around this guard." Call `mtk_deny` with an empty toggle, following read-guard, so no self-service hint is printed.
- **Approval list:** `${CLAUDE_PROJECT_DIR:-$REPO_ROOT}/.mtk/config-guard-allow`. The path is honoured only when the file is modified within 24h (`find -mmin -1440`) and contains the exact repo-relative path.
- An Edit/Write whose REL_PATH is `.mtk/config-guard-allow` is always denied.

**Test cases:**
- **Deny (exit 2):** NoWarn add in props, editorconfig severity none, TWAE false in csproj, eslint "off", ruff ignore add, .eslintignore line add, Write existing props that adds NoWarn, uppercase `DIRECTORY.BUILD.PROPS`, edit of allow-list file, weakening edit with a stale allow list (mtime >24h, simulated with `touch -t`).
- **Allow (exit 0):**
  - severity `error`→`warning`. `warning` is deliberately not a W2 value, so the guard does not over-block; the hook header documents this.
  - stricter rule added
  - version bump in csproj
  - new `.editorconfig` via Write to a missing path
  - `src/Foo.cs`
  - path on a fresh allow list
  - `MTK_CONFIG_GUARD=0`
  - empty payload, garbage payload
- **Extraction round-trip (plan-gap note):** an Edit whose `old_string`/`new_string` contain an escaped quote and `\n`-escaped multi-line text, with the weakening on the third line, must still be detected. This proves `mtk_extract_json_string` for this new use.
- **Deny-ergonomics:** add a config-guard case asserting the suffix and **no** `disable this guard` line.

**Verify:** `bash tests/hooks/test-config-guard.sh && bash tests/hooks/test-deny-ergonomics.sh`

### B2 — fact-force-guard

**Files:**
- `hooks/fact-force-guard.sh`
- `tests/hooks/test-fact-force-guard.sh`

**Design:** spec §B2.
- Mode comes from `hook_event_name`: `PostToolUse` means record, `PreToolUse` means check. An unknown event exits 0.
- **State:** `$TMPDIR/mtk-factforce-<cksum(repo root)>-<key>`, where key is `session_id` with `[^A-Za-z0-9_-]` stripped, falling back to `date +%Y%m%d`.
- **Record:** append one line per search, lowercased, and cap the file at 2000 lines (`tail -n 2000` to tmp, then mv).
- **Check order:** kill-switch → tool is Edit/Write → file exists → in repo (REL_PATH not absolute) → code extension → not exempt → stem length ≥ 3 → evidence (`grep -qiF "$stem" "$search_file"`, which is a file argument, not a pipe) → already nudged → nudge cap → emit/deny, then mark nudged.
- **Advisory text:** `FACT-FORCE: first edit of <rel> this session and no search mentioned "<stem>". Before changing its behaviour or signature, find its dependents — e.g. grep -rn "<stem>" . — then continue. (advisory; MTK_FACT_FORCE_ENFORCE=1 makes this a one-time deny)`.
- **Enforce:** `mtk_deny` with the toggle `MTK_FACT_FORCE_ENFORCE=0 (or MTK_FACT_FORCE=0)`.

**Test cases:**
- advisory emitted on first edit, then silent on second
- silent after a Grep record with the stem
- silent after a Bash `rg Stem` record
- a Bash `echo stem` is **not** recorded
- new-file Write is silent
- `docs/x.md`, `tests/test_x.py`, `FooTests.cs` are silent
- an out-of-repo path is silent
- `MTK_FACT_FORCE=0` is silent
- the nudge cap holds: the 6th distinct file is silent with cap 5
- enforce: exit 2, then 0 on retry
- different `session_id`s are independent

**Verify:** `bash tests/hooks/test-fact-force-guard.sh`

### B3 — mcp-health

**Files:**
- `hooks/mcp-health.sh`
- `tests/hooks/test-mcp-health.sh`

**Design:** spec §B3.
- **State:** `$TMPDIR/mtk-mcp-health-<cksum(repo root)>`, tab-separated: `server failures next_retry code ts`. Updates rewrite the whole file through tmp+mv.
- **Error classification:** `grep -Eiq` on a here-string of the extracted `error` field. When `error` is absent, fall back to `tool_response`.
- **Time:** `date +%s`. Tests inject time with `MTK_MCP_HEALTH_NOW` (an undocumented test seam, named in the hook header).

**Test cases:**
- transport failure → next Pre is advisory, names srv and "retry in"
- enforce → exit 2
- a second failure doubles the backoff (check the recorded `next_retry`)
- success clears the record
- a validation error records nothing
- expiry allows the call
- a non-MCP tool name is ignored
- a malformed server name is ignored
- `MTK_MCP_HEALTH=0` is silent
- a payload without `hook_event_name` exits 0

**Verify:** `bash tests/hooks/test-mcp-health.sh`

### B4 — cost tracking

**Files:**
- `hooks/cost-tracker.sh`
- `scripts/session-cost.sh`
- `hooks/lib/model-pricing.tsv`
- `tests/hooks/test-cost-tracker.sh`
- `.claude/references/implement-archive-receipt.md`

**Design:** spec §B4.
- **Pricing:** first load the `claude-api` skill and copy the current per-MTok prices for the Claude 5 family, Haiku 4.5 and the legacy Opus/Sonnet prefixes into the TSV, with `# as_of: 2026-09-23` and a source line. Do not use remembered prices.
- **`session-cost.sh`:**
  - Resolve the project root as `$CLAUDE_PROJECT_DIR` → git top-level → pwd.
  - `record --transcript P --session S [--metrics-dir D]`, where `--metrics-dir` is the test seam; the default is `<root>/.mtk/metrics`.
  - `window --since ISO --until ISO [--json] [--metrics-dir D]`.
  - python3 is required, with an exit-2 message when missing.
  - Atomic writes (tmp + `os.replace`) for the snapshot; append-only for `costs.jsonl`.
- **`cost-tracker.sh`:**
  - Kill-switch, then extract `transcript_path` and `session_id`.
  - Resolve the script `MTK_HELPER_ROOT` → `SCRIPT_DIR/../scripts` → `${CLAUDE_PLUGIN_ROOT}/scripts`.
  - Run `bash … record … >/dev/null 2>&1 || true`.
- **Fixtures (generated inline by the test in a `mktemp -d`, following the hook-test convention; no fixture files):**
  - The main transcript has 3 assistant messages, and one of them appears on 3 lines with the same usage (the duplicate-content-block case).
  - One message uses an unknown model `claude-test-9`.
  - The subagent transcript has 1 message.
  - Non-assistant lines and a malformed JSON line are included and skipped.
- **Receipt reference:** add a `cost` bullet after `timing`. It holds the output of `bash scripts/session-cost.sh window --since <first event ts> --until <last event ts>`, copied verbatim, labelled "API-equivalent estimate (Stop-granular)", and written as `not recorded` when the tracker was off or no rows fell in the window.

**Test cases:**
- deduplicated totals are exact per source
- `est_usd` is computed for a known model and null for `claude-test-9`
- a second record writes 0 new rows
- appending a message to the fixture copy yields a delta row with only the new tokens
- a missing transcript writes no rows and exits 0
- the window includes/excludes by ts
- an empty window prints `not recorded`
- `MTK_COST_TRACKER=0` means the hook writes nothing

**Verify:** `bash tests/hooks/test-cost-tracker.sh`

### B5 — lesson-score

**Files:**
- `scripts/lesson-score.sh`
- `tests/hooks/test-lesson-score.sh`
- `.claude/skills/lesson-refresh/SKILL.md`

**Design:** spec §B5.
- **Arguments:** `--learnings F`, `--recall-log F`, `--anchors-output F|-` (test seams; default is to run `lesson-anchors.sh` and map its `STALE-*` lines to lessons by heading/title), `--now ISO` (test seam), `--json`.
- **Text output:** columns `score  due  id  title  signals`, sorted ascending.
- **SKILL.md step 2:** replace "Prioritize by due-ness: …oldest…" with running `bash scripts/lesson-score.sh` and triaging from the lowest score, keeping the "data informs, never decides" sentence.

**Test cases:**
- range check on a 4-entry fixture written into a tmpdir
- expected ordering (strong > medium > weak > rotten)
- the `due` flag appears below 0.40
- recall counting ignores recalls older than 90 days
- a missing recall log is tolerated
- a missing learnings file exits 0 with "no lessons"

**Verify:** `bash tests/hooks/test-lesson-score.sh`

### B6 — harness adapter reference

**Files:**
- `docs/ecc-harness-adapters-2026-09.md`
- `docs/plans/2026-09-21-multi-harness-migration.md`

**Design:** spec §B6.
- **Doc content:** the research findings for §5, with ECC paths cited as `ECC:<path>:<line>` at commit bf70150. For each of WS2, WS3, WS6 and WS7, a "Take / Adapt / Skip" table.
- **Plan edits:** add a single `Reference: [ECC harness adapters](../ecc-harness-adapters-2026-09.md) — <one clause>` line under each of those four WS headings. Append-only; no other plan text changes.

**Verify:** `test -f docs/ecc-harness-adapters-2026-09.md && grep -c ecc-harness-adapters docs/plans/2026-09-21-multi-harness-migration.md` (≥ 4)

### B7 — wiring and release

**Depends:** B1–B6.

**Files:**
- `hooks/hooks.json`
- `.claude/settings.json`
- `.claude/references/env-knobs.md`
- `docs/how-it-works.data.json`
- `docs/how-it-works.html` (regenerated)
- `.claude/manifest.json`
- `.claude-plugin/plugin.json`
- `.claude-plugin/marketplace.json`
- `CHANGELOG.md`
- `checksums.sha256`

**Steps:**
1. **Wiring.** In both files, mirroring the existing entries' shape and anchors:
   - PreToolUse `Edit|Write`: append config-guard, then fact-force-guard, after scope-guard (timeout 5).
   - PostToolUse: a new `Grep|Glob|Bash` entry for fact-force-guard (timeout 3).
   - PreToolUse and PostToolUse `mcp__.*`: mcp-health (timeout 3).
   - A new `PostToolUseFailure` block with matcher `mcp__.*`: mcp-health (timeout 3).
   - Stop: cost-tracker (`async: true`, timeout 30).
2. **`env-knobs.md`:** one row each for `MTK_CONFIG_GUARD`, `MTK_FACT_FORCE`/`_ENFORCE`/`_MAX_NUDGES`, `MTK_MCP_HEALTH`/`_ENFORCE`/`_BACKOFF_*` and `MTK_COST_TRACKER`.
3. **Feature catalog:** add entries to `docs/how-it-works.data.json` for the four hooks and two scripts, following existing hook entries, then run `python3 docs/build-how-it-works.py` and `--check`. Leave `harness-support-matrix.md` alone (its hook table is live WS0 observation).
4. **Manifest:** add entries for the 4 hooks, the pricing TSV, 2 scripts, 5 tests. Each entry gets `source`, `target`, `action: sync` and a one-sentence description (S1.2/S1.3).
5. **Versions:** 7.36.0 in manifest, plugin and marketplace, plus `manifest.updated`.
6. **`CHANGELOG.md`:** add a 7.36.0 entry.
7. **Validator:** `bash scripts/validate-toolkit.sh`, confirming the rule for the untracked `docs/*.md` research note (C0.2 coverage).
8. **Regression:** run the full hook-test loop.
9. **Checksums:** `bash scripts/generate-checksums.sh`, as the last change.

**Verify:** `bash scripts/validate-toolkit.sh && python3 docs/build-how-it-works.py --check && for t in tests/hooks/test-*.sh; do bash "$t" >/dev/null || echo "FAIL $t"; done`

## Commits (D4: one per borrow)

1. `feat(hooks): config-guard denies analyzer/linter weakening`
2. `feat(hooks): fact-force-guard nudges dependents search`
3. `feat(hooks): mcp-health backoff`
4. `feat(metrics): per-session token/cost tracker + receipt cost field`
5. `feat(lessons): lesson-score ranks lesson-refresh triage`
6. `docs(research): ECC harness adapters reference`
7. `chore(release): wire hooks, 7.36.0`

Each commit carries its own batch's files. B7 carries the shared files.
