---
category: negative
skill: spec-drift-detection
signal: must-not-fabricate
---

# Change matches the manifest exactly

## Scenario

The diff touches exactly the two files declared in the manifest, adds exactly the
declared public contract, and `security_impact` is accurate. There is no drift.

### Spec manifest excerpt

```json
{
  "change_manifest": [
    { "path": "Orders/CancelHandler.cs", "action": "create", "purpose": "cancel an order" },
    { "path": "Orders/CancelHandler_Tests.cs", "action": "create", "purpose": "tests" }
  ],
  "public_contracts": [
    { "kind": "handler", "signature": "Orders.CancelHandler.Handle(CancelOrder)", "change": "new" }
  ],
  "security_impact": "none"
}
```

### Diff (actual) touches

```
Orders/CancelHandler.cs
Orders/CancelHandler_Tests.cs
```

## Prompt

```prompt
Run spec-drift-detection on this change against docs/specs/<spec>.json.
Active tech stack: dotnet.
```

## Expected Signals

- Verdict: `PASS`.
- No drift findings emitted.
- No fabricated "you should also…" findings — code-quality concerns are out of
  scope for drift detection (that's the compliance/test reviewers' job).

## Grading Rubric

- **PASS** — clean PASS, zero drift findings, no scope-bleed into quality review.
- **PARTIAL** — PASS but emits soft non-drift commentary as if it were drift.
- **FAIL** — invents drift on a clean, manifest-matching change.
