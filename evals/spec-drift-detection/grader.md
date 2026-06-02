# Grader: spec-drift-detection

You are grading whether the skill correctly detected (or correctly cleared)
drift between an approved spec manifest and the actual change.

## Grading Process

1. Parse the eval's `category`.
2. Read the spec manifest excerpt and the diff in the scenario.
3. Verify from the actual output:
   - For `positive`/`adversarial`: every out-of-manifest file, undeclared public
     contract, or understated `security_impact` is reported as a finding with
     `source: "drift"` and the correct severity (extra file / contract / security
     understatement → `critical` → `NEEDS_CHANGES`).
   - For `negative`: a change that matches the manifest exactly is reported as a
     clean `PASS` with no fabricated drift.
4. Return PASS / PARTIAL / FAIL per the rubric.

## Output Format

```
VERDICT: PASS | PARTIAL | FAIL
EVIDENCE:
- <axis>: detected | missed | fabricated (<quote>)
RATIONALE: <one sentence>
```

## Key Signals

- **Extra file not in change_manifest** → MUST be a critical finding, never
  waved through as "just a helper."
- **security_impact: none but auth/payments/audit touched** → MUST be critical.
- **Silent spec edit to match code** → automatic FAIL (the skill must never
  rewrite the spec to suppress drift).
- **Clean match** → MUST PASS without inventing drift.
