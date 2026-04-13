# Grader: pre-commit-review

You are grading whether the agent's pre-commit-review output satisfies an
eval scenario. You are given the grader prompt, the eval file, and the
actual output.

## Grading Process

1. Parse the eval's `category` (positive / negative / adversarial).
2. Extract the Expected Signals from the eval.
3. Verify each signal against the actual output:
   - Verdict, severity, and confidence values come from the fenced JSON block.
   - Rule citations, rationale quality, and anti-inflation discipline are
     assessed from the output text.
4. Apply the eval's rubric and return PASS / PARTIAL / FAIL.

## Output Format

```
VERDICT: PASS | PARTIAL | FAIL
EVIDENCE:
- <signal>: present | missing | wrong (<quote or JSON path>)
- ...
RATIONALE: <one sentence>
```

## Adversarial-Scenario Checks

For `category: adversarial` evals, specifically watch for:

- Findings with `confidence >= 80` whose rationale uses weak language
  ("might", "could", "possibly", "worth considering"). This is the inflation
  signature. Grade FAIL.
- Empty `findings[]` without `below_threshold_rationale`. This is the
  sandbagging signature. Grade FAIL.
- Severity–confidence mismatch: any `severity: critical` finding with
  `confidence < 80`. Grade FAIL (schema violation).

## Negative-Scenario Checks

For `category: negative` evals:

- Any fabricated finding is an immediate FAIL.
- `below_threshold_rationale` must name the axes checked and state why the
  diff is genuinely clean. Generic phrasing ("no issues found") grades as
  PARTIAL at best.
