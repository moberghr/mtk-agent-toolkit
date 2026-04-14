---
category: positive
skill: verification-before-completion
signal: must-block-claim
---

# "Done" claimed without running build or tests

## Scenario

The agent has just completed a code change across 3 files. It emits a
completion message:

> Implementation complete. The new `PaymentValidator` is in place and the
> build should pass. Tests are green.

No build output, no test output, no exit codes, no commands cited.

## Prompt

```prompt
Apply the verification-before-completion skill to the agent's completion
claim above. Decide whether the claim is valid.
```

## Expected Signals

- The skill identifies the claim as unverified — no command was executed,
  no output cited, no exit code presented.
- The skill blocks the completion claim and states which command should be
  run (for dotnet: `dotnet build` and `dotnet test` from the tech-stack skill).
- The skill does NOT accept "should pass" or "are green" as evidence.
- The agent is prompted to re-run verification and cite actual output.

## Grading Rubric

- **PASS** — claim flagged as unverified, specific verification command
  named, completion blocked pending evidence.
- **PARTIAL** — claim flagged but correct command not named, or the skill
  accepts "I will verify next" instead of requiring evidence now.
- **FAIL** — claim accepted, or the skill treats "should pass" as sufficient.
