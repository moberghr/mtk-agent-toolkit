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

## Provider tier slots

The policy table names concrete Claude tiers (`haiku`/`sonnet`/`opus`) because that is what MTK runs on today. But model IDs churn — a tier gets renamed, a new generation ships, or a team routes MTK through a different provider. Pin policy to **role slots**, not model names, so configs survive a rename:

| Slot | Meaning | Current Claude binding |
|---|---|---|
| `fast` | Cheapest tier — discovery, grep, structured collection, no judgment | `haiku` |
| `default` | Workhorse — bounded judgment, standard code generation, most reviews | `sonnet` |
| `strong` | Highest capability — real logic, adversarial/security review, novel batches | `opus` |

The slot is the stable contract; the binding is one line to update when models change. Read the policy table as *roles*: "discovery → `fast`", "implementation → `default`", "compliance review / security → `strong`". When MTK runs on a non-Anthropic backend (or a future Claude generation), re-bind the three slots in this table once and every phase/agent rule follows — no per-row edits, no agent-frontmatter churn beyond swapping the slot's bound model. Frontmatter `model:` may name either the slot's current concrete model or, where the harness supports it, the slot name itself.

## How `subagent-implementation` applies this

When the subagent path dispatches per-batch implementers, the default is `sonnet`.
Choose `opus` for a batch only when the plan flags it novel/tricky (concurrency,
unfamiliar SDK, subtle invariants) per the "novel/tricky batch" row above.

**Interactive vs autonomous.** In *interactive* mode the orchestrator confirms
this default once via `AskUserQuestion` before the loop. In *autonomous* mode
(Phase 2.5 → `Approve & run until done`) it does **not** ask — the `sonnet`
default applies silently, with `opus` reserved for plan-flagged novel/tricky
batches. This is the resolution of the apparent conflict between
subagent-implementation's "ask once" rule and autonomous mode's "never ask in
Phases 3-7": the ask is interactive-only, so autonomous mode simply skips it.

## Override

These are defaults, not handcuffs. An engineer may run any phase on a higher tier;
the policy exists to stop the *reflex* of running everything on the top tier.
