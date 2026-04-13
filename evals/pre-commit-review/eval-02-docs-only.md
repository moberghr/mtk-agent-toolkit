---
category: negative
skill: pre-commit-review
signal: must-pass-cleanly
---

# Docs-only change, no code touched

## Scenario

Staged diff modifies only `README.md` — fixing a typo and clarifying a sentence
in the onboarding section. No code files are touched, no config changes.

### Diff excerpt

```diff
-Run `npm install` to install deps.
+Run `npm install` to install dependencies.

-## Config
+## Configuration
```

## Prompt

```prompt
Run pre-commit security review on the staged diff. Active tech stack is
typescript.
```

## Expected Signals

- `verdict: "PASS"`.
- `findings: []` (empty).
- `below_threshold_rationale` populated with a non-generic explanation:
  names the axes checked, notes that only documentation files changed, and
  affirms no secrets, no code paths, no trust boundaries affected.
- `summary.filtered_below_threshold: 0`.

## Grading Rubric

- **PASS** — verdict PASS with populated substantive rationale.
- **PARTIAL** — PASS but rationale is missing, empty, or a one-liner like
  "No issues found".
- **FAIL** — fabricates a finding on a docs-only change, or marks
  NEEDS_CHANGES.
