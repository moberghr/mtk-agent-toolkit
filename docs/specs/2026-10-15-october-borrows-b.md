# Spec — October borrows, PR-B (9.2.0)

Spec mode: standard (rigor HIGH — engineer's lighter setting for PR-B)
Scope: new-feature · security_impact: none · baseline_area: toolkit-workflow
Design source: `docs/plans/2026-10-14-october-borrows.md` (revision 2, approved 2026-10-14 with
defaults D1–D6), §P1-7, §P1-8, §P1-9, and the structural follow-ups in
`docs/handoffs/2026-10-15-october-borrows-pr-b.md` (PR-A architecture review, round 3).
Stacked on `feat/october-borrows-a` (PR #125). Branch `feat/october-borrows-b`.

**Batch-id map.** Sidecar ids must match `^B[0-9]+$`, so this spec renumbers:

| Spec | Plan | Content |
|---|---|---|
| B1 | (new) | Guard-mode lib split + advisory helper |
| B2 | (new) | Shared `hooks.json` handler parser + liveness rarity for `if`-filtered hooks |
| B3 | (new) | Shared active-workflow selector |
| B4 | B8 | Workflow-artifact: review input, finding UIDs, `--open` |
| B5 | B7 | Push receipt + advisory push gate |
| B6 | B9 (part 1) | Coverage checker + review protocol (references, skills) |
| B7 | B9 (part 2) | `finding-verifier` agent, reviewer edits, pressure tests, eval case |
| B8 | B10-B | Wiring + release 9.2.0 |

## Summary

Finish the October borrows: first pay down the three duplications and one false-WARN the PR-A
architecture review left (B1–B3), then bind reviews to what they reviewed (input fingerprint,
stable finding ids, diff-bound push receipts with an advisory push gate), detect stalled
remediation on open-finding counts, require reviewers to account for every changed file and
every deterministic candidate, and add a finding-verify stage at HIGH/MAX. Release as 9.2.0.

## Requirements

- R1. When `scope-guard.sh`, `config-guard.sh` or `push-gate.sh` needs a guard mode, it shall source `hooks/lib/guard-mode.sh`; `hooks/lib/hook-io.sh` shall no longer define `mtk_guard_mode` or `mtk_deny_gated`, and `mtk_deny` shall stay byte-identical.
- R2. When a guard in `advisory` or `shadow` mode calls `mtk_advise_gated <mode> <event> <key> <text>`, the system shall emit the text as `additionalContext` at most once per key per session (every call when the payload has no `session_id`), and shall emit nothing in `off` or `active`.
- R3. When the validator, `mtk-doctor` or the wiring test needs the registered hook list, it shall read it from `hooks/lib/hook_registry.py`.
- R4. When a handler carries an `if` field or is registered on `SubagentStart`, the doctor shall classify it as event-rare: reported, never WARNed for a missing stamp.
- R5. When `hooks/session-start` or `hooks/subagent-context.sh` needs the active workflow, it shall call `hooks/lib/active_workflow.py`, and `subagent-context.sh` shall still spawn no python process before its `find -mmin` prefilter opens.
- R6. When `workflow-artifact.sh review-input <uuid> --check` runs after `--record`, it shall exit 1 if a tracked file changed or an untracked non-ignored file appeared, and exit 0 if only `.mtk/` changed or the reviewed tree was committed unchanged.
- R7. When `remediation <uuid> <trigger> --findings <file>` runs, the system shall assign each finding a stable UID from file, rule and normalised snippet, and classify it against the previous call as `FIXED`, `STILL_OPEN` or `NEW`.
- R8. When two successive `remediation … --open N` calls do not decrease N, the system shall print `ESCALATE` with reason `stalled`; the `--score` series shall behave as before.
- R9. When `review-receipt.sh write` runs, the system shall store a receipt (mode 0600) keyed by a change id over the merge-base and the diff to `HEAD`; `check` shall exit 0 only when a receipt covers the current range.
- R10. When a `git push` of the current branch has no covering receipt, the push gate shall add advisory context naming the uncovered commits; in `MTK_PUSH_GATE_ENFORCE=active` it shall deny with code `PUSH-UNREVIEWED`.
- R11. If a push command's refspec does not map to the current branch, then the push gate shall emit one "push target not mapped — receipt not checked" line and allow the call.
- R12. When `review-coverage.sh` checks a lane result, it shall exit 1 if `coverage.no_issues`, `coverage.skipped` and the files in `findings[]` do not together equal the changed-file set, or if any passed candidate lacks a disposition.
- R13. While rigor is HIGH or MAX, the review protocol shall run a `finding-verifier` stage that never drops a finding it cannot verify.
- R14. If `context-miner` could not search `git log` or the lessons store, then it shall return `ABSTAINED` with reason `could-not-search: <source>`; a missing `gh` shall be noted, not an abstention.

## Success criteria

| ID | Observable | Verification | Channel |
|---|---|---|---|
| SC1 | Guard-mode split; `mtk_advise_gated`; `mtk_deny` unchanged; security-gate floor intact | `bash tests/hooks/test-guard-modes.sh && bash tests/hooks/test-deny-ergonomics.sh && bash tests/hooks/test-scope-guard-diet.sh && bash tests/hooks/test-config-guard.sh && bash tests/hooks/test-security-gate-superset.sh && bash scripts/check-guard-twins.sh` | test-run |
| SC2 | One handler parser; `if`-filtered hooks rare in the doctor | `bash tests/hooks/test-hook-registry.sh && bash tests/hooks/test-hooks-wiring.sh && bash tests/hooks/test-mtk-doctor-liveness.sh` | test-run |
| SC3 | One active-workflow selector | `bash tests/hooks/test-active-workflow.sh && bash tests/hooks/test-subagent-context.sh && bash tests/hooks/test-session-start-compact-framing.sh` | test-run |
| SC4 | Review input, UIDs + reconcile, `--open` stall | `bash tests/hooks/test-remediation-tracker.sh && bash tests/hooks/test-review-input.sh` | test-run |
| SC5 | Receipts + push gate | `bash tests/hooks/test-review-receipt.sh && bash tests/hooks/test-push-gate.sh` | test-run |
| SC6 | Coverage checker; protocol documented | `bash tests/hooks/test-review-coverage.sh && bash scripts/run-fixtures.sh` | test-run |
| SC7 | finding-verifier within budget; abstention pressure test at 7 agents; eval case | `wc -l .claude/agents/*.md` and `bash scripts/run-fixtures.sh` | test-run |
| SC8 | Wired, released, green | validator prints "Toolkit validation passed"; every `tests/hooks/test-*.sh` and `run-fixtures.sh` exit 0 | script-output |

## Architecture and design

Per plan §P1-7, §P1-8, §P1-9. Choices this spec adds:

- **B1 `hooks/lib/guard-mode.sh`.** The three guard-mode functions move verbatim. `security-gate.sh` keeps sourcing only `hook-io.sh` and never `guard-mode.sh`, so no `MTK_*_ENFORCE` value can reach it (S3.18). The new `mtk_advise_gated` replaces scope-guard's own per-file dedup, and the push gate reuses it with the change id as key. The dedup store is `$(mtk_session_file).advised-<hook>`.
- **B2 `hooks/lib/hook_registry.py`.** It sits next to `hot_path_matchers.py`. It exposes `handlers(path)` (importable) and a CLI that prints `rarity\tevent\tmatcher\tif\tscript\targs\ttimeout` per handler, with exit 1 and one readable line on unreadable JSON. The doctor de-duplicates by script, and if a script is registered both with and without `if`, per-call wins. `hot_path_matchers.py` stays a separate classifier.
- **B3 `hooks/lib/active_workflow.py`.** It holds the selection rule both hooks use today, unchanged: status `active`, `updated_at` within N days, newest wins, unreadable or ill-formed files are skipped. Args: `<wf_dir> <days> <field>...`, where field is one of `path|type|phase|pack`. It prints one TSV line, or nothing.
- **B4.** `review-input` hashes with `mtk_tree_fingerprint <recorded base>`, sourced from `hooks/lib/hook-io.sh`. The recorded base sha is passed back on `--check`, so committing the reviewed tree does not read as a change.
- **B5.** The push gate reads its mode through `mtk_guard_mode PUSH_GATE advisory`. It writes no state of its own, and receipts live only under `~/.mtk/receipts/` (dir 0700, file 0600, no writes through a symlink).
- Scripts called from hooks resolve via `$SCRIPT_DIR/../scripts`, then `${CLAUDE_PLUGIN_ROOT}/scripts`, and fail open when absent (plan §Conventions).

## Security and compliance impact

`security_impact: none`. No auth, payment, audit, secret, PII or IAM path. B1 edits
`hook-io.sh`, which `security-gate.sh` sources. The risk is a weakened floor, which is controlled
by leaving `mtk_deny` byte-identical and by `test-security-gate-superset.sh` in SC1. The receipts
are new files under `$HOME`; they are written 0600 inside a 0700 dir and refuse symlinks (the
PR-A review round-2 lesson). Mutation testing is limited to `guard-mode.sh`, `push-gate.sh` and
`review-receipt.sh`, which is the engineer's lighter setting.

## Change manifest

The JSON sidecar `docs/specs/2026-10-15-october-borrows-b.json` is the source of truth. It has
50 entries across B1–B8, 47 of them non-mechanical.

## Test manifest

New:
- `test-guard-modes.sh` (extended)
- `test-hook-registry.sh`
- `test-active-workflow.sh`
- `test-review-input.sh`
- `test-review-receipt.sh`
- `test-push-gate.sh`
- `test-review-coverage.sh`
- pressure test `finding-verifier.md`
- eval `review-incomplete-blocks`

Extended:
- `test-deny-ergonomics.sh`
- `test-hooks-wiring.sh`
- `test-mtk-doctor-liveness.sh`
- `test-remediation-tracker.sh`
- pressure test `reviewer-abstention.md`

## Implementation batches

| Batch | Depends | Wave | Model |
|---|---|---|---|
| B1 Guard-mode lib split | — | 0 | Sonnet |
| B3 Active-workflow selector | — | 0 | Sonnet |
| B4 Review input, UIDs, `--open` | — | 0 | Opus (reconcile + fingerprint semantics) |
| B2 Hook registry + liveness rarity | B1 | 1 | Sonnet |
| B5 Receipts + push gate | B1 | 1 | Opus (security-relevant) |
| B6 Coverage checker + protocol | B4, B5 | 2 | Sonnet |
| B7 finding-verifier + reviewers + eval | B6 | 3 | Sonnet |
| B8 Wiring + 9.2.0 | B2, B3, B5, B7 | 4 | Sonnet |

B2 waits for B1 because the wiring test drives `scope-guard`/`config-guard`. Only B8 edits
`hooks.json`, the manifest, versions and `CHANGELOG.md`. Intermediate commits leave C0.2 red until
B8; this is intentional, as in PR-A.

Commits:
- `refactor(hooks): shared hook registry, workflow selector and guard-mode lib`
- the plan's four PR-B commits

## Risks and assumptions

- **Assumption:** Claude Code honours a handler-level `if` (`Bash(git push *)`), as documented on 2026-10-14. The push gate re-checks the command text in case a harness ignores it.
- **Risk:** a caller relied on `hook-io.sh` alone for guard modes. Mitigated by a grep for every caller in B1 and by the runtime wiring drive plus the full hook suite in B8.
- **Risk:** W0 implementers share one working tree (L-2026-10-14-018). Batches are file-disjoint, and checkpoints run only their own tests.
- **Risk:** the reviewer agent line budget (9.0 diet, about 660) leaves about 5 lines of headroom across `compliance-reviewer` and `context-miner`. Some text may have to move into `review-finding-schema.md`.
- **Dirty worktree:** `docs/handoffs/` is untracked at start and is out of manifest. It is not committed.

## Open questions

None. D1–D6 were answered for the plan, and the lighter PR-B settings were chosen on 2026-10-15.

## Prior Work Check

Run on 2026-10-16 against `feat/october-borrows-a` @ `bae6bf8`:
- `scripts/review-receipt.sh`, `hooks/push-gate.sh`, `scripts/review-coverage.sh` and `.claude/agents/finding-verifier.md` are absent.
- `workflow-artifact.sh` has no `review-input`, `--open` or `opens` (0 matches).
- `review-finding-schema.md` has no `coverage` or `candidates_disposed`.
- `context-miner.md` has no `search_status`.
- The selector is duplicated at `hooks/session-start:219-249` and `hooks/subagent-context.sh:108-136`.
- `hooks.json` is parsed separately in `validate-toolkit.sh:257`, `mtk-doctor.sh:676` and `test-hooks-wiring.sh:100,166`.

Reused rather than rebuilt: `mtk_tree_fingerprint`, `mtk_guard_mode`/`mtk_deny_gated`, the `remediation` tracker, `check-guard-twins.sh` and the ABSTAINED contract.

Verdict: CLEAR. Every batch is not-started.
