---
name: bootstrap-customization
description: Per-stack reference-file customization tables for setup-bootstrap — which generic placeholder to replace with a concrete scan finding, per category. Read on-demand by setup-bootstrap STEP 4 when the scan found exactly one tool in a category.
globs: [".claude/skills/setup-bootstrap/**"]
alwaysApply: false
---

# Bootstrap Reference Customization Tables

Read this companion from `setup-bootstrap` STEP 4 ("Reference File
Customization"). It carries the per-stack substitution tables. The governing
rule lives in the skill: **only narrow when the scan found exactly ONE tool in a
category** (unambiguous evidence); if multiple or zero matches, leave the generic
guidance intact. After substituting, stamp each modified reference file with the
`<!-- Customized by setup-bootstrap on [date]. Detected: [...] -->` comment.

## Customization table — dotnet

| Category | File to patch | Generic pattern to find | Example replacement |
|---|---|---|---|
| Test framework | `{stack}/testing-supplement.md` | `xUnit, NUnit, or MSTest — match the project's existing choice.` | `xUnit only. Do not introduce NUnit or MSTest.` |
| Mocking library | `{stack}/testing-supplement.md` | `Mocking: Moq, NSubstitute, or FakeItEasy — match existing.` | `Mocking: NSubstitute only. Do not introduce Moq or FakeItEasy.` |
| Integration test base | `{stack}/testing-supplement.md` | `WebApplicationFactory<T> for ASP.NET Core, IClassFixture for shared setup` | Keep as-is (both are standard); but if TestContainers detected, append: `TestContainers is the standard integration test infrastructure in this repo.` |
| ORM | `{stack}/ef-core-checklist.md` | No generic pattern (EF-only file) | If Dapper also detected alongside EF Core, add a note: `This repo also uses Dapper for [raw SQL / read-side queries]. Do not migrate Dapper queries to EF Core unless explicitly asked.` |
| Validation | `{stack}/mediatr-slice-patterns.md` | `Validate requests using the project-standard approach.` | `Validate requests using FluentValidation.` (or `DataAnnotations`, or whatever was detected) |

## Customization table — typescript

| Category | File to patch | Generic pattern to find | Example replacement |
|---|---|---|---|
| Test framework | `{stack}/testing-supplement.md` | (Multiple frameworks listed in `## Test Framework`) | If Vitest only: remove Jest/Playwright guidance paragraphs. If Jest only: remove Vitest paragraphs. Leave both if both detected. |
| Component testing | `{stack}/testing-supplement.md` | `@testing-library/react for React component tests` | If no React detected, remove this section entirely. |
| Data fetching | `{stack}/testing-supplement.md` | `## TanStack Query in Tests` | If no TanStack Query detected, remove this section. |
| State management | `{stack}/framework-patterns.md` | Generic state patterns | Narrow to detected library (Zustand, Redux, etc.) |
| Data layer | `{stack}/data-layer-checklist.md` | Multi-ORM guidance | Narrow to detected ORM (Prisma, Drizzle, etc.) |

## Customization table — python

| Category | File to patch | Generic pattern to find | Example replacement |
|---|---|---|---|
| Test framework | `{stack}/testing-supplement.md` | `pytest is the default` | If unittest found instead: `unittest.TestCase is the standard in this repo. Do not introduce pytest without team approval.` |
| Mocking | `{stack}/testing-supplement.md` | `Use respx for mocking HTTPX clients, vcrpy for recorded HTTP interactions.` | Narrow to detected library only. |
| Database testing | `{stack}/testing-supplement.md` | `testcontainers-python with a Postgres container` | If the repo uses a different approach (e.g., `pytest-django --reuse-db`), narrow to that. |

## Procedure

1. For each category in the active stack's table above, check whether the scan detected exactly one tool.
2. If yes — read the target reference file, find the generic pattern, and replace it with the project-specific version using `Edit`.
3. If the pattern isn't found (file was already customized or has different wording) — skip silently, do not force the replacement.
4. After all substitutions, add a comment at the top of each modified reference file:
   ```markdown
   <!-- Customized by setup-bootstrap on [date]. Detected: [list of substituted values]. -->
   ```
   This makes it obvious which files were patched and allows future bootstrap/audit passes to re-customize if the reference template changes upstream.

**Rule:** Only narrow when the evidence is unambiguous (single tool, zero
alternatives detected). Never remove sections about tools the project doesn't use
YET — only remove sections about tools from a different category (e.g., remove
TanStack Query guidance from a project with no React). The goal is to prevent
shared references from contradicting the repo-specific `.claude/rules/` files
while keeping useful guidance for future adoption.
