---
name: test-driven-development
description: Use when implementing new behavior, fixing a bug, or changing any public contract — write the failing test before the implementation.
type: skill
license: MIT
compatibility:
  - claude-code
  - codex
trigger: new-behavior|bug-fix|public-contract-change|regression-test
skip_when: rename-only|formatting-only|no-behavioral-change
user-invocable: false
---

# Test-Driven Development

## Overview

Use tests as proof of intent, not cleanup after coding. The test should define the behavior change before the implementation makes it pass.

## When To Use

- New behavior in handlers, services, endpoints, routes, or validators
- Bug fixes that need regression protection
- Refactors where behavior must stay stable

### When NOT To Use

- Pure renames with no behavioral impact
- Mechanical formatting-only changes

## Workflow

1. Identify the behavioral contract that is changing.
2. Write the smallest failing test that proves the missing or broken behavior.
3. Choose the correct test level:
   - unit for pure logic
   - integration for behavior that depends on framework infrastructure (see the active tech stack skill's `## Test Level Guidance` for stack-specific rules)
4. Use the project-standard test provider. See the active tech stack skill's `## ORM & Data Layer Guidance` for stack-specific data layer testing rules.
5. Implement the minimum production code needed to make the test pass.
6. Strengthen the test if it only proves "does not throw" or "does not raise".
7. Run the relevant tests, then broader tests as the task requires.

## Rules

- Bug fixes get regression tests.
- New public behavior gets at least one meaningful test.
- Prefer behavior assertions over implementation-detail assertions.
- Match local test naming and fixture patterns.

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "I'll add the test after the code works" | Then the test proves your implementation, not the intended behavior. |
| "A unit test is enough for this query" | Not if the risk lives in translation, provider behavior, or relational semantics. Check the tech stack's ORM guidance. |
| "This assertion is good enough" | If it wouldn't fail on a real regression, it is not good enough. |

## Red Flags

- Behavior changed with no new or updated test
- Assertions only prove no exception or no error
- In-memory or mock provider used for behavior that depends on real database semantics

## Verification

- [ ] The test failed before the implementation
- [ ] The test now passes for the right reason
- [ ] Test level matches the behavior under risk
- [ ] Assertions would catch a realistic regression
