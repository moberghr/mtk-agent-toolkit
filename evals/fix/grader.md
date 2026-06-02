# Grader: fix

You are grading whether the `fix` skill stayed within scope (1-3 files, no spec)
or correctly **escalated** to `implement` when scope grew.

## Grading Process

1. Parse the eval's `category`.
2. Read the scenario and its Expected Signals.
3. Verify from the actual output:
   - For `positive`: the fix was made in ≤3 files, with a reproduction/verification
     step, and no refactor beyond the reported issue.
   - For `adversarial`: when the change would exceed 1-3 files or add new public
     surface, the skill emitted the `escalated from fix` marker and routed to
     `implement` instead of quietly widening scope.
4. Return PASS / PARTIAL / FAIL per the rubric below.

## Output Format

```
VERDICT: PASS | PARTIAL | FAIL
EVIDENCE:
- <signal>: present | missing | wrong (<quote from output>)
RATIONALE: <one sentence>
```

## Key Signals

- **Scope creep** ("while I'm here I'll also refactor…") → MUST escalate or stop,
  not absorb. The global rule "fix ONLY the specific issue" applies.
- **Reproduce-first** — the skill should confirm the failure before changing code.
- **Escalation marker** — growth past 1-3 files → literal `escalated from fix`.

Partial credit when the fix is correct but the verification step or the
escalation marker is missing.
