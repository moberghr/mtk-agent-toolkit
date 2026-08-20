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

> **Tool discipline (phase-locked):** spec authoring is a read + spec-artifact phase. Write **only** the spec artifacts (`docs/specs/<date>-<slug>.md` and its `.json` sidecar) — never source or test code. Code starts at Phase 3, after the approval gate; a source edit here is a scope violation. (Not toolset-locked to `read-only` because it must write its spec files.)

> **Supplied spec/plan (adoption, not authoring):** when the engineer hands in a complete spec or plan as the input (e.g. `docs/specs/…md` or `docs/plans/…md` already on disk), `implement`'s Phase 0.7 *adopts* it as the source of truth. In that case this skill validates the supplied artifact against the schema and reconciles it against the current code (see `prior-work-check`'s existing-plan reconciliation) rather than re-authoring to a fresh path — never overwrite or version-bump the engineer's input. See `implement/SKILL.md` Phase 0.7.

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
   - Relevant lessons via `bash "$([ -n "${MTK_HELPER_ROOT:-}" ] && echo "$MTK_HELPER_ROOT/scripts/learnings.sh" || ([ -f scripts/learnings.sh ] && echo scripts/learnings.sh || echo "${CLAUDE_PLUGIN_ROOT:-.}/scripts/learnings.sh"))" query --phase spec --files "<comma-separated paths from initial scope>" --max 8` (resolves a pinned `MTK_HELPER_ROOT` checkout first, else the project copy, else the plugin copy; 5-layer retrieval: proximity / recurrence / severity / validity / phase). Falls back to reading `tasks/lessons.md` directly if the script is absent from all three (older repos).
2. Resolve the lessons path using the main worktree when in a worktree.
3. Surface assumptions before planning. State what you believe about runtime, architecture, storage, auth, and boundaries. Do not silently fill in major gaps.
4. Classify scope:
   - `internal-refactoring`
   - `new-feature`
   - `breaking-change`
4b. **Dirty-worktree step.** Run `git status --porcelain` and collect any modified or untracked paths. For each path that is NOT listed in the current scope's change manifest, record it under **Risks** as a `dirty-worktree` entry and add it to `out_of_scope` in the JSON sidecar. This surfaces unrelated in-flight work before the plan is locked so the `plan-gap-reviewer` can reject any batch that touches those paths.
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
   - **Resolve the artifact root first:** `bash scripts/resolve-artifact-root.sh "<a path the change touches>"`. Every `docs/specs/...` path below is relative to **that** root, not automatically the repo root. In a polyglot repo a subtree that owns its artifacts (its own `docs/specs/` plus a `CLAUDE.md`) keeps them — writing to the repo root instead would scatter one project's specs across two locations. A repo with no such subtree resolves to the repo root, so single-project repos are unaffected.
   - Create `docs/specs/` under the resolved root if it does not exist.
   - Compute the base target: `<artifact-root>/docs/specs/YYYY-MM-DD-<feature-slug>` (no extension yet).
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
   - Ignore working deltas only: add `docs/specs/*` to `.gitignore` with the
     negations `!docs/specs/baseline/` and `!docs/specs/baseline/**` so the
     baseline stays tracked. Per-feature delta specs are working artifacts;
     the baseline (`docs/specs/baseline/`) and its audit trail are committed
     (see `.claude/references/delta-spec-model.md`).
9.5. **EARS + ANT lint.** Run `bash scripts/lint-ears.sh docs/specs/<file>.md` on the just-persisted spec. Zero violations required before handing to the approval gate. If the script is absent (older repos), at minimum eyeball the Requirements section against the rules in `## Requirements Format (EARS)`.
9.6. **Publish the spec artifact (additive, capability-gated).** After the spec is on disk, follow `.claude/references/artifact-publishing.md` to create the workflow's Claude Artifact from the spec — this is the first section of a single browsable URL that later phases (plan, handoff, health) update in place. Publishing is additive: disk is the source of truth and the step is a silent no-op when the `Artifact` tool is unavailable or `MTK_ARTIFACT_PUBLISH=0`. Never publish anything not already written to disk.
10. Always stop for approval before implementation. When invoked from the implement workflow, this means handing control back to Phase 2.5 approval gate (which uses `AskUserQuestion`). Do not silently continue to implementation.

**Approval is sealed, not asserted.** On approval, the implement gate records a SHA-256 **approval seal** over the approved spec/plan bodies — the two scope-encoding artifacts (`scripts/workflow-artifact.sh seal`). The todo is deliberately *not* sealed: it is progress state designed to mutate as batches complete, so sealing it would flip the seal STALE on the first checkbox tick. Because the seal binds the exact approved bytes, editing an approved spec or plan afterward invalidates the approval deterministically — `verification-before-completion` re-checks it with `verify-seal` (refusing completion on a STALE seal) and the `spec-approval-trigger.sh` hook re-queues the gate, rather than trusting a stale `status: approved` marker. This is why moving a success-criterion goalpost post-approval requires re-opening Phase 2.5: the seal will not match.

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
    { "path": "src/X.cs", "action": "create | modify | delete", "purpose": "one-line why", "mechanical": false }
  ],
  "public_contracts": [
    { "kind": "endpoint | handler | method | event | cli-flag",
      "signature": "POST /api/orders or Namespace.Class.Method(...) or OrderCreated event",
      "change": "new | modified | removed",
      "surface": "external | internal-tooling" }
  ],
  "success_criteria": [
    {
      "id": "SC1",
      "description": "testable outcome",
      "verification": "name of test or command",
      "evidence_channel": "test-run | build-output | http-probe | cli-stdout | db-state-diff | browser | smoke-boot | log-capture | script-output",
      "observable": "one-line binary pass/fail statement (e.g. 'exit 0 with N/N tests passed')"
    }
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
- `mechanical` is an OPTIONAL per-entry boolean (default `false`). An entry is
  **mechanical** only when it changes no logic and no public contract —
  rename-only, formatting-only, or otherwise no-behavioral-change (cf. the TDD
  `skip_when` categories `rename-only|formatting-only|no-behavioral-change`); an
  entry touching any public contract — including a serialized shape, persisted
  schema, or wire format — is never mechanical. Mechanical entries are still
  implemented and verified, but they don't count toward the `implement` rigor
  floor or size score (see `implement/SKILL.md` Rigor Score).
- `public_contracts` is what callers or external consumers will see change.
  Internal helpers don't count. Tag each entry's `surface`: **`external`**
  (the default when absent) for a wire/API/published-library surface a caller
  or external consumer depends on; **`internal-tooling`** for a repo-internal
  build/IaC/CLI knob (CDK config props, an internal CLI flag, a build-script
  option) with no external consumer. The distinction is not cosmetic — the
  implement Rigor Score weights them differently, so an internal CLI flag does
  not inflate ceremony the way a new public endpoint does. When genuinely
  unsure, default to `external` (the safer, higher-ceremony choice).
- `security_impact` is NOT `none` if the diff touches auth, payments,
  audit trails, secrets, PII paths, or IAM configuration. Be honest here;
  `spec-drift-detection` will catch understated impact and block.
- Keep the JSON in sync with the markdown spec. They are one artifact in
  two shapes, not independent documents.
- Every `success_criteria[]` entry must carry `evidence_channel` (from the
  fixed taxonomy: `test-run`, `build-output`, `http-probe`, `cli-stdout`,
  `db-state-diff`, `browser`, `smoke-boot`, `log-capture`, `script-output`) and `observable`
  (a binary pass/fail observation declared before execution). Both fields are
  the verification contract that `verification-before-completion` checks
  criterion-by-criterion. **Each `observable` is a binary yes/no statement** —
  not a prose aspiration. Once Phase 2.5 approves the spec, the
  `success_criteria[]` definitions are **frozen**: their `id`, `observable`, and
  `evidence_channel` are read-only for the rest of the run. Moving a goalpost to
  make a criterion pass requires re-opening Phase 2.5, never an in-flight edit —
  `verification-before-completion` runs a tamper check before accepting any
  completion claim.

**Provenance tags.** Claims in the `assumptions` and `risks` arrays use tags
from the `verify-claims.sh` family:

| Tag | Meaning |
|---|---|
| `[VERIFIED:path]` | Claim checked against a local file at `path` |
| `[ASSUMED]` | Claim not verified against a local file or cited source — counts as an open decision; `MTK_AUTO_PROCEED` does not skip the gate while any `[ASSUMED]` claim is present |
| `[CITED:url]` | Claim supported by an external URL |
| `[COVERAGE:n]` | A **coverage claim**, verified against `n` enumerated write sites (see below) |

**Coverage claims.** A sentence like "this hook covers both the manual and the
generated path with no extra code" reads as design description, so it attracts
neither `[VERIFIED]` nor `[ASSUMED]` — and it is the most expensive kind of
claim a spec can get wrong, because a whole slice can pass every test while
notifying nobody. It is also the cheapest to check: it is a claim about **write
paths**, and a grep settles it.

Whenever the spec asserts that one call site, hook, event, or handler covers
more than one caller, enumerate the callers **before** the batch that depends on
the claim:

1. Grep for every site that writes the entity or raises the event — the entity
   name against `.Add(`, `AddAsync`, `Attach`, `Update`, direct context/store
   writes, and the event or command type against its dispatch call.
2. List each site as `file:line` in the sidecar:
   `coverage_claims: [{"claim":"TaskAssigned covers manual and generated tasks","write_sites":["Handlers/CreateEmployeeTask.cs:42","Jobs/LifecycleGenerator.cs:88"],"verified":true}]`
3. If any site does not route through the claimed point, the claim is **false** —
   amend the spec and the manifest before sealing, not after.

Tag the claim `[COVERAGE:n]` once the sites are enumerated. An unenumerated
coverage claim is an `[ASSUMED]` claim: it counts as an open decision and
`MTK_AUTO_PROCEED` does not skip the gate while one is present. In a codebase
where a handler and a background job both write the same entity, assume there is
**no** shared point until a grep shows one.

**Conditional descopes (pre-authorised reductions).** A spec may authorise its
own reduction up front — "drop the public-holiday nuance if it costs a query per
report", "move this event to a follow-up if its write site turns out to be more
than one handler". This is good spec writing: it decides the trade-off while the
author is thinking about it, instead of leaving the implementer to improvise
under pressure. But as prose it is invisible to the gate logic and to the final
report, so record it as a field:

```json
"conditional_descopes": [
  {"condition": "AssetApprovalPending has more than one write site",
   "action": "defer the event to a follow-up spec",
   "fired": true,
   "evidence": "four handlers write it — Handlers/Asset*.cs"}
]
```

A descope that fires is a **scope reduction**: it re-scores rigor (see
`implement/SKILL.md` Rigor Score → *Recompute on scope reduction*) and does not
re-open the approval gate, because shipping less of an approved scope needs no
new approval. Flip `fired` and fill `evidence` at the moment it fires, so
Phase 3.5 reads a record rather than a narration — an unevidenced `fired: true`
is silent drift wearing a spec's authority.

**Rejected alternatives (trap-register carry-over).** After the elegance check
(step 8), record any option that was considered and ruled out under a
`## Rejected alternatives` section (or in the `risks` array with a `trap:` prefix).
Brainstorming's divergence mode populates this register; it must travel with the spec
so `plan-gap-reviewer` and downstream reviewers see why the obvious answer was
discarded.

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
- [ ] A Constitution Check section is present in the spec
- [ ] Claude-Ready +C score > 13/16 recorded (step 8b)
- [ ] `prior-work-check` ran with no BLOCK verdict (step 8c)
- [ ] Spec artifact published (or gate correctly closed) per `.claude/references/artifact-publishing.md` — disk written first regardless (step 9.6)
