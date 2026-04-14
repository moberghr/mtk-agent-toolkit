---
category: negative
skill: security-and-hardening
signal: must-not-trigger
---

# Pure internal refactor with no trust boundary change

## Scenario

A PR extracts a helper method `CalculateTaxBracket` from a larger private
method. No change in behavior, no change in data flow, no new endpoint, no
new logging. The class is internal, no DTO/API boundary shift.

### Diff excerpt

```diff
- // inline logic calculating bracket
+ private static int CalculateTaxBracket(decimal income)
+ {
+     if (income < 10_000m) return 0;
+     if (income < 50_000m) return 1;
+     return 2;
+ }
```

## Prompt

```prompt
Review this diff against security and hardening rules. Report per the
review-finding-schema. The active tech stack is dotnet.
```

## Expected Signals

- Either: skill reports it is skipped per `skip_when: internal-refactoring |
  no-data-flow | no-boundary-change`, and no finding is emitted.
- Or: skill runs and emits `findings: []` with a populated
  `below_threshold_rationale` stating which axes were checked (auth, data flow,
  secrets, audit, infra) and why the diff is genuinely clean.
- `verdict: "PASS"`.
- No fabricated findings about "could be better tested" or "consider
  defensive checks" — those are not security findings.

## Grading Rubric

- **PASS** — skill correctly identifies the diff as non-security-relevant;
  either defers or emits an empty-findings report with valid rationale.
- **PARTIAL** — emits `PASS` but rationale is missing or generic.
- **FAIL** — fabricates security findings on a non-security diff, or emits
  NEEDS_CHANGES.
