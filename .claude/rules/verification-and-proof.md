---
paths:
  - ".claude/skills/verification-before-completion/**"
  - ".claude/skills/batch-fix/**"
  - ".claude/skills/workflow-artifacts/**"
  - ".claude/skills/subagent-implementation/**"
axes:
  decision: process
  topic: verification
  scope: global
---

# Verification & Proof (S5)

> Added 2026-09-15 from a six-phase field-run retro. Cite rules as S5.N in reviews.

These rules encode failure modes a green-everything run hid: gates stayed green
through phases that never touched a real external system, a load-bearing trap
list survived only by being hand-carried, and independently-green fixes broke on
composition. They are process invariants for the verification, batch-fix, and
workflow-orchestration skills whose globs are listed above.

## Proof vs. Green

- **S5.1** Green gates are not proof. A passing build or test suite is evidence only about the code paths it executed and is silent about every path it did not — and that silence reads as false confidence. For behavior-shaped changes, pair the completion evidence table with a **Not-Proved ledger** (see `verification-before-completion`) that names every external system exercised only against a mock, every configuration or branch the change supports but no criterion ran, and the fact that an exact match on one fixture is evidence about that fixture alone. An empty Not-Proved column on a behavior-shaped change is a red flag, not a clean bill.
- **S5.4** Document the analyzer wall. In a warnings-as-errors repo the analyzer set (StyleCop `SA*`, SonarAnalyzer `S*`, Meziantou `MA*`) — not the toolkit's own rules — catches most build-gate failures. The common offenders, the `SA1512`/`SA1514` collision, and the fact that a green `dotnet build` does not imply a green `dotnet format --verify-no-changes` belong in the stack's analyzer reference (`.claude/references/dotnet/analyzer-config.md`), written down once — not re-diagnosed every phase.

## Carry, Don't Re-Derive

- **S5.2** Carry a trap list across phases. A *trap* is a specific gotcha a phase learned the hard way (a stale generated contract, an analyzer that fires only under `format`, a fixture that silently seeds the wrong state). Record each on the workflow artifact the moment it is learned (`workflow-artifact.sh trap add`) and inject the accumulated list (`trap list`) into every subsequent phase and subagent brief. A trap that lives only in a phase report is lost the moment that report scrolls out of context — the carry-forward is the one mechanism a field run proved load-bearing, so it must be a maintained artifact, not a habit of whoever is driving.

## Composition

- **S5.3** Independent fixes that were each green in isolation must pass one composed **full-suite** run before completion — not just the per-fix areas. Parallel application (separate branches or worktrees, merged) trades rebase cost for integration risk: a change to an aggregate key, a scope predicate, or a shared fixture can break tests a *different* fix silently depended on, and only the whole suite sees it. On a composed failure, diagnose before touching numbers — most are stale **fixtures** (seed the state the code's contract now assumes; the original expected values then pass unchanged, which is the proof no total moved), some are stale **assertions** (a genuinely changed contract — update and say so), a few are **real defects** (fix the code). Never edit an expected value to reach green: in this exact scenario that pinned a double-billed invoice with a passing test.
