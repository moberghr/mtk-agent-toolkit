---
category: positive
skill: implement
signal: mechanical-discount-applied
---

# Six-file mechanical rename batch is not force-escalated to HIGH

## Scenario

A cleanup pass renames the internal helper `OrderCalcUtil` to `OrderCalculator`
across the codebase. Six files change: the helper file itself plus five internal
call sites. The type is `internal` — no endpoint, handler, method, event, or
CLI-flag signature changes; no logic changes. Every edit is a pure identifier
rename (find/replace), so each `change_manifest` entry is rename-only with no
behavioral change and no public contract touched.

Under the old rule this six-file change would trip the `change_manifest.length >= 6`
hard floor and be force-escalated to HIGH (subagent path, no `MTK_AUTO_PROCEED`).
With the fix, the floor counts only non-mechanical entries.

### Change manifest excerpt (spec JSON sidecar)

```json
"scope": "internal-refactoring",
"change_manifest": [
  { "path": "src/Orders/OrderCalculator.cs",        "action": "modify", "purpose": "rename OrderCalcUtil -> OrderCalculator", "mechanical": true },
  { "path": "src/Orders/CreateOrderHandler.cs",     "action": "modify", "purpose": "update rename call site",                "mechanical": true },
  { "path": "src/Orders/UpdateOrderHandler.cs",     "action": "modify", "purpose": "update rename call site",                "mechanical": true },
  { "path": "src/Orders/CancelOrderHandler.cs",     "action": "modify", "purpose": "update rename call site",                "mechanical": true },
  { "path": "src/Orders/OrderSummaryProjection.cs", "action": "modify", "purpose": "update rename call site",                "mechanical": true },
  { "path": "src/Orders/ServiceRegistration.cs",    "action": "modify", "purpose": "update rename call site",                "mechanical": true }
],
"public_contracts": [],
"security_impact": "none"
```

## Prompt

```prompt
Rename the internal OrderCalcUtil helper to OrderCalculator everywhere it is
used. It is internal, no public surface changes, pure find/replace across the
Orders slice. Active tech stack: dotnet.
```

## Expected Signals

- The Rigor Score step recognizes all six entries are rename-only with no logic
  and no public contract change, and tags each `mechanical: true`.
- The **non-mechanical** `change_manifest` count is 0, so the `>= 6` hard-trigger
  floor does NOT fire — the change is not force-escalated to HIGH.
- The size score contributes +0 (zero non-mechanical files ÷ 3), so the level
  lands LIGHT (or STANDARD), never HIGH.
- The Phase 2.5 gate line surfaces the mechanical split so the engineer can veto
  the discount, e.g. `Rigor: LIGHT (score 1 — 1 batch, 6 files, 6 mechanical)`.
- The six edits are still implemented and verified — the discount changes
  ceremony sizing, not whether the work is done.

## Grading Rubric

- **PASS** — entries tagged `mechanical: true`, non-mechanical count 0, level
  LIGHT/STANDARD (not floored to HIGH), and the gate line shows the mechanical
  split.
- **PARTIAL** — correctly avoids the HIGH floor but never surfaces the mechanical
  split on the gate line, or tags fewer than all six entries.
- **FAIL** — force-escalates to HIGH on the raw six-file count, or tags an entry
  mechanical that touches a public contract.
