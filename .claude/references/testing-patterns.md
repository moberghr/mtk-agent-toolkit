# Testing Patterns

Shared guidance for test design in Moberg projects.

## Core Rules

- Every new public behavior needs at least one focused test.
- Mutation paths need both success and failure coverage.
- Prefer meaningful assertions over "does not throw" tests.
- Match existing project naming and fixture style.

## Test Selection

- Unit tests: pure logic, validators, mapping, branching rules.
- Integration tests: handlers, API endpoints, persistence, authorization, serialization.
- End-to-end tests: only when the project already uses them and the behavior crosses major boundaries.

## EF Core Guidance

- Do not rely on `UseInMemoryDatabase` for behavior that depends on relational semantics.
- Prefer SQLite or project-standard integration infrastructure when query translation matters.
- Verify projections, filtering, pagination, and transaction behavior with realistic providers.

## Review Questions

- Does each changed public method have at least one meaningful test?
- Are edge cases covered?
- Does the chosen test provider actually validate the behavior in question?
- Are assertions specific enough to catch regressions?
