# MTK Benchmarks

Deterministic effectiveness benchmarks for MTK's hooks, linter pattern packs, and the
structural validator. No LLM is involved — every assertion invokes a real process and
checks a real exit code or output match.

```bash
bash scripts/run-benchmarks.sh            # run all sections
bash scripts/run-benchmarks.sh --verbose  # also show passing assertions
```

Each run writes **`benchmarks/results.json`** (committed, schema `mtk.benchmarks.v1`).

## What the numbers measure

Per-section pass/fail counts over seven benchmark sections:

| Section | Asserts that… |
|---|---|
| Linter Patterns: known-bad.diff | secrets / slopwatch / stack / domain packs fire on seeded violations |
| Linter Patterns: known-good.diff | the same packs do **not** fire on clean code (false-positive floor) |
| Security Gate: destructive commands | destructive shell/SQL/git commands are blocked with exit 2 |
| Scope Guard: spec-aware scope detection | out-of-manifest edits warn, in-manifest edits stay silent |
| Verify Completion: evidence gating | completion claims without fresh evidence are blocked |
| Prerequisites: tool detection | prerequisite reporting produces formatted output |
| Toolkit Validation | `validate-toolkit.sh` exits 0 and prints its pass line |

## What these numbers do **not** measure

Stated explicitly, and duplicated into `results.json.excludes` so the caveats travel with
the data rather than living only here:

- **Model behaviour.** Whether an agent actually *follows* a skill is not measured. That is
  what `evals/` is for. A green benchmark run says the deterministic guards work; it says
  nothing about whether Claude honours a skill's instructions.
- **Cross-model coverage.** One bash environment, one model-agnostic code path.
- **Real-world hit rate.** Linter sections measure pattern behaviour against curated
  fixtures, not prevalence in production diffs.
- **False-negative rate.** Fixtures prove the patterns fire on *seeded* cases. They place no
  bound on what the patterns miss.
- **Timing and cost.** No wall-clock or token measurements are collected.
- **Environment coverage.** One run on one host. macOS (bash 3.2) and Linux (bash 5) differ;
  only the running host is represented.

## Reading `results.json`

```jsonc
{
  "schema": "mtk.benchmarks.v1",
  "run_complete": true,        // false ⇒ the run aborted early; counts are PARTIAL
  "totals":   { "passed": 0, "failed": 0, "total": 0 },
  "sections": [ { "name": "…", "passed": 0, "failed": 0 } ],
  "measures": "…",
  "excludes": [ "…" ]
}
```

Two properties are load-bearing:

1. **`run_complete`.** The runner uses `set -e`, so a single failing helper aborts the whole
   script. Publication happens from an `EXIT` trap, so a partial run still publishes its
   real measurements — flagged `run_complete: false` — instead of silently producing
   nothing. **Never read `totals` without reading `run_complete` first.** Sections absent
   from the array did not run; they are not passes.
2. **Reconciliation.** Per-section counts are asserted to sum to `totals` at write time. If
   they ever disagree the file is not written and the runner warns, because a published
   number that does not add up is worse than no published number.

## Adding a benchmark

Call `section "Name"` to open a tracked block, then use `assert_match`,
`assert_no_match`, or `assert_exit`. Section accounting and JSON publication are automatic.
