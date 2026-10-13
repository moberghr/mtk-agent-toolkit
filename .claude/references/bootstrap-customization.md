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

| Category | Where | Generic pattern to find | Example replacement |
|---|---|---|---|
| Test framework | stack reference | `xUnit, NUnit, or MSTest — match the project's existing choice.` | `xUnit only. Do not introduce NUnit or MSTest.` |
| Mocking library | stack reference | `Mocking: Moq, NSubstitute, or FakeItEasy — match existing.` | `Mocking: NSubstitute only. Do not introduce Moq or FakeItEasy.` |
| Integration test base | stack reference | `` `WebApplicationFactory<T>` for ASP.NET Core, `IClassFixture` for shared setup `` | Keep as-is (both are standard); but if TestContainers detected, append: `TestContainers is the standard integration test infrastructure in this repo.` |

## Customization table — typescript

| Category | Where | Generic pattern to find | Example replacement |
|---|---|---|---|
| Test framework | stack reference | (Multiple frameworks listed in `## Test Framework`) | If Vitest only: remove Jest/Playwright guidance paragraphs. If Jest only: remove Vitest paragraphs. Leave both if both detected. |
| Component testing | stack reference | `**@testing-library/react** for React component tests` | If no React detected, remove this section entirely. |
| Data fetching | stack reference | `## TanStack Query in Tests` | If no TanStack Query detected, remove this section. |

## Customization table — python

| Category | Where | Generic pattern to find | Example replacement |
|---|---|---|---|
| Test framework | stack reference | `pytest is the default` | If unittest found instead: `unittest.TestCase is the standard in this repo. Do not introduce pytest without team approval.` |
| Mocking | stack reference | `Use respx for mocking HTTPX clients, vcrpy for recorded HTTP interactions.` | Narrow to detected library only. |
| Database testing | stack reference | `testcontainers-python with a Postgres container` | If the repo uses a different approach (e.g., `pytest-django --reuse-db`), narrow to that. |

## Procedure

1. For each category in the active stack's table above, check whether the scan detected exactly one tool.
2. If yes — locate the file carrying the generic pattern (`grep -rlF '<pattern>' .claude/references/{stack}/`; file names change between releases, the pattern is the anchor) and replace it with the project-specific version using `Edit`.
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
