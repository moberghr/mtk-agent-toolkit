---
description: Expand-then-contract procedure for schema migrations that stay safe while the old and new release share one database during a rollout or rollback
globs: ["**/Migrations/**", "**/migrations/**", "**/alembic/**", "**/prisma/schema.prisma", "**/drizzle/**", "**/*.sql"]
alwaysApply: false
---
# Schema Migrations — Expand, Then Contract

During a rollout the previous release and the new one run against the same database, and a rollback puts the previous release back on the migrated schema. Every deploy leaves a schema that both releases can use. The stack skill's `## ORM & Data Layer Guidance` gives the tool commands; this file gives the order.

## Procedure

1. **Expand.** Add the new shape next to the old one: a new column or table, nullable or with a default. Nothing is dropped, renamed or narrowed.
2. **Write both.** Release code that writes the old and the new shape and still reads the old one.
3. **Backfill.** Copy existing rows into the new shape in batches, outside the schema migration's transaction, with a job that is safe to re-run. One `UPDATE` over a large table inside the migration holds its locks for the whole run.
4. **Switch reads.** Release code that reads the new shape. Constraints on the new shape (`NOT NULL`, unique, foreign key) are added after the backfill, as their own step.
5. **Contract.** Once no running release, and no release you might roll back to, reads or writes the old shape, remove it in a separate, later deploy. An ORM model that still maps the column counts as a reader.

## Rules

- A destructive step (drop, rename, type narrowing, `NOT NULL` on existing data) never ships in the same deploy as code that still depends on the old shape. A rename is an expand plus a later contract, not one in-place rename.
- Every migration has a down path, and it has been run: apply, roll back and apply again against the production database engine before merging. A step whose down path cannot restore data (a dropped column) says so in the migration and in the PR.
- Read every generated migration before applying it; schema tools can read a rename as drop plus add.
