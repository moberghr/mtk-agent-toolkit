# Spec — October borrows, PR-A (9.1.0)

Spec mode: extended (rigor MAX)
Scope: new-feature · security_impact: none · baseline_area: toolkit-workflow
Design source: `docs/plans/2026-10-14-october-borrows.md` (revision 2, approved 2026-10-14 with
defaults D1–D6). Section references below (§P0-1 …) point into that plan; this spec is the
contract, the plan holds the per-signal detail.
Batch ids: this spec's B1–B6 are the plan's B1–B6; this spec's **B7 is the plan's B10-A**.

## Summary

Close six of the nine "behind" rows from `docs/competitive-analysis-2026-10.md`: give MTK
subagents the context pack and rule ids at start (P0-1); stop lesson mining from re-proposing
rejected candidates and from re-reading mined transcripts (P0-2); scope handoffs to their
branch and offer rather than claim them (P0-3); detect instruction files a harness truncates
or never reads (P0-4); detect weakened tests in config-guard, shadow-only at first (P1-5); and
give blocking guards an off/advisory/shadow/active mode with a shadow log, hook liveness and
paired allow/deny fixtures (P1-6). Release as 9.1.0.

## Requirements

- R1. When a subagent starts and its `agent_type` matches `^mtk:` or an active workflow exists, the system shall add a context block holding the critical-rule ids and, when an active workflow has an existing context pack, the pack path.
- R2. When a subagent starts with no `^mtk:` type and no workflow JSON modified in the last 7 days, the system shall emit nothing and spawn no python process.
- R3. If the SubagentStart context block would exceed 4,000 characters, then the system shall truncate it at a rule boundary and end it with a count of omitted rules.
- R4. When `lessons mine` lists transcripts, the system shall list only content past each file's recorded watermark, falling back to the `--days` window for files never mined.
- R5. When a mined candidate has a recorded accepted or rejected decision, the system shall exclude it from the proposal list.
- R6. When a candidate is admitted only by rubric rule A2 or A3, the system shall require verbatim quotes that match decoded messages in at least two distinct sessions before proposing it.
- R7. When a session compacts, the system shall re-inject only a handoff that is open or accepted during this session and that targets the current branch, or a legacy handoff modified within 24 hours.
- R8. When a session starts with source `startup` and an open handoff targets the current branch, the system shall append exactly one `HANDOFF OFFER:` line to the startup context.
- R9. When `check-instruction-load.sh` runs, the system shall report `CODEX-BYTES`, `SHADOWED-AGENTS`, `GLOBS-NOT-PATHS` and `LOCAL-UNIGNORED` findings and exit 1 when any is present.
- R10. When an Edit or Write to a test file of a code extension adds a skip, focus or suppression marker, removes test declarations, removes assertions, or replaces a strong assertion on the same first argument with a weak one, the system shall record a `T1`–`T5` signal.
- R11. While `MTK_TEST_GUARD_ENFORCE` is `shadow` (the default), the system shall log test-tamper signals to `.mtk/metrics/enforcement-shadow.jsonl` and allow the call without model-visible output.
- R12. While a guard's mode is `active`, the system shall deny the call with exit 2 exactly as today.
- R13. If a deny path belongs to `security-gate.sh` or to config-guard's allow-list protection, then the system shall deny regardless of any `MTK_*_ENFORCE` value.
- R14. When MTK writes state under `.mtk/`, the system shall leave `mtk_tree_fingerprint` unchanged.
- R15. When a registered hook runs, the system shall refresh a liveness stamp under `$TMPDIR`, outside the repository.
- R16. When `validate-toolkit.sh` runs, the system shall fail if any code passed to `mtk_deny_gated` lacks both a `deny:<code>` and an `allow:<code>` labelled test case.
- R17. When `mtk-doctor` runs in health mode with at least 5 recorded sessions, the system shall warn about each per-call hook without a liveness stamp and about each instruction-load finding.

`bash scripts/lint-ears.sh docs/specs/2026-10-14-october-borrows-a.md` → 0 violations is a
gate condition.

## Success criteria

| ID | Observable | Verification | Channel |
|---|---|---|---|
| SC1 | SubagentStart hook emits pack + rule ids for the right agents, nothing (and no python) otherwise, ≤ 4,000 chars | `bash tests/hooks/test-subagent-context.sh` | test-run |
| SC2 | Mining state: watermark, decision ledger, id stability, decoded-quote evidence | `bash tests/hooks/test-lesson-mine-state.sh && bash tests/hooks/test-learnings.sh` | test-run |
| SC3 | Handoff state filtering, compact re-injection and the startup offer line | `bash tests/hooks/test-handoff-state.sh && bash tests/hooks/test-session-start-compact-framing.sh` | test-run |
| SC4 | Instruction-load checks fire on fixtures and stay silent on clean twins | `bash tests/hooks/test-check-instruction-load.sh` | test-run |
| SC5 | Guard modes, shadow log, `mtk_deny` unchanged, security-gate unshadowable, fingerprint ignores `.mtk/`, twins checker | `bash tests/hooks/test-guard-modes.sh && bash tests/hooks/test-check-guard-twins.sh && bash tests/hooks/test-deny-ergonomics.sh && bash tests/hooks/test-scope-guard-diet.sh && bash tests/hooks/test-verify-completion-failclosed.sh` | test-run |
| SC6 | Test-tamper class: every T-code fires in C#/Python/TS, every allow case passes, existing config-guard cases green | `bash tests/hooks/test-config-guard.sh && bash scripts/check-guard-twins.sh` | test-run |
| SC7 | Wiring, liveness doctor check, full regression and validator green | `bash tests/hooks/test-hooks-wiring.sh && bash tests/hooks/test-mtk-doctor-liveness.sh && bash scripts/validate-toolkit.sh` | script-output |
| SC8 | No hook-process regression on the read path; Edit/Write and Bash counts unchanged | `python3 hooks/lib/hot_path_matchers.py hooks/hooks.json` exit 0 and the wiring test's expected table | script-output |

## Architecture and design

Per plan §P0-1, §P0-2, §P0-3, §P0-4, §P1-5, §P1-6. Load-bearing choices:

- `mtk_deny` is untouched (S3.18 floor). Shadow mode lives in a new `mtk_deny_gated <mode> <hook> <code> <reason> [toggle]` that only shadow-capable hooks call, with the mode passed explicitly.
- Liveness stamps live in `$TMPDIR/mtk-hook-seen-<cksum(root)>/`, and `mtk_tree_fingerprint` excludes `.mtk/`, so no new state write can trigger a verification gap.
- The test-tamper check is a second class inside `config-guard.sh` (D6), selected on the repo-relative path and code extensions only; config class wins on overlap; the allow-list protection stays first and unconditional.
- Scripts called from hooks resolve via `$SCRIPT_DIR/../scripts`, then `${CLAUDE_PLUGIN_ROOT}/scripts`, and fail open when absent.

## Security and compliance impact

`security_impact: none`. No path touches auth, payments, audit, secrets, PII or IAM. The change
adds guards and alters `hooks/lib/hook-io.sh`, which `security-gate.sh` sources; the risk is a
weakened floor, controlled by R13, by leaving `mtk_deny` byte-identical, and by the existing
`test-security-gate-superset.sh` regression.

## Change manifest

See the JSON sidecar (`docs/specs/2026-10-14-october-borrows-a.json`), which is the source of
truth: 54 entries across B1–B7 (45 non-mechanical). `.claude/references.index` is gitignored
and generated locally, so it is regenerated in B7 but is not a manifest entry.

## Test manifest

New: `test-subagent-context.sh`, `test-lesson-mine-state.sh`, `test-handoff-state.sh`,
`test-check-instruction-load.sh`, `test-guard-modes.sh`, `test-check-guard-twins.sh`,
`test-mtk-doctor-liveness.sh`, fixture `subagent-start.payload.json`. Extended:
`test-constitution-digest.sh`, `test-learnings.sh`, `test-session-start-compact-framing.sh`,
`test-deny-ergonomics.sh`, `test-scope-guard-diet.sh`, `test-config-guard.sh`,
`test-hooks-wiring.sh`; pressure tests `lesson-mining-rubric.md`, `lessons.md`.

## Implementation batches

| Batch | Plan item | Depends | Wave |
|---|---|---|---|
| B1 SubagentStart context | P0-1 | — | 0 |
| B2 Lesson-mining hygiene | P0-2 | — | 0 |
| B3 Handoff state | P0-3 | — | 0 |
| B4 Instruction load checks | P0-4 | — | 0 |
| B5 Guard modes, shadow log, fingerprint, twins | P1-6 | — | 0 |
| B6 Test-tamper class | P1-5 | B5 | 1 |
| B7 Wiring + release 9.1.0 (plan B10-A) | — | B1–B6 | 2 |

B1–B6 do not edit `hooks.json`, the manifest, versions or `CHANGELOG.md`, and do not call
`mtk_hook_seen`. Intermediate commits leave C0.2 red until B7 — intentional.

## Risks and assumptions

- **Assumption:** the `SubagentStart` payload carries `agent_type` (documented). B1 step 0 captures a real payload and fails the batch if the field is named differently.
- **Assumption:** Codex's project-doc cap is 32 KiB (`project_doc_max_bytes`). It is a knob (`MTK_CODEX_DOC_MAX_BYTES`), so a wrong default is one env change.
- **Risk:** test-tamper false positives on legitimate test refactors. Mitigated by shadow default (D2) and the allow list.
- **Risk:** same-wave implementers share one working tree (lesson L-2026-10-14-018); a gate failure may be another batch's transient. W0 batches are file-disjoint; checkpoints run only their own tests.
- **Risk:** B3 and B7 both edit `hooks/session-start` and `.claude/rules/hooks-and-scripts.md`; B5 and B7 both edit `hooks/scope-guard.sh`; B6 and B7 both edit `hooks/config-guard.sh`. Different waves, B7 depends on all.
- **Dirty worktree:** `docs/competitive-analysis-2026-10.md` and `docs/plans/2026-10-14-october-borrows.md` are untracked at start; both are in the manifest (create, mechanical) so they ship with PR-A.

## Open questions

None. D1–D6 were answered by the engineer (defaults accepted).

## Constitution Check

| Rule | How the design satisfies it |
|---|---|
| C0.1 versions in sync | B7 bumps manifest, plugin and marketplace to 9.1.0 together |
| C0.2 manifest coverage | B7 adds an entry for every new file; docs research notes are on the allow list |
| C0.3/C0.4 skill anatomy, frontmatter | Edited skills keep their sections; no new skill |
| C0.5 hooks executable, `set -euo pipefail` | New hook and scripts follow the config-guard skeleton |
| C0.6 no secrets or user paths | Fixtures redact ids; stamps use `$TMPDIR` |
| C0.7 AGENTS.md protected | Not edited |
| C0.8 validator before completion | SC7 |
| S3.3 dependencies | bash/coreutils; python3 for JSON and hashing |
| S3.6 exact hook set | B7 updates rule text and the wiring test together |
| S3.11 compact recovery | Amended in B3 for the startup offer line |
| S3.16 shrink-guarded writes | `lessons` writes still go through `learnings.sh` |
| S3.17 no SIGPIPE pipes | Convention for every batch |
| S3.18 security-gate floor | `mtk_deny` unchanged; R13; superset test in regression |
| S4.11 checksums last | B7 final step |

## INVEST+C

Independent 4/4 (W0 file-disjoint) · Negotiable 2/2 (D1–D6 answered) · Valuable 2/2 · Estimable
2/2 · Small 1/2 (seven batches; split from PR-B already) · Testable 2/2 · +C 2/2 (context pack
lists every touched rule file). Score 15/16.

## Delta against baseline (`toolkit-workflow`)

Adds: SubagentStart hook; lesson-mining state store; handoff state; instruction-load check;
guard modes and shadow log; test-tamper class. Modifies: compact recovery (S3.11), the hook set
(S3.6), the tree fingerprint, `lessons mine` steps 3–7. Removes: nothing.

## Prior Work Check

Run 2026-10-14 against `origin/main` @ `0c908ee`: no existing SubagentStart hook
(`hooks/hooks.json` events: SessionStart, PreToolUse, PostToolUse, Stop); no mining watermark
or decision ledger (`lessons/SKILL.md:92` fixed 7-day window); handoff pick is
`find -mtime -1 | awk NR==1` (`hooks/session-start:125`); no instruction byte-budget check
(`instructions/SKILL.md` has line caps only); no guard mode beyond `MTK_SCOPE_GUARD_ENFORCE`
on/off; no test-file class in `config-guard.sh`. Reused rather than rebuilt:
`constitution-digest.sh`, `resolve-constitution.sh`, `mtk_tree_fingerprint`,
`.mtk/config-guard-allow`, `learnings.sh`. Verdict: CLEAR.
