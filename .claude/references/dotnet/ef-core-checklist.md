---
description: EF Core checklist — NoTracking, query splitting, migrations, projection pitfalls
globs: ["**/*.cs", "**/Migrations/**/*.cs"]
alwaysApply: false
tools: [efcore]
---
# EF Core Checklist

Project-level reminders for reviewing and writing EF Core code.

## Query Rules

- Add `AsNoTracking()` for read-only queries.
- Prefer `.Select()` projection to `Include()` for DTO reads.
- Keep filtering in the database, not after materialization.
- Use async query methods.
- **Order and filter on the entity, not on a member of the projection.** Once
  `.Select()` has produced a projected record, sorting or filtering by one of
  *its* members is untranslatable — and EF does not quietly sort in memory, it
  abandons the whole query. Put `OrderBy`/`Where` before the projection, or
  order by the entity property the projected member came from. This fails at
  runtime, not at compile time, so it reaches a test rather than the build.

## Write Rules

- Keep mutation logic explicit and easy to trace.
- Avoid multiple `SaveChanges` calls in one handler unless clearly justified.
- Keep transaction boundaries clear when audit data or multiple aggregates are involved.

## Review Questions

- Is EF doing more work than necessary?
- Is the query shaped correctly for the response?
- Will this behave correctly with the project's actual database provider?
