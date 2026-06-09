---
name: spec-driven-development
description: Use when the task is a new feature, breaking change, multi-file change, or any work where approval should happen before coding begins.
type: skill
license: MIT
compatibility:
  - claude-code
  - codex
trigger: new-feature|breaking-change|multi-file-change|approval-required
skip_when: typo-fix|config-update|single-line-change
user-invocable: false
---

# Spec-Driven Development

## Overview

Write the implementation spec before writing code. The spec is the shared source of truth between the engineer, the command flow, and the reviewers. Code without a spec is guessing.

## When To Use

- New endpoints, handlers, routes, or views
- Database changes or migrations
- Multi-file work
- Breaking changes
- Any task where approval should happen before coding
- Any task likely to take more than a short focused session

### When NOT To Use

- Typo fixes
- One-line config updates with no behavior impact
- Small bug fixes that clearly stay within quick-fix scope

## Workflow

### Decision Graph

This graph drives the two questions models get wrong most often: *"do I need a spec at all?"* and *"can I start coding after writing one?"* The red node is the hard stop — implementation never begins inside this skill.

```dot
digraph spec_flow {
  rankdir=TB;
  node [shape=box, style=rounded, fontname="Helvetica"];
  edge [fontname="Helvetica", fontsize=10];

  start    [label="task arrived"];
  trivial  [label="typo / 1-line config /\nclear quick fix?", shape=diamond];
  skip     [label="skip spec\n(use fix workflow)", style="rounded,filled", fillcolor="#e0f0e0"];
  multi    [label="multi-file OR new endpoint /\nhandler / migration OR\nbreaking change?", shape=diamond];
  long     [label="longer than a short\nfocused session?", shape=diamond];

  load     [label="load standards:\nCLAUDE.md, coding guidelines,\nsecurity, testing, architecture,\nrelevant lessons"];
  assume   [label="surface assumptions\n(runtime, arch, storage,\nauth, boundaries)"];
  classify [label="classify scope:\ninternal-refactoring /\nnew-feature / breaking-change"];
  pattern  [label="read 2-3 nearby files\nfor local pattern"];
  ambig    [label="ambiguity present?\n(≥2 plausible designs OR\nundefined scope edge OR\nunresolved arch choice)", shape=diamond];
  ask      [label="ask via AskUserQuestion\nBEFORE drafting\n(batched ≤2 / interview ≥3)"];
  draft    [label="draft spec sections:\nsummary · success criteria ·\narch · security impact ·\nchange manifest · test manifest ·\nbatches · risks · open Qs"];
  elegance [label="elegance check:\nfewer files? fewer\nabstractions? fewer\nmoving parts?"];
  sec      [label="security_impact\nhonest?", shape=diamond];
  fixsec   [label="upgrade security_impact\n(spec-drift will catch lies)",
            style="rounded,filled", fillcolor="#fff8d0"];
  persist  [label="write to disk:\ndocs/specs/<date>-<slug>.md\n+ <date>-<slug>.json sidecar\n(version-suffix if exists)"];
  approve  [label="STOP — hand to approval gate.\nDo NOT implement.\nDo NOT merge into batch 1.",
            style="rounded,filled", fillcolor="#ff9090"];

  start -> trivial;
  trivial -> skip  [label="yes"];
  trivial -> multi [label="no"];
  multi   -> load  [label="yes"];
  multi   -> long  [label="no"];
  long    -> load  [label="yes"];
  long    -> skip  [label="no"];

  load -> assume -> classify -> pattern -> ambig;
  ambig -> ask   [label="yes"];
  ambig -> draft [label="no"];
  ask   -> draft;
  draft -> elegance -> sec;
  sec  -> fixsec  [label="no — auth/payments/\naudit/secrets/PII/IAM\nbut marked 'none'"];
  fixsec -> persist;
  sec  -> persist [label="yes"];
  persist -> approve;
}
```

**Red flags inside the loop:**

| Rationalization | Reality |
|---|---|
| "I'll write the spec after I implement it" | That's documentation, not specification. The value is deciding *before* coding. |
| "Small enough to skip approval" | Multi-file work creates risk regardless of size. The gate catches bad direction early. |
| "I already know which files will change" | You have a hypothesis. Read neighboring files; prove the manifest. |
| "security_impact is `none`, it's just a small change" | If the diff touches auth / payments / audit trails / secrets / PII / IAM, it isn't `none`. spec-drift-detection blocks. |
| "I'll start batch 1 while waiting for approval" | No. The approval gate is the hard stop. |

### Steps

1. Read standards in this order:
   - `CLAUDE.md`
   - The coding guidelines from the active tech stack skill's `## Reference Files`
   - `.claude/references/security-checklist.md`
   - `.claude/references/testing-patterns.md`
   - `.claude/references/architecture-principles.md` if present
   - Relevant lessons via `bash scripts/learnings.sh query --phase spec --files "<comma-separated paths from initial scope>" --max 8` (5-layer retrieval: proximity / recurrence / severity / validity / phase). Falls back to reading `tasks/lessons.md` directly if `scripts/learnings.sh` is absent (older repos).
2. Resolve the lessons path using the main worktree when in a worktree.
3. Surface assumptions before planning. State what you believe about runtime, architecture, storage, auth, and boundaries. Do not silently fill in major gaps.
4. Classify scope:
   - `internal-refactoring`
   - `new-feature`
   - `breaking-change`
5. Read 2-3 nearby files that represent the local pattern to follow.
6. **Ambiguity gate (BEFORE drafting).** Detect whether the task has genuine ambiguity that would change the spec. Trigger if **any** of:
   - Two or more plausible designs exist and the request doesn't pick one (e.g., reflection vs source-gen, sync vs async, single vs split package).
   - Scope edges are undefined (e.g., "users" — authenticated only? including service accounts? soft-deleted?).
   - An architectural choice is unresolved (e.g., new boundary, new persistence target, cross-slice contract).
   - A success criterion would be untestable as stated.

   If triggered: stop and call `AskUserQuestion` with one question per ambiguity (max 4). Each question presents 2–4 concrete options with the tradeoff in the description. Wait for answers, then proceed to drafting with answers folded into the spec — do NOT defer them to "Open questions" in the spec body.

   **Interview mode (Socratic, one question per round).** Switch from the batched form above to a structured interview when **either**: three or more ambiguities triggered, or the request is one or two sentences for clearly multi-file scope (the ask is underspecified relative to its blast radius). In interview mode:

   - Ask **one** question per `AskUserQuestion` round, starting with the highest-leverage ambiguity — the one whose answer most reshapes the spec (usually the success definition or the architectural boundary, not the naming choice).
   - Probe **intent**, not just option preference: lead with what the engineer is trying to achieve or avoid ("what should happen to in-flight payments when this flag flips?"), then offer the 2–4 concrete options informed by that framing.
   - After each answer, **re-derive the remaining ambiguities** before asking the next question — answers routinely resolve later questions or surface new ones; a pre-computed question list goes stale after round one.
   - Cap at **5 rounds**. Anything still open after the cap is written into the spec as an explicit assumption with the chosen default and its rationale — never as a silent guess.

   Batched mode remains the default for one or two independent ambiguities — don't stretch a two-question gate into an interview.

   If `AskUserQuestion` is deferred, load it via `ToolSearch` with `select:AskUserQuestion`. If the harness doesn't expose it, print the questions as a numbered list and stop until the engineer answers.

   Skip the gate when: the engineer's request already specifies the approach, the task follows an obvious existing pattern, or only one viable design fits the constraints. Document the skip in one line ("ambiguity gate skipped: <reason>") so it's visible in the session log.

   **When an ambiguity is version-sensitive** — the right answer depends on current external best-practice, the installed package version's behavior, or a recent migration path rather than a preference — first follow `.claude/skills/research-context/SKILL.md` to produce a grounded, cited brief, then fold its recommendation into the options you present at the `AskUserQuestion` gate. Resolve "which design" from current information, not training-cutoff memory.
7. Produce a spec with these sections:
   - Summary
   - Success criteria
   - Architecture and design
   - Security and compliance impact
   - Change manifest
   - Test manifest
   - Implementation batches
   - Risks and assumptions
   - Open questions
   - **Requirements** — every requirement-bearing bullet uses EARS notation (see `## Requirements Format (EARS)` below). Run the ANT self-check before continuing.
8. Run an elegance check: reduce file count, new abstractions, and moving parts if a simpler design exists.
8a. **EARS + ANT lint.** Run `bash scripts/lint-ears.sh docs/specs/<file>.md` after persisting the spec (step 9). Zero violations required before handing to the approval gate. If the script is absent (older repos), at minimum eyeball the Requirements section against the rules in `## Requirements Format (EARS)`.
8b. **Claude-Ready (INVEST+C) check.** Score the draft against
   `.claude/references/claude-ready-checklist.md`. The +C section is hard —
   any failing item among +C #1..#16 must be fixed before the spec leaves
   this skill. Specs scoring ≤13/16 are sent back to draft (no approval).
   Cite failing item numbers in the lint output so the engineer can see
   exactly what to tighten. The classic INVEST half is a soft check —
   surface failures, do not block on them.
8c. **Prior-work check.** Invoke the `prior-work-check` skill against the
   draft (see `.claude/skills/prior-work-check/SKILL.md`). Three deterministic
   queries run: `search_prior_work`, `get_constraints`, `get_risk_profile`.
   Any BLOCK finding (existing implementation, EXTRACTED contradiction,
   mis-classified `security_impact`) holds the approval gate — the spec
   must be revised. FLAG findings are surfaced to the engineer for explicit
   acknowledgement. Output is appended under a `## Prior Work Check` section
   in the spec markdown so reviewers can see what was checked.
9. Persist the spec to disk:
   - Create `docs/specs/` if it does not exist.
   - Compute the base target: `docs/specs/YYYY-MM-DD-<feature-slug>` (no extension yet).
   - **Version detection:** Check whether `docs/specs/YYYY-MM-DD-<feature-slug>.md` already exists.
     - If it does NOT exist → write to `docs/specs/YYYY-MM-DD-<feature-slug>.md` (no suffix).
     - If it DOES exist → find the highest existing `-vN` suffix:
       ```bash
       ls docs/specs/YYYY-MM-DD-<slug>*.md 2>/dev/null | grep -oE '\-v[0-9]+' | sort -V | tail -1
       ```
       If a `-vN` suffix is found, write as `-v(N+1)`. If the file exists but no `-vN` variants do, write as `-v2`.
     - The JSON sidecar gets the **same version suffix** (e.g., `docs/specs/YYYY-MM-DD-<slug>-v2.json`).
     - Emit one line before writing: `Writing spec → docs/specs/<final-filename>.md` so the engineer can confirm the version chosen.
   - **Also emit a machine-parseable sidecar** at `docs/specs/<final-filename>.json` with the schema in the next section. This sidecar drives `spec-drift-detection` after implementation.
   - This enables session recovery, human review outside chat, and reuse across sessions.
   - Add `docs/specs/` to `.gitignore` if not already present — specs are working artifacts, not committed deliverables.
10. Always stop for approval before implementation. When invoked from the implement workflow, this means handing control back to Phase 2.5 approval gate (which uses `AskUserQuestion`). Do not silently continue to implementation.

## Requirements Format (EARS)

Every requirement-bearing bullet in the spec's `## Requirements` section uses **EARS** (Easy Approach to Requirements Syntax). EARS makes requirements testable by forcing a predicate-with-trigger shape; flowery prose has nowhere to hide.


### The five templates

| Variant | Template | Example |
|---|---|---|
| **Ubiquitous** (always) | The system **shall** \<response\>. | The system shall persist every audit event for at least 7 years. |
| **Event-driven** | **When** \<trigger\>, the system **shall** \<response\>. | When a payment fails three times, the system shall lock the account. |
| **State-driven** | **While** \<state\>, the system **shall** \<response\>. | While a migration is running, the system shall reject new write requests. |
| **Optional** | **Where** \<feature\>, the system **may** \<response\>. | Where multi-factor auth is enabled, the system may skip the SMS step. |
| **Unwanted** | **If** \<trigger\>, **then** the system **shall** \<response\>. | If the request lacks a tenant ID, then the system shall reject it with HTTP 400. |

### ANT (Anti-Null-Tautology) check

A requirement that **cannot be falsified** carries no information. After drafting Requirements, walk each bullet and ask: *what would a counter-example look like?* If you cannot describe one, the bullet fails the ANT test and must be rewritten or dropped.

Common ANT failures (auto-flagged by `lint-ears.sh`):

- "The system shall be reliable / performant / scalable / secure / robust / clean."
- "The code shall follow best practices."
- "The system shall handle errors gracefully."
- "Where appropriate" / "as needed" / "if necessary" with no concrete trigger.

The lint scopes only to the `## Requirements` section (and its EARS subsections); narrative sections (Summary, Risks, Goals) are not checked.

### Subsection layout (recommended)

```markdown
## Requirements

### Ubiquitous
- The system shall ...

### Event-driven
- When X, the system shall ...

### State-driven
- While Y, the system shall ...

### Optional
- Where Z, the system may ...

### Unwanted behaviours
- If W, then the system shall ...
```

## Constitution Check (Cited, Not Ambient)

The project's governing rules are an **explicit cited input** to the spec, not
background context the reader is assumed to know.

1. Run `bash scripts/constitution-digest.sh` to get the authoritative set —
   Critical Rules (`C0.x` from CLAUDE.md) plus tagged architecture principles
   (`[EXTRACTED]` / `[INFERRED:x]` / `[AMBIGUOUS]`), if present.
2. Add a **Constitution Check** section to the markdown spec listing every rule
   or principle that *constrains this design*, each with one line on how the
   design satisfies it. Cite by id (e.g. `C0.2`, `S1.15`, a principle id).
3. If the design appears to violate or bend a rule, surface it here as an
   explicit exception with rationale — do not bury it. `[EXTRACTED]` principle
   violations should normally send you back to redesign, not into an exception.

This closes the loop with `spec-drift-detection` (S1.15): what you cite at spec
time is what the drift check verifies at ship time. An empty Constitution Check
is allowed only with a one-line "no Critical Rules or principles constrain this
change" note — rare for multi-file work.

## Machine-Parseable Manifest (JSON Sidecar)

Every spec is accompanied by a structured manifest at
`docs/specs/<date>-<slug>.json`, validated against
`.claude/schemas/handoff.schema.json`. This is the source of truth for
drift detection and for the `plan` and `implement` sections appended
later by downstream skills (MetaGPT typed-handoff pattern).

```json
{
  "slug": "feature-slug",
  "date": "YYYY-MM-DD",
  "scope": "new-feature | internal-refactoring | breaking-change",
  "change_manifest": [
    { "path": "src/X.cs", "action": "create | modify | delete", "purpose": "one-line why" }
  ],
  "public_contracts": [
    { "kind": "endpoint | handler | method | event | cli-flag",
      "signature": "POST /api/orders or Namespace.Class.Method(...) or OrderCreated event",
      "change": "new | modified | removed" }
  ],
  "success_criteria": [
    { "id": "SC1", "description": "testable outcome", "verification": "name of test or command" }
  ],
  "test_manifest": [
    { "path": "tests/X_Tests.cs", "covers": ["SC1", "SC2"] }
  ],
  "out_of_scope": ["explicit non-goals"],
  "security_impact": "none | requires-audit-trail | new-auth-path | secrets-change | pii-exposure | iam-change",
  "baseline_area": "slice/subsystem this delta belongs to (e.g. payments) — see Delta & Baseline",
  "delta": { "adds": [], "modifies": [], "removes": ["explicit baseline removals only"] },
  "assumptions": ["..."],
  "risks": ["..."]
}
```

Rules:

- Every entry in `change_manifest` must be intended — do not pre-populate
  with files you "might" touch.
- `public_contracts` is what callers or external consumers will see change.
  Internal helpers don't count.
- `security_impact` is NOT `none` if the diff touches auth, payments,
  audit trails, secrets, PII paths, or IAM configuration. Be honest here;
  `spec-drift-detection` will catch understated impact and block.
- Keep the JSON in sync with the markdown spec. They are one artifact in
  two shapes, not independent documents.

## Delta & Baseline

Specs are **deltas against a living per-area baseline**.
See `.claude/references/delta-spec-model.md` for the full model.

- Set `baseline_area` in the sidecar to the slice/subsystem this change belongs
  to (e.g. `payments`, `auth`, `toolkit-workflow`). This is what makes the spec
  archivable into a baseline.
- Optionally declare `delta.adds` / `delta.modifies` / `delta.removes` relative
  to the current baseline. If omitted, the whole `change_manifest` and
  `public_contracts` are folded into the baseline on archive; **removals must be
  explicit** in `delta.removes` (archiving never infers deletion).
- The baseline is synced back only at archive time (implement Phase 7.5), and
  only after a clean drift PASS — never hand-edited. The accumulated baseline
  lives at `docs/specs/baseline/<area>.{json,md}` with an audit trail at
  `docs/specs/baseline/<area>.audit.jsonl`.

## Required Outputs

- A clear scope classification
- A file-level change manifest covering every file to be touched
- A test manifest covering every behavioral change
- A batch breakdown with build/test checkpoints
- A list of assumptions and unresolved risks
- Concrete, testable success criteria
- A **Constitution Check** section citing the Critical Rules / principles that
  constrain the design (from `scripts/constitution-digest.sh`)
- A JSON sidecar manifest at `docs/specs/<date>-<slug>.json` matching the
  Machine-Parseable Manifest schema (drives drift detection)

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` for the shared table. Spec-specific traps: "I'll write the spec after I implement it" (that is documentation, not specification — the value is in deciding before coding), "this is small enough to skip approval" (small multi-file work still creates risk — approval gates catch bad direction early), and "I already know which files will change" (you have a hypothesis, not a manifest — read neighboring files and prove it).

## Red Flags

- Planning after code has already started
- Files likely to be touched but omitted from the change manifest
- Missing tests for new public behavior
- Approval gate skipped or merged into implementation
- Success criteria written as vague aspirations instead of verifiable outcomes

## Verification

- [ ] The plan can be handed to another engineer with no missing context
- [ ] Every file and every test file appears in the manifest
- [ ] Success criteria are specific and testable
- [ ] Assumptions are explicit
- [ ] The scope still matches the original request
- [ ] The JSON sidecar exists at `docs/specs/<date>-<slug>.json` and matches
      the markdown spec's change_manifest, test_manifest, success_criteria,
      and security_impact
- [ ] `security_impact` honestly reflects touched trust boundaries (not `none`
      if auth / payments / audit / secrets / PII / IAM are involved)
- [ ] `bash scripts/lint-ears.sh <spec.md>` returns 0 (EARS + ANT clean)
