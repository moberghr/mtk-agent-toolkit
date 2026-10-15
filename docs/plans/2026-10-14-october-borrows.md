# Plan — October borrows: close the "behind" table

Source: `docs/competitive-analysis-2026-10.md` (backlog P0-1 … P1-9, i.e. every row of
"Where MTK is now behind" plus the three fastest wins).
Branch: cut from `origin/main` @ `0c908ee` (PR #123 merged). Not on
`fix/config-guard-worktree-root`.
Scope: new-feature · security_impact: low (new guards; no auth/secrets paths change)
Status: **PROPOSED — not approved.** Revision 2, after a fresh plan-gap review (3 blockers,
13 should-fix, 4 nits — all folded in; see §Review log). Feed to `/mtk implement` after the
decisions below are settled; implement turns §Items into the spec and sidecar and runs the
approval gate.

## What the code check changed vs. the research note

| Item | Research note said | Code says | Effect on plan |
|---|---|---|---|
| P0-1 SubagentStart | "attacks the ~16k–27k tok/subagent re-read cost" | `build-context-pack.sh` already cut the implementer preamble 63k → 19.5k chars (Sept). | Value is **coverage**, not tokens: subagents dispatched outside `implement` get no pack, and a brief that forgets the pack path silently loses it. |
| P0-3 handoff | "session-start surfaces any handoff < 24h" | Handoffs are re-injected only on `source=compact` (`hooks/session-start:124`). Startup emits one `SESSION RECOVERY` line for a recent spec/plan/todo (`:54-72`) but never a handoff. | Branch/state filter on compact, plus a one-line *offer* appended on startup (D3). |
| P1-9 stall | "fixed cap only" | `workflow-artifact.sh remediation` already has `--score N` plateau → ESCALATE (`:436-497`); the lanes reference never passes it. | Add a separate `--open N` series and wire it. Mostly wiring. |
| ABANDON | not in MTK | `workflow-artifact.sh abandon <uuid> --reason` exists. | Nothing to build. |
| New latent bug | — | `mtk_tree_fingerprint` (`hook-io.sh:288`) hashes untracked non-ignored files, `.mtk/` included. In a repo where `.mtk/` is not gitignored (plugin-only install), any MTK state write between baseline and Stop can read as a tree change. | B5 excludes `.mtk/` from the fingerprint before any new state writer lands. |

Hook facts confirmed against the Claude Code hooks reference (2026-10-14): `SubagentStart`
exists, takes `hookSpecificOutput.additionalContext`, matches on agent type (plugin agents as
`mtk:<name>`, unanchored regex), **cannot block**. `SubagentStop` carries
`agent_transcript_path`. PreToolUse handlers accept an `if` field in permission-rule syntax
(`"Bash(git push *)"`). The ~10,000-char `additionalContext` cap is unverified — design for
≤ 4,000.

Shipped-file budget: the plugin folder is 475 files against a 512-file limit
(`CHANGELOG.md:347`); `tests/` and `evals/` are not shipped (`build-plugin-branch.sh:8`). This
plan ships 10 new files (2 hooks, 7 scripts, 1 agent) → ~485. Headroom after: ~27.

## Open decisions (default applied until answered)

| # | Decision | Default | Alternative |
|---|---|---|---|
| D1 | Release shape | **Two stacked PRs:** PR-A = 9.1.0 (B1–B6, B10-A), PR-B = 9.2.0 (B7–B9, B10-B) | One PR, one release |
| D2 | Test-tamper guard initial mode | **`shadow`** for 9.1.x; promote to `active` after ≥ 2 weeks of shadow data with < 10% false positives on manual review | `active` from day one |
| D3 | Handoff on `startup` | **One-line offer** for open handoffs on the current branch (amends S3.11) | Keep compact-only; only add the branch/state filter |
| D4 | Finding-verify stage | **Rigor HIGH/MAX only** | Every rigor level |
| D5 | Push gate default | **Advisory** (`additionalContext`), `MTK_PUSH_GATE_ENFORCE=active` to deny | Deny by default |
| D6 | Where the test-tamper check lives | **Inside `config-guard.sh`** as a second class — Edit/Write stays at 2 processes (the 8.2 budget) | Separate `hooks/test-guard.sh` |

D1–D6 are reversible. Nothing here pushes, deploys or deletes data.

---

## Items

### P0-1 — SubagentStart context

**New hook:** `hooks/subagent-context.sh`, registered on `SubagentStart` with no matcher (it
filters inside, so built-in implementers are covered too).

- **Cheap gate first.** Exit 0 unless `agent_type` matches `^mtk:` **or**
  `find "$ROOT/.mtk/workflows" -name '*.json' -mmin -10080` returns a file. Python runs only
  after that gate passes.
- **Pack line** (only when an active workflow — status `active`, `updated_at` ≤ 7 days, same
  rule as `session-start:137-164` — has `results.context_pack` pointing at an existing file):
  `Context pack: <repo-relative path> — read it instead of AGENTS.md, the stack skill and the guideline files.`
  The selection logic is copied from session-start in this release (B3 edits that file in the
  same wave); extracting a shared helper is a named follow-up.
- **Rules line.** Only the resolved constitution's `## Critical Rules` bullets, reduced to
  `<id> <first sentence>`, each capped at 200 chars. Produced by a new
  `constitution-digest.sh --ids-only` mode (the existing `--quiet` prints full bullets plus
  every tagged principle and a totals line — too much). Resolve the script as
  `"$SCRIPT_DIR/../scripts/constitution-digest.sh"`, falling back to
  `${CLAUDE_PLUGIN_ROOT}/scripts/…`; absent ⇒ omit the rules line, never fail.
- Body ≤ 4,000 chars, truncated at a rule boundary with `[+N more rules in AGENTS.md]`.
- Framed as reference, not instruction — same envelope wording as the S3.11 recovery block.
- Never blocks (the event can't). Kill-switch `MTK_SUBAGENT_CONTEXT=0`.

**Measure (receipt line):** `Read` calls on `AGENTS.md` / `CLAUDE.md` / tech-stack `SKILL.md`
inside subagent transcripts, one field run before vs after, with n.

### P0-2 — Lesson-mining hygiene

**New script:** `scripts/lesson-mine-state.sh` (python3 for hashing and JSON decode, S3.3
baseline; state under `.mtk/lessons/`):

| Subcommand | Does |
|---|---|
| `window [--days N]` | Lists transcripts with content past their watermark in `.mtk/lessons/mine-watermark.json` (`{session_file: byte_offset}`); files never seen fall back to `--days` (default 7). Prints `<session_id>\t<path>\t<from_offset>`. |
| `advance <session_file> <offset>` | Moves a watermark forward; never backward. |
| `id <text>` | Stable candidate id `mine-<sha256(lowercased, whitespace-collapsed rule text)[:12]>`. |
| `decide <id> accepted\|rejected <reason>` | Appends `- <id> <verdict> <date> — <reason>` to `.mtk/lessons/decisions.md`. Append-only. |
| `filter <id>...` | Prints only ids with no recorded decision. |
| `evidence <session_id> <quote>` | Exit 0 iff the quote occurs in a **decoded** message of that session (`json.loads` per line, then substring match on text content) — raw-JSONL `grep -F` misses quotes with `"`, newlines or non-ASCII. |

**Skill edits (`.claude/skills/lessons/SKILL.md`, mode `mine`):**
- Step 3: replace "last 7 days" with `lesson-mine-state.sh window`; `--days N` stays.
- New step between 5 and 6: drop decided candidates (`filter`). Candidates admitted only by
  **A2 or A3** (the multi-occurrence admit rules) need quotes from **≥ 2 distinct sessions**
  that pass `evidence`; the count comes from the script. A1 (engineer redirect with reason)
  and A4 stay single-session, but their quote must still pass `evidence`. A2/A3 candidates with
  one session are listed as "watching", not proposed.
- Step 7: every ruled candidate gets a `decide` line (rejects too), then `advance` per file.
- Signals (step 4): add permission/tool rejections that carried the engineer's reason.

**Rubric (`.claude/references/lesson-mining-rubric.md`):**
- Output contract (`:89`): `candidate_id` becomes the `mine-<hash12>` form above.
- Route rule: a candidate that is a fixed syntactic or API rule ("never call X", "always pass
  Y") is proposed as a check (`hooks/linter-patterns/project/`, an analyzer rule or a CI step),
  not a `tasks/lessons.md` entry. Judgement calls stay lessons.

**Schema:** `learnings.sh add --retire-when "<external condition>"` (optional string,
documented in `learnings-schema.md`); `lessons refresh` step 3 checks it and, when evaluable
locally (a pinned version moved, a referenced file is gone), proposes Retire with that
evidence. Never auto-retires.

### P0-3 — Handoff: branch-scoped, offer-not-claim

**New script:** `scripts/handoff-state.sh`:
- `list --open [--branch B] [--include-accepted-since <ISO>]` — parses YAML frontmatter of
  `docs/handoffs/*.md`, newest `mtime` first; drops past-`expires`. Legacy files (no
  frontmatter) count as open, branch unknown, **only when modified < 24h** (today's bound).
- `accept <file>` — rewrites only the `state:` line to `accepted` and adds `accepted_at:`.
- `expire <file>` — rewrites only the `state:` line.

**Handoff template (`.claude/skills/handoff/SKILL.md`):**
```yaml
---
state: open            # open | accepted | expired
branch: <git branch --show-current>
worktree: <git rev-parse --show-toplevel>   # absolute path is fine: docs/handoffs/ is gitignored (SKILL.md:22)
expires: <date +14 days>
---
```
plus a step: "When you resume from a handoff, run `handoff-state.sh accept <file>`."

**`hooks/session-start`** (resolve the script via `"$SCRIPT_DIR/../scripts"` then
`${CLAUDE_PLUGIN_ROOT}/scripts`; absent ⇒ today's behaviour):
- `compact`: replace `find -mtime -1 | awk NR==1` with the first line of
  `list --open --branch <current> --include-accepted-since <session start>` — a handoff
  accepted earlier in this session stays visible after compaction, when it matters most.
- `startup` (D3): append to `RECOVERY_MSG` (after the spec/plan/todo line, never replacing
  it) exactly one line, token `HANDOFF OFFER:` (never `POST-COMPACTION`, which
  `test-session-start-compact-framing.sh:50-52` forbids on startup):
  `HANDOFF OFFER: open handoff for this branch at <path> (<date>) — read it if you are picking this work up.`
  Nothing for other branches; nothing when none match.
- S3.11's last sentence amended: startup may carry exactly that one offer line.

### P0-4 — Instruction load checks

**New script:** `scripts/check-instruction-load.sh [--json]`, exit 0 clean / 1 findings / 2
usage:

| Code | Check |
|---|---|
| `CODEX-BYTES` | For each directory containing an `AGENTS.md`, the root→that-dir concatenated chain (`AGENTS.override.md` preferred where present) exceeds `MTK_CODEX_DOC_MAX_BYTES` (default 32768). Codex truncates silently. |
| `SHADOWED-AGENTS` | `AGENTS.md` exists but `bash scripts/resolve-constitution.sh` resolves to `CLAUDE.md` — Claude Code never reads the AGENTS.md. Reuses the resolver; no rule re-implementation. |
| `GLOBS-NOT-PATHS` | A `.claude/rules/*.md` has `globs:` frontmatter and no `paths:` — Claude Code ignores it (Cursor key). |
| `LOCAL-UNIGNORED` | `CLAUDE.local.md` exists and `git check-ignore` says it is not ignored. |

**Wiring:** `instructions` audit step 1 runs it; `setup-bootstrap` runs it after generating
AGENTS.md (finding → fix before writing the PR); `mtk-doctor` health mode WARNs on any finding
(B10-A).

**Audit verdict:** `instructions` audit step 3 ("Judge what scripts cannot") gains one verdict:
**Move → <named owner>** (README, a rule file, a skill, the spec) for a line that is true but
belongs elsewhere, with the test "would a newcomer act differently because of this line?".

### P1-5 — Test-tamper class in config-guard (D6)

**Restructure `hooks/config-guard.sh` around `CLASS=config|test`** (today `MODE` comes from
`BASE_LC` only and `[ -n "$MODE" ] || exit 0` at `:127-138` — test files never get a mode):

- **Precedence:** config class wins (`Foo.Tests/Foo.Tests.csproj` stays a config file, `:132`).
- **Test class** only for code extensions (`.cs .fs .vb .py .ts .tsx .js .jsx`) **and** a
  test-shaped **repo-relative** path (`REL_PATH`, `:101` — never the absolute path, or a repo
  checked out under `~/tests/` classifies everything as a test): basename `*Tests.cs`,
  `*Test.cs`, `test_*.py`, `*_test.py`, `*.test.*`, `*.spec.*`; or a path segment named
  `tests`, `test`, `__tests__`, or ending `.Tests` / `.Test`.
- **Allow-list protection stays first and unconditional** (`:110-125`, plain `mtk_deny`,
  never gated).
- **Separate awk** `count_test_signals` (the existing `count_signals` at `:152-239` is keyed to
  config modes). awk has no `\b`; every token uses an explicit boundary class
  `(^|[^A-Za-z0-9_.])`.

| Code | Signal (fires when after > before, unless noted) |
|---|---|
| `T1-SKIP` | `[Fact(Skip`, `[Theory(Skip`, `[Ignore]`, `[Ignore(` (not `[IgnoreDataMember`), `Skip =`, `@pytest.mark.skip`, `pytest.skip(`, `@unittest.skip`, `it.skip(`, `describe.skip(`, `test.skip(`, `xit(`, `xdescribe(`, `.only(` |
| `T2-SUPPRESS` | `#pragma warning disable`, `// @ts-ignore`, `// @ts-expect-error`, `# noqa`, `# type: ignore`, `eslint-disable` |
| `T3-FEWER-TESTS` | after **<** before on test declarations: `[Fact]`, `[Theory]`, `[Test]`, `[TestMethod]`, `[InlineData` rows, `def test_`, boundary-anchored `it(` / `test(` |
| `T4-FEWER-ASSERTS` | after **<** before on `Assert.`, `.Should()`, `assert `, `expect(` **with no T3 drop** |
| `T5-WEAKENED` | a strong assertion in before (`Assert.Equal(`, `Assert.Same(`, `Assert.Throws`, `toEqual(`, `toBe(`, `assert x == `) whose **first argument text** reappears in after only inside a weak one (`Assert.NotNull(`, `Assert.True(`, `toBeDefined(`, `toBeTruthy(`, `is not None`) |

- Mode via P1-6: `MTK_TEST_GUARD_ENFORCE=off|shadow|active`, default **shadow** (D2).
- Active deny names the signal and counts and says: "Make the test pass by fixing the code. If
  the engineer asked to remove or relax this test, STOP and ask them." No escape hint (same
  stance as config-guard).
- Approval: the existing `.mtk/config-guard-allow` (path, 24h) covers test files.
- Header documents the limits: Bash writes are out of reach; a test moved to a new file reads
  as T3 on the old file (approval list is the escape).

### P1-6 — Gate economics: modes, shadow log, liveness, allow twins

**`hooks/lib/hook-io.sh` — `mtk_deny` stays byte-for-byte unchanged.** It is the S3.18 floor
path (`security-gate.sh:42,653,827,843`) and the config-guard allow-list deny (`:124`).

- `mtk_guard_mode <NAME> <default>` → one of `off | advisory | shadow | active` from
  `MTK_<NAME>_ENFORCE`. Back-compat: `MTK_SCOPE_GUARD_ENFORCE` keeps its full truthy set
  (`1|true|TRUE|yes|YES|on|ON` → `active`, `scope-guard.sh:238-239`), unset → `advisory`;
  `MTK_CONFIG_GUARD=0` → `off`.
- `mtk_deny_gated <mode> <hook> <code> <reason> [toggle]` — new; only shadow-capable hooks
  call it, with the mode as an **explicit argument** (no env channel):
  - `active` → `mtk_deny "$reason" "$toggle"`.
  - `shadow` → append `{"ts","hook","code","target"}` (fields via `mtk_json_escape`;
    `target` = `cksum` of the path/command, never raw text) to
    `.mtk/metrics/enforcement-shadow.jsonl`, then return 0. For a hook whose non-active state
    is `advisory` (scope-guard), shadow emits the advisory **and** logs.
  - `advisory` / `off` → return 0 (caller handles advisory text as today).
- `mtk_tree_fingerprint` excludes `.mtk/` (pathspec `:!.mtk` on both the diff and
  `ls-files -o`), so MTK's own state never reads as a working-tree change.
- **Liveness stamps** in `$TMPDIR/mtk-hook-seen-<cksum(repo root)>/<hook>` (`: > … || true`)
  — outside the repo, so no fingerprint effect and no `.mtk/` creation rule needed. A missing
  stamp directory means "unknown", never WARN.

**Adopters:** `config-guard.sh` (config class: default `active`, behaviour unchanged; test
class: default `shadow`) and `scope-guard.sh` (adds `shadow`).

**Allow twins — `scripts/check-guard-twins.sh`:** collects every code passed to
`mtk_deny_gated` in `hooks/*.sh` and requires, per code, at least one `expect` call line in
`tests/hooks/test-*.sh` whose label starts `deny:<code>` **and** one starting `allow:<code>`
(comments do not count). Missing twin ⇒ exit 1. Wired into `scripts/validate-toolkit.sh` as a
FAIL (S3.10). Existing config-guard and scope-guard cases are relabelled to the convention.

### P1-7 — Review disposition + verify stage

**Schema (`.claude/references/review-finding-schema.md`):**
- `coverage: { "no_issues": [file…], "skipped": [{ "file", "reason" }] }` — required on PASS
  and NEEDS_CHANGES. Files with findings are taken from `findings[]`; together the three must
  equal the changed-file set. (Compact form — per-file objects for every file would cost tokens
  against the 9.0 diet.)
- `candidates_disposed: [{ "candidate_id", "outcome": "raised|dropped", "reason", "cited": "file:line" }]` — required when the orchestrator passed candidates.
- An incomplete either field ⇒ the orchestrator records the lane `ABSTAINED` with
  `abstention.reason` prefixed `incomplete:` (codes live in `reason`; the `stage` enum is
  unchanged).

**New script:** `scripts/review-coverage.sh <lane-result.json> <changed-files.txt> [--candidates <file>]` — exit 0 complete, 1 incomplete (prints what is missing), 2 unparseable.

**Deterministic candidates:** implement Phase 4 and `code-review-and-quality` collect
`pre-commit-linters.sh`, `secret-scan.sh` and `parse-build-diagnostics.sh` output for changed
lines into `.mtk/workflows/<uuid>/review/candidates.json`; `compliance-reviewer` must dispose
of each.

**Verify stage (D4: HIGH/MAX):** new agent `.claude/agents/finding-verifier.md` (`tools: Read,
Glob, Grep`; follows the reviewer contract incl. ABSTAINED). One dispatch per top-level
directory group. Verdicts `confirmed | refined | rejected | immaterial | pre_existing`:
- reject only when the code shows the finding is wrong; "cannot verify" keeps it;
- `pre_existing` → follow-up list, not remediation;
- `immaterial` needs all three: can it happen, does it matter, is the fix worth its reach;
- a failed verifier leaves its group `unverified` — never drops findings.

### P1-8 — Bind reviews to what they reviewed

**`scripts/workflow-artifact.sh`** (sources `hooks/lib/hook-io.sh` via
`"$SCRIPT_DIR/../hooks/lib"` for `mtk_tree_fingerprint`; no second hashing scheme):
- `review-input <uuid> --record` stores the tree fingerprint at
  `results.review.input_fingerprint` with a timestamp; `--check` exits 1 when it changed.
  Implement records at lane dispatch and checks before aggregating; a mismatch re-dispatches
  the lanes whose files changed.
- Finding UIDs `F-<sha1-equivalent via python hashlib (file|rule|normalised snippet)>[:10]`.
  `remediation <uuid> review --findings <file.json>` reconciles against the previous
  iteration: `FIXED`, `STILL_OPEN`, `NEW`, stored at `results.remediation.review.findings`.
  Re-dispatched lanes are **not** shown prior findings.
- Usage header (`:31-33`) documents the new flags.

**Push receipt — `scripts/review-receipt.sh`** (python3 `hashlib`):
- **Qualifying reviews:** a PASS from implement Phase 4 or `code-review-and-quality` (full
  lanes). `pre-commit-review` does **not** write receipts — it is a fast staged-diff check
  (`pre-commit-review/SKILL.md:17,24`) with no push range.
- `write --lanes <csv> --rigor <level>` → `~/.mtk/receipts/<sha256(repo realpath)>/<change_id>.json`
  (mode 0600), recording lanes, rigor, verdict and timestamp.
  `change_id = sha256(merge-base sha + diff merge-base..HEAD)`, merge-base against
  `@{upstream}` when set, else the remote default branch (`origin/HEAD`), else `main`.
- `check` → exit 0 when a receipt covers `<merge-base>..HEAD`, 1 otherwise.

**New hook `hooks/push-gate.sh`** — PreToolUse `Bash` handler with `"if": "Bash(git push *)"`:
- Checks `HEAD` against its upstream as above. Does **not** parse refspecs: a command whose
  refspec is not the current branch (`HEAD:other`, `-C dir`, multiple refs) gets one advisory
  line "push target not mapped — receipt not checked" and passes.
- No receipt ⇒ advisory `additionalContext` naming the uncovered commits (D5);
  `MTK_PUSH_GATE_ENFORCE=active` ⇒ `mtk_deny_gated … PUSH-UNREVIEWED`.
- Re-checks the command text itself (defence in depth if `if` is unsupported on a harness).
- Force pushes stay security-gate's job.

### P1-9 — Stall detection + loud empty results

- `remediation … --open N` keeps its **own `opens` series** next to `scores` (lower is better;
  plateau when the last two calls did not decrease) ⇒ `ESCALATE` with reason `stalled`.
  `--findings` computes N itself. `--score` behaviour unchanged.
- `implement-review-lanes.md` §Iteration cap and `orchestration-gates.md:43-47` (circuit
  breaker) pass and document `--open`. While editing, reconcile the "capped at 2 iterations"
  sentence in `review-finding-schema.md:72-73` with the tracker default 3
  (`implement-review-lanes.md:97`, `implement/SKILL.md:259`).
- `context-miner` records `search_status: ran | unavailable` per source:
  - `git log` or the lessons store `unavailable` ⇒ `ABSTAINED` (`abstention.reason`
    `could-not-search: <source>`).
  - `gh` `unavailable` ⇒ noted, **not** an abstention — keeps `context-miner.md:91-92`.
  - "No history" stays a valid PASS (`implement-review-lanes.md:88-90`) when the required
    sources `ran`.

---

## Waves

- **W0 (parallel, file-disjoint):** B1 · B2 · B3 · B4 · B5 · B8
- **W1:** B6 (needs B5) · B7 (needs B5) · B9 (needs B7, B8)
- **W2:** B10-A (needs B1–B6) → PR-A
- **W3:** B10-B (needs B7–B9 **and B10-A** — it applies its manifest, version, CHANGELOG,
  `hooks.json` and wiring-table edits on top of PR-A's output) → PR-B

No W0/W1 batch edits `hooks.json`, the manifest, versions or `CHANGELOG.md`, and none calls
`mtk_hook_seen` (B10-A adds it everywhere at once). Their checkpoint is their own test.
**Intermediate commits leave `validate-toolkit.sh` red on C0.2** (unlisted new files) until
the release commit — intentional, same as the ECC plan; C0.8 is checked at B10-A/B10-B.

## Conventions every batch follows

Same as `docs/plans/2026-09-23-ecc-borrows.md` §Conventions: hook skeleton from
`hooks/config-guard.sh` (diag trap, `hook-io.sh`, kill-switch, bounded `mtk_read_payload`);
optional env as `"${VAR:-}"` (S3.4 — `hook-io.sh` runs under `set -u`); no jq (S3.3; python3
for hashing/JSON); repo-relative paths via `mtk_repo_relative_path` (S1.17); no pipes into
early-exit consumers (S3.17); tests follow `tests/hooks/test-config-guard.sh` with `TMPDIR` on
a `mktemp -d`; `chmod +x` everything new; scripts called from hooks resolve via
`$SCRIPT_DIR/../scripts` then `${CLAUDE_PLUGIN_ROOT}/scripts` and fail open when absent.

## Batches

### B1 — SubagentStart context (P0-1)
**Files:** `hooks/subagent-context.sh`, `scripts/constitution-digest.sh` (`--ids-only`),
`tests/hooks/test-subagent-context.sh`, `tests/hooks/test-constitution-digest.sh` (one case),
`tests/hooks/fixtures/subagent-start.payload.json`
**Step 0:** capture one real `SubagentStart` payload (temporary `MTK_SUBAGENT_CONTEXT_DUMP=<path>`
seam, `claude --plugin-dir .`, dispatch any agent), redact ids, commit it as the fixture, and
assert the field names the hook reads.
**Tests:** `mtk:` agent + no workflow → rules only · general-purpose + active workflow with pack →
pack + rules · general-purpose + no workflow → silent, **no python spawned** · 8-day workflow → no
pack line · pack path missing → no pack line · 60-rule constitution → ≤ 4,000 chars, ends with
`[+N more rules…]` · digest script absent → pack line only · `MTK_SUBAGENT_CONTEXT=0` → silent ·
garbage payload → exit 0.
**Verify:** `bash tests/hooks/test-subagent-context.sh && bash tests/hooks/test-constitution-digest.sh`

### B2 — Lesson-mining hygiene (P0-2)
**Files:** `scripts/lesson-mine-state.sh`, `tests/hooks/test-lesson-mine-state.sh`,
`.claude/skills/lessons/SKILL.md`, `.claude/references/lesson-mining-rubric.md`,
`scripts/learnings.sh`, `.claude/references/learnings-schema.md`, `tests/hooks/test-learnings.sh`,
`tests/pressure-tests/lesson-mining-rubric.md`, `tests/pressure-tests/lessons.md`
**Tests:** `window` lists only past-watermark content · never-seen file uses `--days` ·
`advance` refuses to go backward · `id` stable across whitespace/case · `decide` append-only ·
`filter` drops decided ids · `evidence` matches a quote containing `"`, a newline and `ć` inside
a JSON-escaped transcript line, and rejects a near-miss · `--retire-when` round-trips through
`add` and `regen-markdown`. Pressure tests: A1 single-session candidate still proposed; A2
single-session candidate is "watching".
**Verify:** `bash tests/hooks/test-lesson-mine-state.sh && bash tests/hooks/test-learnings.sh`

### B3 — Handoff state (P0-3)
**Files:** `scripts/handoff-state.sh`, `tests/hooks/test-handoff-state.sh`,
`.claude/skills/handoff/SKILL.md`, `hooks/session-start`,
`tests/hooks/test-session-start-compact-framing.sh`, `.claude/rules/hooks-and-scripts.md` (S3.11)
**Tests:** open + matching branch listed · other branch hidden · expired hidden · past
`expires` hidden · accepted shown only with `--include-accepted-since` before `accepted_at` ·
legacy file < 24h listed, > 24h hidden · newest first · startup: spec line **and** offer line
both present, offer uses `HANDOFF OFFER:`, never `POST-COMPACTION` · no match → no offer ·
`accept` changes only `state:`/`accepted_at:` · script absent → today's compact behaviour.
**Verify:** `bash tests/hooks/test-handoff-state.sh && bash tests/hooks/test-session-start-compact-framing.sh`

### B4 — Instruction load checks (P0-4)
**Files:** `scripts/check-instruction-load.sh`, `tests/hooks/test-check-instruction-load.sh`,
`.claude/skills/instructions/SKILL.md`, `.claude/skills/setup-bootstrap/SKILL.md` (one step)
**Tests:** each code fires on its fixture and stays silent on its clean twin · nested chain sums
root + nested · `AGENTS.override.md` preferred · `SHADOWED-AGENTS` agrees with
`resolve-constitution.sh` on its own fixtures · `--json` shape.
**Verify:** `bash tests/hooks/test-check-instruction-load.sh`

### B5 — Guard modes, shadow log, fingerprint, twins (P1-6 core)
**Files:** `hooks/lib/hook-io.sh`, `hooks/scope-guard.sh`, `scripts/check-guard-twins.sh`,
`scripts/validate-toolkit.sh` (twins FAIL), `tests/hooks/test-guard-modes.sh`,
`tests/hooks/test-check-guard-twins.sh`, `tests/hooks/test-deny-ergonomics.sh`,
`tests/hooks/test-scope-guard-diet.sh`
**Tests:** mode table incl. `on`/`TRUE`/`YES` and unset → advisory · `mtk_deny` unchanged:
`unset MTK_HOOK_ID` still exits 2; security-gate still denies with every
`MTK_*_ENFORCE=shadow` exported · `mtk_deny_gated` shadow → exit 0, one JSON line, no
stdout/stderr · scope-guard shadow → advisory text **and** log line · active unchanged ·
fingerprint unchanged after writing `.mtk/metrics/x` in an un-ignored repo, changed after
writing `src/x` · stamps land in `$TMPDIR`, never in the repo · twins checker fails a code with
only a comment mentioning `allow:<code>`.
**Verify:** `bash tests/hooks/test-guard-modes.sh && bash tests/hooks/test-check-guard-twins.sh && bash tests/hooks/test-deny-ergonomics.sh && bash tests/hooks/test-scope-guard-diet.sh && bash tests/hooks/test-verify-completion-failclosed.sh`

### B6 — Test-tamper class in config-guard (P1-5) · needs B5
**Files:** `hooks/config-guard.sh`, `tests/hooks/test-config-guard.sh`
**Tests (deny in active / log in shadow):** every T1–T5 code in C#, Python and TS fixtures ·
`[InlineData` row removed · `Assert.Equal(expected, result)` → `Assert.NotNull(result)` · Write
over an existing test file that drops a `[Fact]`.
**Tests (allow):** new test file · adding a test · renaming a test method · assertion moved,
count equal · `Assert.Equal` → `Assert.Equivalent` · non-test `src/Foo.cs` with
`#pragma warning disable` (existing case `:274` stays green) · repo checked out under a parent
named `tests` with `src/Foo.cs` · `Foo.Tests/Foo.Tests.csproj` stays config class · fixture text
with `split(` / `emit(` / `latest(` not counted as tests · `[IgnoreDataMember]` not T1 ·
`tests/hooks/test-x.sh` (bash, not a code extension) ignored · fresh allow list ·
`MTK_TEST_GUARD_ENFORCE=off` · allow-list file edit still denied in every mode.
Existing W1–W3 cases relabelled `deny:`/`allow:` so B5's checker passes.
**Verify:** `bash tests/hooks/test-config-guard.sh && bash scripts/check-guard-twins.sh`

### B7 — Push receipt + gate (P1-8 part) · needs B5
**Files:** `scripts/review-receipt.sh`, `hooks/push-gate.sh`, `tests/hooks/test-review-receipt.sh`,
`tests/hooks/test-push-gate.sh`
**Tests:** receipt written 0600 under a fake `HOME` · `check` passes for the same range, fails
after a new commit · amended commit → new change_id · upstream unset → falls back to
`origin/HEAD` then `main` · no receipt → advisory · `active` → exit 2 `PUSH-UNREVIEWED` with
allow twin · `git push origin HEAD:other` → "not mapped" advisory, exit 0 · non-push Bash
payload → silent.
**Verify:** `bash tests/hooks/test-review-receipt.sh && bash tests/hooks/test-push-gate.sh`

### B8 — Workflow-artifact: review input, finding UIDs, `--open` (P1-8 part, P1-9 part)
**Files:** `scripts/workflow-artifact.sh`, `tests/hooks/test-remediation-tracker.sh`,
`tests/hooks/test-review-input.sh`, `.claude/references/workflow-artifact-schema.md`
**Tests:** `--record` then `--check` → 0; edit a tracked file → 1; add an untracked file → 1;
write under `.mtk/` → still 0 · UID stable across line moves, changes with snippet · reconcile
FIXED/STILL_OPEN/NEW · two successive calls `--open 3` then `--open 3` → second prints
`ESCALATE` (stalled); `--open 3` then `--open 1` → `CONTINUE` · `--score` series and its
plateau unchanged when `--open` is also used.
**Verify:** `bash tests/hooks/test-remediation-tracker.sh && bash tests/hooks/test-review-input.sh`

### B9 — Review protocol (P1-7, P1-9 part) · needs B7, B8
**Files:** `.claude/references/review-finding-schema.md`,
`.claude/references/implement-review-lanes.md`, `.claude/references/orchestration-gates.md`,
`.claude/agents/finding-verifier.md`, `.claude/agents/compliance-reviewer.md`,
`.claude/agents/context-miner.md`, `.claude/skills/implement/SKILL.md` (Phase 4: candidates,
`review-input`, verify stage, `--open`, receipt write),
`.claude/skills/code-review-and-quality/SKILL.md` (same, receipt write),
`scripts/review-coverage.sh`, `tests/hooks/test-review-coverage.sh`,
`tests/pressure-tests/reviewer-abstention.md` (6 → 7 agents carry ABSTAINED),
`tests/pressure-tests/finding-verifier.md` (new, S1.10/S2.7),
`evals/review-incomplete-blocks/` (case.yaml, prompt.md, scaffold.sh, graders — a lane that
skips a changed file must not yield PASS)
**Tests:** coverage complete / missing file / unparseable · candidates all disposed / one missing.
**Budget:** reviewer agents ≤ the 9.0 total (~660 lines) + `finding-verifier.md` ≤ 60 lines
(`wc -l .claude/agents/*.md`).
**Verify:** `bash tests/hooks/test-review-coverage.sh && bash scripts/run-fixtures.sh`

### B10-A — Wiring + release 9.1.0 (PR-A) · needs B1–B6
1. `hooks/hooks.json`: `SubagentStart` → `subagent-context.sh` (timeout 5).
2. `tests/hooks/test-hooks-wiring.sh` expected table + S3.6 text.
3. `mtk_hook_seen <name>` after the kill-switch (or first line after sourcing `hook-io.sh` where
   there is none, e.g. `scope-guard.sh`) in every registered hook: `session-start`,
   `security-gate.sh`, `format-on-edit.sh`, `scope-guard.sh`, `config-guard.sh`,
   `evidence-ledger.sh`, `spec-approval-trigger.sh`, `verify-completion`,
   `workflow-continuation.sh`, `cost-tracker.sh`, `subagent-context.sh`.
4. `scripts/mtk-doctor.sh` **health mode:** WARN when a per-call hook (`session-start`,
   `security-gate`, `scope-guard`, `config-guard`, `evidence-ledger`, `format-on-edit`,
   `verify-completion`) has no stamp although `.claude/analytics.json` shows ≥ 5 sessions;
   event-rare hooks (`subagent-context`, `spec-approval-trigger`, `push-gate`) are reported,
   never WARNed; WARN on `check-instruction-load.sh` findings. **`--usage`** adds raw shadow
   counts per hook/code (no thresholds, `mtk-doctor.sh:60-61`). Test:
   `tests/hooks/test-mtk-doctor-liveness.sh`.
5. `.claude/references/env-knobs.md`: `MTK_SUBAGENT_CONTEXT`, `MTK_TEST_GUARD_ENFORCE`,
   `MTK_SCOPE_GUARD_ENFORCE` (now off/advisory/shadow/active), `MTK_CODEX_DOC_MAX_BYTES`.
6. `README.md` "Files written in your repo" (`:667`): `.mtk/lessons/`,
   `.mtk/metrics/enforcement-shadow.jsonl`; "What MTK runs": `subagent-context.sh`.
7. Manifest entries for every new file; 9.1.0 in manifest, plugin, marketplace;
   `CHANGELOG.md` (measured hook process counts incl. SubagentStart = 1 per subagent);
   `bash scripts/build-references-index.sh`; `bash scripts/generate-checksums.sh` last (S4.11).
**Verify:** `rc=0; bash scripts/validate-toolkit.sh || rc=1; for t in tests/hooks/test-*.sh; do bash "$t" >/dev/null || { echo "FAIL $t"; rc=1; }; done; bash scripts/run-fixtures.sh || rc=1; exit $rc`

### B10-B — Wiring + release 9.2.0 (PR-B) · needs B7–B9, B10-A
1. `hooks/hooks.json`: PreToolUse `Bash` gains `push-gate.sh` with
   `"if": "Bash(git push *)"` (timeout 5).
2. `tests/hooks/test-hooks-wiring.sh`: table entry **plus** an assertion that the push-gate
   handler carries that `if` (the table reads only `command`); confirm
   `hot_path_matchers.py` still reports clean. S3.6 text.
3. `mtk_hook_seen` in `push-gate.sh`.
4. `.claude-plugin/plugin.json` agents list + `finding-verifier.md`; README agent count 6 → 7
   (`:119,135,159,477`).
5. `env-knobs.md`: `MTK_PUSH_GATE_ENFORCE`; README: `~/.mtk/receipts/`.
6. Manifest; 9.2.0 ×3; CHANGELOG; references index; checksums last.
**Verify:** as B10-A, plus the native eval run in §Release gates.

## Release gates (both PRs)

- `bash scripts/validate-toolkit.sh` prints "Toolkit validation passed" (C0.8).
- Native eval suite: overall ≥ 0.83 (the 9.0.0 measurement), same model, judge and run count;
  no case drops by more than one run's noise. PR-B adds `review-incomplete-blocks`.
- Hook processes per tool call unchanged: Read/Grep/Glob/MCP/prompt 0, Bash 3 (push gate only
  on `git push`), Edit/Write unchanged (D6); new: SubagentStart 1 per subagent. Measured with
  the 8.2 counting method; numbers in the CHANGELOG.
- Shipped plugin file count ≤ 490 (`build-plugin-branch.sh`, then count).
- Receipts carry `timing` and `cost` per the existing receipt reference.

## Commits

PR-A (9.1.0):
1. `feat(hooks): SubagentStart hands MTK subagents the context pack and rule ids`
2. `feat(lessons): mining watermark, decision ledger and evidence floor`
3. `feat(handoff): branch-scoped handoff state; startup offers, never claims`
4. `feat(instructions): check instruction load budgets and shadowed constitutions`
5. `feat(hooks): guard modes with a shadow log, allow twins; MTK state no longer counts as a tree change`
6. `feat(hooks): config-guard detects weakened tests (shadow by default)`
7. `chore(release): wire hooks, liveness stamps, 9.1.0`

PR-B (9.2.0), stacked on PR-A:
1. `feat(workflow): review input fingerprint, finding UIDs, stall detection on open findings`
2. `feat(hooks): diff-bound review receipts and an advisory push gate`
3. `feat(review): file coverage, candidate disposition and a finding-verify stage`
4. `chore(release): wire push gate and finding-verifier, 9.2.0`

Each commit carries its own batch's files; the release commit carries the shared files. No
source-repo names in commit messages, PR bodies or CHANGELOG. PRs opened with
`--assignee @me`.

## Out of scope (named so they are not smuggled in)

P2-10 … P2-17 from the research note; the index-first nudge and anchor-touch lesson surfacing
(8.2-diet tension); trace-derived review coverage via `SubagentStop` (now feasible — 9.3
candidate once B9's file coverage has field data); read-only review mode; per-batch worktrees;
extracting the active-workflow selector shared by session-start and subagent-context; the
gh-pages feature catalog (`how-it-works.*` moved off `main`; update it separately if wanted).

## Review log

Fresh `plan-gap-reviewer` pass on revision 1 (2026-10-14). Folded in:

| Finding | Resolution |
|---|---|
| B-1 `how-it-works.*` not on main | Removed from B10-A/B; named in Out of scope |
| B-2 B10-A/B10-B share files in one wave | B10-B moved to W3, depends on B10-A |
| B-3 context-miner abstains on missing `gh` | Only `git log` / lessons store abstain; `gh` noted; reason codes in `abstention.reason` |
| S1 shadow inside `mtk_deny` touches the S3.18 floor | `mtk_deny` unchanged; new `mtk_deny_gated` with explicit mode; `cksum` + `mtk_json_escape` |
| S2 twins not in validator, label check weak | Validator FAIL in B5; counts `expect` call lines; relabel existing cases |
| S3 `.mtk/` stamps change the fingerprint | Stamps in `$TMPDIR`; fingerprint excludes `.mtk/`; stability test |
| S4 config-guard has no test class path | `CLASS` restructure, `REL_PATH`, config precedence, code extensions only, boundary class, extra allow cases |
| S5 handoff facts and legacy bound | Corrected startup facts; `HANDOFF OFFER:` token; legacy 24h bound; newest first; accepted visible on compact; script resolution |
| S6 receipt gaps | Qualifying reviews defined; `pre-commit-review` excluded; range derivation; no refspec parsing; receipt write in B9; B9 needs B7 |
| S7 floor conflicts with rubric | Floor scoped to A2/A3; contract id changed; JSON-decoded evidence; pressure tests in B2 |
| S8 scope-guard back-compat | Full truthy set; explicit `advisory` state; shadow = advisory + log |
| S9 re-invented hashing, two series in one plateau | Reuse `mtk_tree_fingerprint`; separate `opens` series; header + `orchestration-gates.md`; 2-vs-3 reconciliation |
| S10 digest too big, python per subagent | `--ids-only` mode; per-rule cap; `find -mmin` gate before python; SubagentStart counted |
| S11 agent registration surfaces | `plugin.json`, README counts, abstention pressure test, eval case dir, `tools:` |
| S12 verify commands too weak | `rc` accumulation; real SubagentStart payload fixture; `if` assertion; doctor thresholds only in health mode |
| S13 file budget | Counted: ~485 / 512; gate ≤ 490 |
| N1 `generate-tool-configs.sh` no-op | Dropped |
| N2 audit vocabulary, resolver reuse | Insertion point named; `SHADOWED-AGENTS` calls `resolve-constitution.sh` |
| N3 B1 needs `mtk_hook_seen` from B5 | `mtk_hook_seen` added only in B10-A |
| N4 red intermediate commits | Stated as intentional |
