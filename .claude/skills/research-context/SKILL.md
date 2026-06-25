---
name: research-context
description: Use when a decision needs current external/web information (library best-practices, version-specific behavior, migration guidance) rather than local source verification — runs web research grounded in named project files and returns a cited brief, deferring to /deep-research for heavy questions.
type: skill
license: MIT
compatibility:
  - claude-code
trigger: research-needed|current-best-practice|version-sensitive-decision|external-info-grounding
skip_when: behavior-verifiable-from-local-repo|well-understood-stable-api|no-external-uncertainty
triggers:
  - best-practice
  - best-practices
  - latest-version
  - upgrade-guide
  - migration-guide
user-invocable: false
---

# Research Context

## Overview

`source-driven-development` answers "does this *known* API behave the way I think?" by checking authoritative docs for one call. `research-context` answers the broader, forward-looking question: "given what this repo already does, what is the *current* best way to do X?" — pulling fresh external information (release notes, current best-practices, migration paths, security advisories) and **grounding it against named files in this repo** so the answer fits the codebase, not a generic tutorial.

It is the MTK analog of Taskmaster's research mode: research is a first-class workflow primitive, not an ad-hoc web search. Its output is a small, cited brief that downstream skills consume — `spec-driven-development` (version-sensitive ambiguity gate, step 6) and `implement` (Phase 3, version-sensitive choices) — so spec and implementation decisions ride on current information rather than training-cutoff memory.

This skill **does not edit code**. It produces a brief; another skill acts on it.

> **Tool discipline (phase-locked):** research is a read + web-fetch phase — use `Read`/`Grep`/`Glob` and the web tools only. Do **not** `Edit`/`Write` source or test code; the only artifact it may write is its own brief. (It is not locked to the `read-only` toolset because it legitimately needs `WebSearch`/`WebFetch`, which that toolset excludes.)
> **Model tier:** runs on `sonnet` (synthesis of external sources into a cited brief) per `.claude/references/model-routing.md`.

## When To Use

- A spec or plan hinges on a **version-sensitive** choice (which API/pattern is current in the installed package version, not the one from memory).
- Choosing between competing libraries/approaches where the landscape moved recently.
- A dependency upgrade or framework migration where the migration path matters.
- A security-sensitive decision where current advisories or deprecations could change the answer.
- The engineer literally asks to "research X" before building.

### When NOT To Use

- The behavior is verifiable from local repo patterns already in use → use `source-driven-development` (cheaper, no web).
- A single known-API contract question → `source-driven-development`.
- Stable, well-understood APIs with no version sensitivity → just implement.
- The question is about *this codebase's* internals → read the code; this skill is for *external* information.

## Workflow

### Step 1 — Frame the question against the repo (grounding is mandatory)

Before any web call, anchor the research in concrete project context. Identify and **name** the files that constrain the answer:

- The active tech stack (read `.claude/tech-stack`) and the relevant `tech-stack-<stack>/SKILL.md`.
- The **installed version** of the library in question — read it from the lockfile / project file (`*.csproj`, `Directory.Packages.props`, `requirements.txt`, `pyproject.toml`, `package.json`). A research answer for the wrong version is worse than no answer.
- 1–3 existing files that show how the repo uses the relevant area today.

Write the framed question as: *"For \<stack\> using \<library\>@\<installed-version\>, given that this repo currently does \<X in file:line\>, what is the current recommended way to \<goal\>?"*

If you cannot name the installed version or a grounding file, say so in the brief — an ungrounded brief is explicitly marked as such.

### Step 2 — Choose research depth

| Signal | Path |
|---|---|
| One focused question, 1–2 likely authoritative sources (e.g. "is `X` deprecated in v8?") | **Light path**: `WebSearch` + `WebFetch` directly (2–4 fetches), or `context7` MCP for library docs if available. |
| Multi-angle, contested, or high-stakes (architecture choice, security posture, "which of these 3 approaches") | **Deep path**: delegate to the built-in `/deep-research` workflow via the `Skill` tool, passing the framed question from Step 1. It fans out, cross-checks, votes per claim, and returns a cited report — do not re-implement that loop by hand. |

Prefer the light path. Escalate to `/deep-research` only when the question genuinely has multiple competing answers or the cost of being wrong is high (security, data integrity, a hard-to-reverse migration).

### Step 3 — Ground findings against the named files

For each finding, classify it the same way `source-driven-development` does, and make the classification visible:

- **verified-from-source** — backed by a fetched authoritative source (link it).
- **applies-to-this-repo** — confirmed compatible with the installed version and existing patterns named in Step 1.
- **conflicts-with-repo** — current best-practice diverges from what the repo does today (flag explicitly; this is a decision for the spec/plan, not a silent override).
- **still-uncertain** — could not confirm against an authoritative source or against the installed version.

### Step 4 — Emit the brief

Write a compact, cited brief (Markdown). Keep it short — it is consumed by another skill, not read for pleasure:

```
## Research brief: <framed question>

**Stack / version:** <stack> · <library>@<installed-version> (from <file>)
**Grounding files:** <file:line>, <file:line>

### Recommendation
<1–3 sentences: the current recommended approach for THIS version/repo>

### Findings
- [CITED:<url>] <claim> — confirmed against an external source
- [VERIFIED:<file:line>] <claim> — confirmed against this repo's code/config
- [ASSUMED] <claim> — could not confirm; stated as an assumption, NOT a fact

### Open decisions for the spec/plan
- <anything that needs an engineer or AskUserQuestion call downstream>

### Sources
- <url> — <one-line what it established>
```

**Provenance tags are mandatory on every claim.** Each finding carries exactly
one provenance tag so downstream skills can tell fact from guess:

- `[CITED:<url>]` — backed by a named external source.
- `[VERIFIED:<file:line>]` — confirmed against this repo (installed version,
  existing pattern, config value).
- `[ASSUMED]` — not confirmed. This is the load-bearing one: an `[ASSUMED]`
  claim that reaches a spec becomes an open decision that **blocks
  `MTK_AUTO_PROCEED`** at the `implement` Phase 2.5 gate (a human must confirm
  it). Never launder an `[ASSUMED]` claim into a bare assertion — if you could
  not confirm it, tag it, so the gate can catch it.

If invoked standalone (engineer said "research X"), present the brief and stop — do not start implementing. If invoked by `spec-driven-development` or `implement`, return the brief to that skill so its decisions and ambiguity gate consume it.

### Step 5 — Persist when part of a workflow

If a workflow artifact is active (`$MTK_WF_UUID` set), record the brief so it survives compaction:

```
scripts/workflow-artifact.sh event "$MTK_WF_UUID" research_brief --data '{"question":"...","recommendation":"...","conflicts":<n>}'
```

## Rules

- **Ground before you search.** No web call until the installed version and at least one repo grounding file are named (or their absence is recorded).
- **Cite or it didn't happen.** Every `verified-from-source` finding carries a fetched URL. Memory is not a source.
- **Version-match.** A finding for a different major/minor version than the one installed is `still-uncertain` until confirmed for the installed version.
- **Surface conflicts, never resolve them silently.** If current best-practice contradicts the repo, that is an open decision for the spec/plan — not something this skill changes.
- **Don't implement.** This skill produces a brief. Acting on it is another skill's job.
- **Escalate deep, not wide.** Use `/deep-research` for genuinely multi-angle questions; don't hand-roll a fan-out.

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` for the shared table. Research-context-specific traps:

| Rationalization | Reality |
|---|---|
| "I already know the best practice for this library" | Your memory has a training cutoff; the library shipped versions since. If the decision is version-sensitive, verify it for the installed version. |
| "I'll research the general approach, version doesn't matter" | Version is the whole point — a recommendation for v7 can be an anti-pattern in v9. Name the installed version first. |
| "Web result says X, so I'll just code X" | A blog from two years ago about a different version is not grounding. Classify the finding and check it against the installed version + repo patterns. |
| "Let me just implement while I research" | This skill produces a brief and stops. Implementing mid-research means acting on unverified findings. |
| "The repo does it differently, I'll quietly switch to the modern way" | A conflict between repo and current best-practice is a decision for the spec/plan, surfaced explicitly — not a silent rewrite. |
| "One quick web search is enough for this architecture call" | High-stakes, multi-answer questions go through `/deep-research` so claims get cross-checked and voted, not taken from a single page. |

## Red Flags

- A brief with `verified-from-source` findings that have no URLs.
- Findings stated without naming the installed library version.
- Research that never names a single file from this repo (ungrounded — generic tutorial output).
- The skill editing source files.
- A multi-angle architecture decision answered from a single web page instead of `/deep-research`.
- Conflicts between repo and best-practice silently resolved instead of surfaced.

## Verification

- [ ] The framed question names the active stack and the installed library version (or records that it could not be found)
- [ ] At least one repo grounding file is named (or absence is explicitly noted)
- [ ] Research depth (light vs `/deep-research`) was chosen deliberately per the Step 2 table
- [ ] Every `verified-from-source` finding carries a fetched source URL
- [ ] Findings are version-matched to the installed version, or marked `still-uncertain`
- [ ] Repo-vs-best-practice conflicts are surfaced as open decisions, not silently resolved
- [ ] The brief was returned to the calling skill (or presented and stopped, if standalone) — no code was edited
- [ ] If a workflow artifact is active, the brief was recorded as a `research_brief` event
