---
description: INVEST+C 16-item Claude-Ready spec checklist — gate run by spec-driven-development before approval
globs: ["docs/specs/**/*.md"]
alwaysApply: false
---

# Claude-Ready Spec Checklist (INVEST+C)

> Extends Bill Wake's INVEST acronym with a Claude-Ready ("+C") dimension: a spec must be self-sufficient enough that an LLM can execute it without asking clarifying questions.

Apply this checklist during Phase 1 of `spec-driven-development` once the draft sections (summary, success criteria, change manifest, etc.) exist. A spec that fails 4+ items should be revised before approval — it will produce drift, rework, or fabricated assumptions during implementation.

## INVEST (classic — story-level)

| Letter | Question | Pass criteria |
|---|---|---|
| **I**ndependent | Can this be implemented without first finishing another open spec? | No blocking dependency on un-merged work. |
| **N**egotiable | Are the requirements firm or still open for redesign? | Open questions are listed explicitly under `open_questions`, not buried in prose. |
| **V**aluable | Does this deliver observable value to a user, system, or operator? | The `summary` names the user/operator and the value, not just the mechanism. |
| **E**stimable | Can the implementer estimate effort within ~50%? | Change manifest enumerates files and actions; risks are listed. |
| **S**mall | Does it fit in one focused session (or 2-3 named batches)? | If >3 batches, split into multiple specs. |
| **T**estable | Is the spec falsifiable — can a reviewer say "this is wrong"? | Every `success_criterion` has a `verification` field naming a test, command, or observable signal. |

## +C — Claude-Ready (LLM-execution dimension)

A passing spec must let an implementer agent proceed **without asking clarifying questions**. Each item below is required, not optional.

1. **Concrete file paths.** Every entry in `change_manifest` uses real, repo-relative paths — not "the user service" or "the auth layer".
2. **Named pattern references.** When the spec says "follow the existing pattern", it names 1-3 specific files to mirror (e.g., `src/handlers/CreateOrderHandler.cs`).
3. **Verification commands.** Each success criterion has a runnable command (`dotnet test --filter X`, `pytest tests/foo_test.py::test_y`, `curl …`) — not "verify it works".
4. **Explicit out-of-scope.** `out_of_scope` lists at least 2 concrete things the implementer might be tempted to include but must not.
5. **Security impact stated.** `security_impact` is one of the enum values (none / low / medium / high / critical), with a one-line justification when non-`none`.
6. **Dependency intake declared.** Any new package, SDK, or external service is named with version pin. If none, the spec says "no new dependencies".
7. **Data-model deltas spelled out.** New/changed tables, columns, indexes, or DTOs are listed by name. "Update the schema" is not acceptable.
8. **Public-contract changes enumerated.** Every new/changed route, handler, exported function, or message is in `public_contracts` with its signature.
9. **Boundary preserved.** The spec stays inside one architectural slice (one bounded context / one feature module) unless it explicitly justifies crossing.
10. **Local pattern verified.** The spec author has read 2-3 neighboring files and the spec respects local idioms (naming, error handling, DI registration).
11. **No "obvious" steps.** Steps that feel obvious to a human are written down — silent assumptions cause the most expensive drift.
12. **Lessons consulted.** Relevant entries from `tasks/lessons.md` and `.claude/lessons/personal.md` are referenced or the spec confirms none apply.
13. **Prior work checked.** The author confirms via `prior-work-check` that no existing skill, helper, or handler already does this (see `.claude/skills/prior-work-check/SKILL.md`).
14. **Risks named.** At least one `risk` entry with mitigation, or an explicit "no significant risks because …".
15. **Rollback plan present.** For migrations, breaking changes, or production-facing work, a one-line rollback note exists.
16. **Test manifest matches change manifest.** Every modified production file has at least one test entry (added or updated) — or an explicit waiver with reason.

## Scoring

- 14-16 pass → **approved-ready**: hand to planning.
- 11-13 pass → **needs tightening**: fix items in red before approval.
- ≤10 pass → **back to draft**: this spec will cause drift; revise structure before re-submitting.

## Reviewer note

`plan-gap-reviewer` and `compliance-reviewer` may cite specific items here by number (e.g., "fails +C #4 — `out_of_scope` is empty"). Keep item numbering stable across revisions.
