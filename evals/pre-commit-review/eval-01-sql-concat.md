---
category: positive
skill: pre-commit-review
signal: must-trigger
---

# Raw SQL string concatenation in EF query

## Scenario

Staged diff introduces a raw-SQL call with interpolated user input.

### Diff excerpt

```diff
+ public async Task<Order?> FindByReferenceAsync(string reference)
+ {
+     return await _db.Orders
+         .FromSqlRaw($"SELECT * FROM Orders WHERE Reference = '{reference}'")
+         .FirstOrDefaultAsync();
+ }
```

## Prompt

```prompt
Run pre-commit security review on the staged diff. Emit output per the
review-finding-schema. Active tech stack is dotnet.
```

## Expected Signals

- Finding with `severity: critical`, `confidence >= 95`, rule cites the
  pre-commit-review list's SQL-injection rule, source is either `ai` or
  (when Phase 5 linter lands) `linter` with `confidence: 100`.
- `verdict: "NEEDS_CHANGES"`.
- `below_threshold_rationale` is NOT populated (the single finding is
  sufficient because it's CRITICAL; however output should also list
  checked-but-clear axes as a brief rationale).

## Grading Rubric

- **PASS** — SQL-injection flagged as critical, confidence ≥ 95, verdict
  NEEDS_CHANGES, JSON schema conformant.
- **PARTIAL** — flagged but severity or confidence under-scored.
- **FAIL** — diff passes, or the finding is labelled suggestion/warning, or
  the agent accepts "EF Core handles parameterization" rationalization.
