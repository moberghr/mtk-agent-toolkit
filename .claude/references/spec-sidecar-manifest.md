---
description: The spec's JSON sidecar (docs/specs/<date>-<slug>.json) in full — every field with its allowed values, the ambiguity gate, coverage claims, conditional descopes, and the downstream sections plan/implement append; read by spec-driven-development when authoring or amending a sidecar
globs: ["docs/specs/**"]
alwaysApply: false
---
# Spec Sidecar — Machine-Parseable Manifest

`spec-driven-development` writes this file beside every spec and validates it against
`.claude/schemas/handoff.schema.json`. The skill keeps the decision (when a sidecar is
written, what blocks approval); this reference holds the field-by-field detail.

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
