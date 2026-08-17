# Competitive Borrow Rounds — 2026-08-17

Five research→compare→borrow rounds, each producing one stacked PR. Per round:
fresh discovery of ~10 active comparable repos (fan-out research agents, file-level
evidence required), comparison against MTK with "already covered" verdicts, one
borrow implemented and validated. Priorities: performance, correctness, token
savings. Prior-borrow ledger consulted to avoid re-borrowing (waves v7.1–v7.31).

## Round 1 research (2026-08-17)

24 unique repos discovered, top 10 deep-dived (all active within the last week):
affaan-m/ECC, Fission-AI/OpenSpec, modu-ai/moai-adk, GanyuanRan/Aegis,
mksglu/context-mode, Opencode-DCP/opencode-dynamic-context-pruning, nizos/probity,
Edmonds-Commerce-Limited/claude-code-hooks-daemon, Doucs91/hivelore,
EveryInc/compound-engineering-plugin. ~40 mechanisms extracted; verdicts recorded
per mechanism (fills gap / partially covered / already covered).

Discarded after verification: the hooks-daemon per-event dispatcher (Claude Code
runs matching hooks in parallel, so consolidating MTK's ~20 ms bash hooks into one
sequential dispatcher does not improve wall-clock latency; measured PreToolUse
floor 19 ms, slowest hook 57 ms).

## Round 1 — Outcome-aware verification ledger (from nizos/probity)

**Gap:** MTK recorded that a verification command *ran* (`mtk_command_is_verification`
match at PostToolUse → `last_verification_seq`), never whether it *passed*. A pytest
run with 12 failures stamped the ledger as verified, and `verify-completion`
accepted it as fresh evidence for a completion claim — its EVIDENCE regex even
matches `FAILED` output. Probity's rule: gate on the outcome *observed* in the
transcript ("observed failing for the right reason"), not on the command having
been typed.

**Borrow:**
- `mtk_classify_verification_outcome()` in `hooks/lib/hook-io.sh` — classifies a
  verification command's `tool_response` as `pass|fail|unknown` from unambiguous
  runner summary shapes (pytest/jest/vitest counts, dotnet `Build FAILED`/
  `Passed!`/`error CSnnnn`, unittest, ruff/mypy, validate-toolkit). Fail shapes
  win over pass shapes ("2 failed, 10 passed" → fail). Everything ambiguous is
  `unknown`, and `unknown` never blocks — per the toolkit lesson that a gate
  which flakes on innocent output is a gate people learn to skip.
- `context-budget.sh` records `last_verification_status` alongside the existing
  seq/epoch/command fields; the payload is sliced at `"tool_response"` so outcome
  markers in the command text itself cannot classify the run.
- `verify-completion` gains a third GAP branch: strong completion claim + fresh
  verification + `status=fail` → block once ("a verification that ran is not a
  verification that passed"), between the re-arm check and the evidence check.

**Test:** `tests/hooks/test-verification-outcome.sh` — classifier shapes (incl.
XFAIL word-boundary and fail-beats-pass), ledger recording via a real PostToolUse
payload, non-verification commands leaving the column untouched, and the Stop-hook
block/no-block/fail-open triple.

## Round 2 — Verification Economy evidence contract (from modu-ai/moai-adk)

**Gap:** verification output enters context verbatim and is then re-quoted in the
completion banner (double burn). `compress-monitor` nags after the fact;
nothing routes output to disk from the start.

**Borrow:** `.claude/references/verification-evidence-contract.md` (the durable
contract: file-redirect form `cmd > log 2>&1`, exit-code echo, bounded tail-30 into
context, evidence persisted under `.mtk/evidence/<session>/` with the citable path
required in the completion report) + `scripts/mtk-verify-run.sh` (wrapper that
implements the contract atomically: unique log per run, `exit=N` line, bounded tail,
`[full output: <path>]` citation) + wiring into `verification-before-completion`
(new "Evidence economy" section referenced from the workflow) and
`subagent-implementer-prompt.md` (VERIFY step routes through the wrapper, JSON
`evidence` field carries the log path + tail, not the full dump). Also
`verify-completion`'s EVIDENCE regex accepts the wrapper's `exit=N` signature.
Validate-toolkit budget tripwire deferred (S2.6a covers descriptions; the
always-loaded-surface estimate is a candidate for a later round).

**Round 2 research (2026-08-17, fresh sweep — evidence handling + new entrants):**
first-fluke/oh-my-agent (Stop-gate with bounded 2000-char tail, no-exec allowlist,
JSONL gate-event trail), fivetaku/fablize (structured-first outcome extraction:
`exit_code`/`returncode`/`success` fields before text regex; redacted evidence
ledger), basilisk-labs/agentplane (evidence contract as schema — checks[] with
sha256-pinned artifact citations, passed/failed/partial/not_run/waived status
enum), sleeplesshan/token-router (lossless line-slicing: select coordinates,
never rewrite; deterministic error-keyword prefilters), PCIRCLE-AI/toonify-mcp
(`updatedToolOutput` replace-at-source; do-not-compress policy learned from
measurement), u-ichi/compact-plus (semantic PreCompact state capture),
chaseai-yt/crucible (persistent-session adversarial review, VERDICT line
contract), Nanako0129/pilotfish re-verified, zeuikli/output-compress
(deterministic fidelity gate protecting file paths through compression).

Two findings folded into this round's implementation: (1) fablize's
structured-first rule — the classifier now reads `"exit_code"/"returncode"/
"success"` from the tool_response before any text shape; (2) token-router's
lossless error slice — on failure the wrapper emits the first error-keyword
hits with log line numbers ahead of the tail, so diagnostics above the tail
are reachable by coordinate. Deferred to later rounds: agentplane's sha256-
pinned citations + status enum, oh-my-agent's JSONL gate-event trail,
crucible's persistent-session review convergence, toonify's replace-at-source
hook mechanism.

**Test:** `tests/hooks/test-mtk-verify-run.sh` — exit-code fidelity (0 and
non-zero), bounded tail on long output, full output preserved on disk, citation
line format, error-hit slice on failure only, structured-field precedence, and
ledger interop (wrapper invocations register as verification commands).

## Round 3 — Fail-safe merge guards on spec-archive (from Fission-AI/OpenSpec)

**Gap:** `spec-archive.sh` promised "never deletes from the baseline by
inference" but never checked it: a typo'd `delta.removes` entry silently removed
nothing (forever), the merged JSON replaced the baseline unvalidated via a
non-atomic cross-device `mv`, and the JSON mutated before the MD/audit so a
mid-run failure left inconsistent state.

**Borrow (all in `scripts/spec-archive.sh`):** sidecar shape pre-validation;
Guard 1 — unmatched-remove refusal with case/whitespace-folded near-miss
suggestions (OpenSpec's foldRequirementName); Guard 2 — re-validate merged JSON
before any replace; Guard 3 — loss accounting (keys that disappeared must equal
keys explicitly removed, else refuse naming the lost keys — OpenSpec's
unaccounted-content rule, deltaspec's C4 "archive without loss"); all-or-nothing
commit point (same-directory temp files, atomic renames, audit appended last);
plus deltaspec's C5 baseline growth advisory (lines/token budget, never blocks).

**Round 3 research (2026-08-17, fresh sweep — artifact integrity + safe writes):**
iuripereira/deltaspec (C4 archive-without-loss CRITICAL gate, C5 token-cost gate
— both folded in), jakubsuplicki/codument (per-symbol fingerprint drift with
proven exemptions; invariant pointers that execute their cited tests;
fingerprint-bound acks that auto-invalidate), claimset/claimset (falsifiability
pre-gate for citations; divergence localization), gastownhall/beads (field-level
three-way automerge naming every superseded cell; typed merge-refusal taxonomy),
AlexZio00/sovereign-skills (validate_memory_claims.py path/provenance checks on
handoff artifacts; handoff attestation receipts), intellectronica/ruler
(provenance-guarded backups; containment/symlink asserts before managed writes),
hyuga611/narai (pre-write "is this still what I last wrote" hash check),
josephbsmith/citationdiff (verification bound to content hash — the
seal-binds-content mechanism), DavidWells/markdown-magic (loss-safe sentinel
block regeneration, write-only-if-changed). Deferred to rounds 4-5: citationdiff
hash-bound approval seals, codument ack invalidation, sovereign-skills handoff
claim validation, ruler containment asserts.

**Test:** `tests/hooks/test-spec-archive-guards.sh` — seed archive, typo'd
remove refused with near-miss, refusal leaves JSON/MD/audit byte-identical and
no temp files, exact remove merges and audits, malformed sidecar refused,
growth advisory fires without blocking. (Its grep assertion also re-learned the
S3.1 lesson: `echo | grep -q` SIGPIPEs under pipefail — case-match instead.)

## Rounds 4–5 (planned, revisited each round with fresh research)

- Round 4 (correctness): deny-continuation suffix + disabling-toggle attribution
  on all deny-capable hooks (from Edmonds-Commerce hooks-daemon field data).
- Round 5 (tokens): decided after Round 5 research — candidates: per-source
  bytes-saved attribution in analytics (context-mode), negative-ceremony fixtures
  (Aegis), stale-anchor citation check in mtk-doctor (hivelore), citationdiff
  hash-bound approval seals.
