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

**Test:** `tests/hooks/test-mtk-verify-run.sh` — exit-code fidelity (0 and
non-zero), bounded tail on long output, full output preserved on disk, citation
line format, and ledger interop (wrapper invocation still classifies pass/fail
via the runner summary in the tail).

## Rounds 3–5 (planned, revisited each round with fresh research)

- Round 3 (correctness): fail-safe merge guards on `spec-archive.sh` —
  content-loss accounting + re-lint before atomic write (from Fission-AI/OpenSpec).
- Round 4 (correctness): deny-continuation suffix + disabling-toggle attribution
  on all deny-capable hooks (from Edmonds-Commerce hooks-daemon field data).
- Round 5 (tokens): decided after Round 5 research — candidates: per-source
  bytes-saved attribution in analytics (context-mode), negative-ceremony fixtures
  (Aegis), stale-anchor citation check in mtk-doctor (hivelore).
