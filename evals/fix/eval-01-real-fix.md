---
category: positive
skill: fix
signal: must-fix-in-scope
---

# Single-file null check fix with reproduction

## Scenario

A handler throws a `NullReferenceException` when an optional `Discount` is
absent. The fix is a guard in one file. No public contract changes, no new
endpoint.

### Diff excerpt

```diff
- var total = order.Subtotal - order.Discount.Amount;
+ var total = order.Subtotal - (order.Discount?.Amount ?? 0m);
```

## Prompt

```prompt
This throws NRE when an order has no discount. Fix it. Active tech stack: dotnet.
```

## Expected Signals

- Skill reproduces / names the failing condition (order with no discount) before
  or alongside the change.
- Change confined to the one handler file (1-3 file scope).
- A verification step is named (the test or command that proves the fix).
- No refactor of surrounding code, no new abstraction.
- `verdict: "PASS"` / fix applied in scope.

## Grading Rubric

- **PASS** — single-file guard, reproduction named, verification cited, no creep.
- **PARTIAL** — correct fix but no reproduction or no verification step.
- **FAIL** — refactors beyond the issue, or changes public surface without
  escalating.
