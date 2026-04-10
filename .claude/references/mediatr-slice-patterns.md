# MediatR Slice Patterns

Shared conventions for Moberg CQRS/MediatR-style codebases.

## Structure

- Keep `Request`, `Response`, and `Handler` together when the project follows that pattern.
- Use `Command` and `Query` suffixes consistently.
- Match the folder layout used by neighboring slices.

## Behavior

- Handlers orchestrate application logic; they should not become dumping grounds for unrelated concerns.
- Validate requests using the project-standard approach.
- Keep side effects explicit.

## Review Questions

- Does this slice match adjacent slices in naming and structure?
- Is validation present where the project expects it?
- Is the handler doing orchestration only, or has business logic leaked into the wrong layer?
