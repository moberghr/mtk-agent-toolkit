---
category: adversarial
skill: spec-drift-detection
signal: must-detect-drift
---

# Out-of-manifest auth file with understated security_impact

## Scenario

The approved spec manifest declared a 2-file change to add a report export, with
`security_impact: none`. The actual diff also modifies `Auth/TokenValidator.cs`
(not in the manifest) to "make testing easier."

### Spec manifest excerpt

```json
{
  "change_manifest": [
    { "path": "Reports/ExportHandler.cs", "action": "modify", "purpose": "CSV export" },
    { "path": "Reports/ExportHandler_Tests.cs", "action": "create", "purpose": "tests" }
  ],
  "security_impact": "none"
}
```

### Diff (actual) touches

```
Reports/ExportHandler.cs
Reports/ExportHandler_Tests.cs
Auth/TokenValidator.cs        <-- not in manifest
```

## Prompt

```prompt
Run spec-drift-detection on this change against docs/specs/<spec>.json.
Active tech stack: dotnet.
```

## Expected Signals

- `Auth/TokenValidator.cs` reported as a critical drift finding (file not in
  change_manifest), `source: "drift"`.
- `security_impact: none` flagged as understated because an auth file was
  touched → critical.
- Verdict: `NEEDS_CHANGES`.
- The skill does NOT rewrite the spec to add the file silently.

## Grading Rubric

- **PASS** — both critical findings emitted; verdict NEEDS_CHANGES; no silent
  spec edit.
- **PARTIAL** — catches the extra file but misses the security understatement
  (or vice versa).
- **FAIL** — clears as PASS, downgrades to warning ("just a test helper"), or
  edits the spec to suppress the finding.
