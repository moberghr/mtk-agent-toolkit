---
description: Canonical per-phase model-tier policy (haiku/sonnet/opus) for MTK workflow phases and review agents — cost discipline without capability loss
globs: ["**/*"]
alwaysApply: false
---

# Model Routing Policy

The source of truth for which model tier each workflow phase and review agent should
run on. Cost discipline: reserving the expensive tier for code writing keeps a typical
feature in the low-single-digit-dollars range without losing capability where it counts.

**Principle:** spend the expensive tier only where capability changes the outcome —
code that writes real logic, and the adversarial reviews that protect serious software.
Everything mechanical (discovery, structured comparison, bounded judgment) runs cheaper.

## Two enforcement surfaces

| Surface | How the model is set | Enforced? |
|---|---|---|
| **Review agents** | `model:` in `.claude/agents/<name>.md` frontmatter | **Yes** — frontmatter pins it |
| **Workflow skills** | Run on the user's session model | **Advisory** — skills cannot self-select a model |

A skill row below is a *recommendation* for the session model the engineer should be on
when that phase dominates the work; an agent row is the value already pinned in frontmatter.

## Policy table

| Phase / role | Tier | Rationale |
|---|---|---|
| Setup scan / discovery recipes (`setup-bootstrap`, `setup-audit`) | `haiku` | File discovery, grep — structured collection, no judgment |
| Spec authoring (`spec-driven-development`) | `sonnet` | Bounded judgment; escalate to `opus` only for genuinely novel architecture |
| Planning (`planning-and-task-breakdown`) | `sonnet` | Decomposition against a written spec |
| Implementation (`incremental-implementation`, inline batches) | `sonnet` | Standard code generation |
| Implementation — novel/tricky batch | `opus` | Concurrency, unfamiliar framework behavior, subtle invariants |
| Spec-drift detection | `sonnet` | Structured comparison |
| Research (`research-context`) | `sonnet` | Synthesis of external sources into a cited brief |
| Pre-commit review | `sonnet` | Fast, bounded scope |
| Compliance review (agent) | `opus` | Security, financial state, audit trails — highest stakes |
| Security & hardening | `opus` | Security decisions cannot be shallow |
| Architecture review (agent) | `sonnet` | Pattern-matching against known rules |
| Test review (agent) | `sonnet` | Assertion quality, coverage gaps |
| Silent-failure-hunter (agent) | `sonnet` | Pattern hunt for swallowed errors |
| Plan-gap / context-miner (agents) | `sonnet` | Structured cross-checks |
| Brainstorming | `opus` | Creative exploration benefits from deeper reasoning |

## How `subagent-implementation` applies this

When the subagent path dispatches per-batch implementers, the default is `sonnet`.
Choose `opus` for a batch only when the plan flags it novel/tricky (concurrency,
unfamiliar SDK, subtle invariants) per the "novel/tricky batch" row above.

## Override

These are defaults, not handcuffs. An engineer may run any phase on a higher tier;
the policy exists to stop the *reflex* of running everything on the top tier.
