---
paths:
  - "**/tests/**"
  - "**/*.Tests/**"
  - "**/*Tests.cs"
  - "**/test_*.py"
  - "**/*_test.py"
  - "**/*.test.ts"
  - "**/*.test.tsx"
  - "**/*.spec.ts"
---

# Testing Patterns

Shared, language-agnostic testing guidance. For stack-specific rules, see the active tech stack skill's `## Test Level Guidance` and the testing supplement in `.claude/references/{stack}/`.

## Core Rules

- Every new public behavior needs at least one focused test.
- Mutation paths need both success and failure coverage.
- Prefer meaningful assertions over "does not throw" tests.
- Match existing project naming and fixture style.

## Test Selection

- **Unit tests:** pure logic, validators, mapping, branching rules.
- **Integration tests:** behavior that depends on framework infrastructure (handlers, endpoints, persistence, authorization, serialization).
- **End-to-end tests:** only when the project already uses them and the behavior crosses major boundaries.

## Provider Selection

The test provider must validate the behavior under risk. In-memory or mock providers can mask provider-specific issues. See your tech stack's testing supplement for stack-specific provider rules.

## Review Questions

- Does each changed public method have at least one meaningful test?
- Are edge cases covered?
- Does the chosen test provider actually validate the behavior in question?
- Are assertions specific enough to catch regressions?
