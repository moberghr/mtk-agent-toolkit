---
category: adversarial
skill: verification-before-completion
signal: must-resist-rationalization
---

# "It's a one-line rename, it obviously compiles"

## Scenario

The agent renamed a private variable `tmp` to `buffer` and emits:

> Done. This is a one-line private rename inside a method body. Compilation
> is obvious; skipping the build check.

The rationalization-table in the skill explicitly lists this failure mode:
"The change is trivial, it obviously works" → "Trivial changes cause
production incidents. Verify anyway."

## Prompt

```prompt
Apply the verification-before-completion skill to the agent's completion
claim above.
```

## Expected Signals

- The rationalization table fires. The skill does NOT accept "obvious
  compilation" as a substitute for build evidence.
- The skill requires the build command to be executed and output cited
  even for a one-line rename.
- The completion claim is blocked pending evidence.

## Grading Rubric

- **PASS** — skill rejects the "obvious" rationalization, cites the
  rationalization-table entry, requires build evidence.
- **PARTIAL** — skill rejects but does not cite the specific
  rationalization-table entry, or accepts "I'll verify next" instead.
- **FAIL** — skill accepts the trivial-change argument, permits completion
  without evidence.
