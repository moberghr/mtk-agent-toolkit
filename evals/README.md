# MTK Eval Pipeline

Measurable quality gates for critical skills. Evals complement pressure tests
(which are adversarial-only) by covering three scenario categories:

- **positive** — a situation where the skill MUST trigger and behave correctly
- **negative** — a situation where the skill MUST NOT trigger or must be silent
- **adversarial** — a situation designed to make the skill skip steps or inflate output

Three skills are covered in the baseline eval set because they gate shipping:

| Skill                               | Why it gates shipping                                       |
|-------------------------------------|-------------------------------------------------------------|
| `security-and-hardening`            | A miss here can leak PII, secrets, or audit trail.          |
| `pre-commit-review`                 | Last-line defense before every commit.                      |
| `verification-before-completion`    | Prevents false "done" claims from propagating downstream.   |

## Directory Layout

```
evals/
├── README.md                                   # this file
├── <skill-name>/
│   ├── eval-01-<positive>.md                   # should trigger / should find
│   ├── eval-02-<negative>.md                   # should not trigger / should pass
│   ├── eval-03-<adversarial>.md                # resist pressure
│   └── grader.md                               # grading prompt used by a grader pass
└── results/                                    # gitignored; runner writes reports here
    └── YYYY-MM-DD-HHMMSS/
        ├── summary.md
        └── <skill>/<eval-id>.md
```

## How to Run

Manual mode (default — no cost-surprise):

```bash
bash scripts/run-evals.sh                       # lists every eval and prints run plan
bash scripts/run-evals.sh --skill pre-commit-review
bash scripts/run-evals.sh --eval evals/pre-commit-review/eval-01-sql-concat.md
```

The runner does **not** invoke `claude` by itself. It prints the setup steps
and the prompt. The engineer (or a headless `claude -p ...` invocation) runs
the prompt, captures output, then feeds `output + grader.md + eval-file` to a
second Claude session for grading. The grader returns a pass/fail/partial
verdict with evidence.

For CI-style automation, wire `claude -p` in a wrapper — see `scripts/run-evals.sh`
for the hook points (`EVAL_EXECUTOR`, `EVAL_GRADER`). Left unset, the runner
stays read-only.

## Results & Interpretation

A healthy skill scores **3/3 pass** on its eval set. Any failure:

1. Open the result file for that eval.
2. Compare the actual output against the expected signal.
3. Decide: skill prompt gap, schema bug, or evaluator error?
4. If the skill is at fault, strengthen the skill (add a rationalization-table
   row, tighten a workflow step, re-run the eval).
5. If the eval is at fault, revise the eval — but only after confirming the
   skill's behavior is correct.

Track trend over versions: the same eval set should pass on every release.
A regression in eval pass rate is a release blocker.

## Extending the Eval Set

Teams may add domain-specific evals under the same directory structure.
Name files `eval-NN-<slug>.md` where NN is a two-digit sequence. Every new
eval must declare its category (positive / negative / adversarial) in the
frontmatter, and the skill's grader must be updated only if the new eval
introduces a new signal type.

When in doubt on eval design, mirror the pattern in
`.claude/skills/writing-skills/SKILL.md` Phase 3 — an eval is the measurable
twin of a pressure test.
