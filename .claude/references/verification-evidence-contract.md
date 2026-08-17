---
description: The verification evidence contract — full output persisted to a citable disk log, exit code + bounded tail in context, log path cited in the completion report
globs: ["**/*"]
alwaysApply: false
---

# Verification Evidence Contract

Verification output enters context twice today: once verbatim when the command
runs, and again when the completion report re-quotes it. On a 20–60k-char test
run that double burn is thousands of tokens for output whose diagnostic value
lives in its last 30 lines. Dropping the output is not an option — completion
claims must stay evidence-backed and audit-reachable.

The contract resolves both: **verbatim evidence lives on disk with a citable
path; context carries the exit code plus a bounded tail.**

## The contract

When a verification command's output is likely to exceed the bounded-tail
ceiling (~30 lines), run it through the wrapper:

```bash
bash scripts/mtk-verify-run.sh -- dotnet test
bash scripts/mtk-verify-run.sh --label unit -- pytest tests/
bash scripts/mtk-verify-run.sh "npm test 2>&1"
```

Output shape (this is the whole contract):

```
exit=0
--- tail -30 of 'dotnet test' (412 lines total, full output: .mtk/evidence/20260817-141530-dotnet-812.log) ---
<last 30 lines — runner summary included, since summaries print last>
```

1. **Full output** persists under `.mtk/evidence/` (gitignored via `.mtk/`,
   survives the session; not committed — commit-worthy evidence follows the
   `browser` channel convention in `evidence-capture.md` instead).
2. **`exit=N`** is machine-readable and authoritative: the session ledger's
   outcome column (`mtk_classify_verification_outcome`) reads it ahead of any
   text-shape heuristic, and `verify-completion` accepts it as cited evidence.
3. **The log path MUST appear in the completion report** next to the criterion
   it verifies. A bounded tail without its citable path is a claim, not
   evidence.
4. The command's **exit code is preserved** as the wrapper's own exit code —
   `&&` chains and hook semantics behave exactly as with the bare command.

## When to use what

| Situation | Tool |
|---|---|
| Verification command (build, tests, validators) whose result backs a completion claim | `mtk-verify-run.sh` — persisted evidence + exit fidelity |
| Exploratory large output (JSON dumps, HTML fetches, log spelunking) | `mtk-compress.sh` (see `output-compression.md`) — lossy in-flight compression is fine when nothing downstream cites the output |
| Output short by definition | neither — run it bare |

Never route secrets or redaction-relevant content through either path — the
safety carve-outs in `output-compression.md` apply to the evidence log too:
the log file persists on disk, so a leaked token in verification output is a
leaked token in `.mtk/evidence/`.

## Subagent implementers

The implementer VERIFY step routes build/test through the wrapper and returns
the `exit=N` line, the tail, and the log path in `build.evidence` /
`tests.evidence` — never the full dump. The orchestrator can read the full log
from disk when the tail is not enough; the subagent reply stays bounded.

## Knobs

| Env | Default | Purpose |
|---|---|---|
| `MTK_VERIFY_TAIL` | 30 | Tail line count kept in context (same bound as `MTK_COMPRESS_MAX_LOG_LINES`) |
| `MTK_VERIFY_ERROR_HITS` | 8 | On failure, max error-keyword hit lines emitted before the tail — each with its log line number, so the reader widens from the persisted log by coordinate instead of guessing above the tail. Hits are raw log lines, selected never rewritten |
