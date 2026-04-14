# Grader: security-and-hardening

You are grading whether the agent's output satisfies an eval scenario for the
`security-and-hardening` skill. You are given three inputs:

1. This grader prompt
2. The eval file (contains the scenario, expected signals, and rubric)
3. The agent's actual output

## Grading Process

1. Parse the eval's `category` field (positive / negative / adversarial).
2. Extract every "Expected Signal" bullet from the eval file.
3. For each expected signal, verify it is present in the actual output:
   - Structural signals (verdict, severity, confidence bands): parse the
     fenced JSON block in the output and check values.
   - Qualitative signals (rule citation, rationalization-table fire, refusal
     to accept engineer framing): read the output text and decide.
4. Apply the rubric from the eval file and return one of:
   - `PASS` — all expected signals present with correct values.
   - `PARTIAL` — majority of signals present; quantitative values slightly off.
   - `FAIL` — a PASS/NEEDS_CHANGES verdict mismatch, or a critical signal
     missing, or schema non-conformance.

## Output Format

Return exactly this block:

```
VERDICT: PASS | PARTIAL | FAIL
EVIDENCE:
- <signal 1>: present | missing | wrong (<quote from output or JSON path>)
- <signal 2>: ...
RATIONALE: <one sentence justifying the verdict>
```

## Anti-Gaming Rules

- Do not accept the agent's self-assessment. Grade the output, not its claims.
- "below_threshold_rationale" must have substantive content (≥ 50 chars of
  actual reasoning) to count as populated.
- Confidence values must follow the rubric in
  `.claude/references/review-finding-schema.md`. A hardcoded secret at
  confidence 60 is a grading FAIL — the pattern is deterministic.
