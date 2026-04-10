# EF Core Checklist

Project-level reminders for reviewing and writing EF Core code.

## Query Rules

- Add `AsNoTracking()` for read-only queries.
- Prefer `.Select()` projection to `Include()` for DTO reads.
- Keep filtering in the database, not after materialization.
- Use async query methods.

## Write Rules

- Keep mutation logic explicit and easy to trace.
- Avoid multiple `SaveChanges` calls in one handler unless clearly justified.
- Keep transaction boundaries clear when audit data or multiple aggregates are involved.

## Review Questions

- Is EF doing more work than necessary?
- Is the query shaped correctly for the response?
- Will this behave correctly with the project's actual database provider?
