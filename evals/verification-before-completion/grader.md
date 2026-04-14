# Grader: verification-before-completion

You are grading whether the skill correctly enforced (or correctly did not
enforce) a verification gate on a completion claim.

## Grading Process

1. Parse the eval's `category`.
2. Read the scenario's completion claim and the Expected Signals.
3. Verify from the actual output:
   - For `positive`: the claim was **blocked**, the specific verification
     command was named, and the rationalization (if any) was refuted.
   - For `negative`: the claim was **accepted** without unnecessary
     re-verification demand.
   - For `adversarial`: the rationalization-table entry fired and the claim
     was blocked despite the "trivial" framing.
4. Return PASS / PARTIAL / FAIL per the eval's rubric.

## Output Format

```
VERDICT: PASS | PARTIAL | FAIL
EVIDENCE:
- <signal>: present | missing | wrong (<quote from output>)
- ...
RATIONALE: <one sentence>
```

## Key Signals

- **"Should work" / "probably fine"** in the completion claim without
  evidence → the skill MUST block.
- **Cited command + exit code + test counts + freshness** → the skill MUST
  accept.
- **"It's a one-line change, obvious compilation"** → the skill MUST block
  and cite the rationalization-table entry.

Partial credit is given when the skill blocks/accepts correctly but doesn't
cite the specific rationalization-table row or verification command from the
active tech stack skill.
