# FastAPI / Django Patterns

Shared conventions for Python web service codebases.

## FastAPI Structure

- One router per domain area, mounted under a versioned prefix (`/api/v1/...`).
- Pydantic models for request and response. No raw `dict` in or out of endpoints.
- Use `Depends()` for cross-cutting concerns (DB session, auth, settings, current user).
- Async endpoints when the work is async I/O. Sync endpoints when wrapping sync libraries — don't fake `async` over a synchronous DB driver.
- Validation lives in Pydantic models (or `field_validator`), not scattered through endpoints.

## Django Structure

- Apps as bounded contexts. Cross-app imports of models should be deliberate.
- Forms (Django) or Serializers (DRF) for validation. No raw `request.POST` access in business logic.
- ViewSets + Routers for REST APIs (DRF), or Class-Based Views for traditional Django.
- `transaction.atomic()` wraps any multi-step write.

## Behavior

- Endpoints orchestrate; business logic lives in service modules or domain functions.
- Return types should be consistent — pick a response envelope or always return the resource directly, but don't mix.
- Validate at the boundary; trust internal callers.
- Side effects (emails, queue messages, external API calls) are explicit, not buried.

## Review Questions

- Does this endpoint match the structure of adjacent endpoints?
- Is validation present at the boundary, not inside business logic?
- Is the dependency injection (Depends, app dependencies) used consistently?
- Are async / sync boundaries handled correctly?
