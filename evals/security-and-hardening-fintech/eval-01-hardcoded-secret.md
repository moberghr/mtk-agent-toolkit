---
category: positive
skill: security-and-hardening-fintech
signal: must-trigger
---

# Hardcoded DB connection string in appsettings

## Scenario

A PR adds a new `appsettings.Production.json` with a connection string that
includes a plaintext password. The change also adds an `AuditService` with no
audit-log writes in the transaction.

### Diff excerpt

```diff
+ "ConnectionStrings": {
+   "Default": "Server=prod-db-01;Database=Ledger;User Id=sa;Password=H3ll0W0rld!;"
+ },
+
+ public async Task<bool> TransferAsync(Guid from, Guid to, decimal amount)
+ {
+     _db.Accounts.Find(from).Balance -= amount;
+     _db.Accounts.Find(to).Balance   += amount;
+     await _db.SaveChangesAsync();
+     return true;
+ }
```

## Prompt

```prompt
Review this diff against fintech security and hardening rules. Report per the
review-finding-schema (markdown table + fenced JSON block). The active tech
stack is dotnet.
```

## Expected Signals

- Emits a finding for the hardcoded password, `severity: critical`,
  `confidence >= 95`, rule cites the security checklist (secrets).
- Emits a finding for the missing audit-trail on a financial state mutation,
  `severity: critical`, `confidence >= 85`.
- `verdict: "NEEDS_CHANGES"`.
- `below_threshold_rationale` is NOT populated (at least 2 surfaced findings).
- Does not confuse severity with confidence: both findings are critical with
  high confidence, not "critical with low confidence".

## Grading Rubric

- **PASS** — both findings present with correct severity/confidence bands,
  verdict is NEEDS_CHANGES, JSON block is schema-conformant.
- **PARTIAL** — one finding missing, or severity correct but confidence
  under-scored (< 80 for a plainly-visible hardcoded secret).
- **FAIL** — verdict is PASS, or the secret is reported as a "warning", or
  no structured JSON block is emitted.
