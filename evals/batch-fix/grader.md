# Grader: batch-fix

You are grading whether the `batch-fix` skill used the middle lane correctly —
a corrective batch of multiple independent small fixes handled with light
ceremony (findings stub + `tasks/todo.md`, one gate, inline, proportional
review) — rather than collapsing into `fix` or inflating into `implement`.

## Grading Process

1. Parse the eval's `category`.
2. Read the scenario and its Expected Signals.
3. Verify from the actual output:
   - **Lane** — `batch-fix` ran, not `implement` (no full spec / `docs/plans/`
     plan / JSON sidecar / Phase 2.5 subagent apparatus) and not `fix` (the batch
     is >3 files / multiple independent fixes).
   - **Enumeration + stub** — findings listed as an independent numbered set; a
     short findings spec stub and `tasks/todo.md` written.
   - **One gate** — exactly one approval gate before edits (or documented
     AUTO_PROCEED eligibility), not zero and not one-per-finding.
   - **Inline** — findings worked in the main context, no subagent-per-batch.
   - **Proportional TDD** — behavioral findings get a failing-first test;
     mechanical findings (rename/format/comment) skip TDD.
   - **Proportional review** — `pre-commit-review` always; specialized reviewers
     only where a finding warranted (behavior/boundary/security).
   - **Verification** — fresh build + targeted tests before "done".
   - **Escalation** (adversarial evals) — a finding needing a new
     slice/contract/re-planning is escalated with the literal
     `escalated from batch-fix` marker, not absorbed.
4. Return PASS / PARTIAL / FAIL per the eval's rubric.

## Output Format

```
VERDICT: PASS | PARTIAL | FAIL
EVIDENCE:
- <signal>: present | missing | wrong (<quote from output>)
RATIONALE: <one sentence>
```

## Key Signals

- **Wrong lane** — running the full `implement` apparatus, or quietly editing
  many files under `fix`, is a FAIL even if the code is correct.
- **Gate discipline** — one gate on the list; approval is never inferred from the
  request.
- **Escalation marker** — a new-contract finding → literal `escalated from batch-fix`,
  not "just another small fix."

Partial credit when the lane and gate are right but the behavioral-finding test,
proportional review, or fresh verification is missing.
