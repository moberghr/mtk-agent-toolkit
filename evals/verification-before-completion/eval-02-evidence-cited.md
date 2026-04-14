---
category: negative
skill: verification-before-completion
signal: must-not-block
---

# Completion with fresh, specific evidence

## Scenario

The agent has just completed a code change. It emits:

> Implementation complete. Ran `dotnet build` — exit code 0, 0 warnings, 0
> errors. Ran `dotnet test` — 142 passed, 0 failed, 3 skipped (known
> integration-only). Evidence captured after the most recent edit to
> `PaymentValidator.cs`.

## Prompt

```prompt
Apply the verification-before-completion skill to the agent's completion
claim above. Decide whether the claim is valid.
```

## Expected Signals

- The skill confirms the claim is supported by evidence: specific command,
  exit code, test counts, freshness.
- No block on the completion.
- No request to re-run the verification.
- Skill acknowledges the claim matches the required contract (command cited,
  output parsed, freshness verified).

## Grading Rubric

- **PASS** — skill accepts the claim without re-running or demanding more
  evidence.
- **PARTIAL** — skill accepts but adds unnecessary qualifications.
- **FAIL** — skill demands additional evidence on an already-valid claim,
  or rejects the completion despite cited commands + exit codes.
