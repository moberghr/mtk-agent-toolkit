# MTK Improvements from a Client Three-Slice Field Run — 2026-08-20

**Source:** artifact `881ffb55` "MTK on Three Slices" — three specs (19 Aug) built as three
stacked branches in one session. 11 batches, 15 commits, 90 files, PRs #94 → #95 → #96.
Rigor MAX/MAX/HIGH. 6 real defects caught, 1 a PII leak.

**Method.** Every item below is checked against the toolkit as it stands on
`feat/borrow-r8-full-slate` — the "already covered / gap" line names the file I read.
Items are ordered by evidence strength, not by appeal.

---

## What earned keep (do not touch)

Listed first so the improvements below are not read as a verdict on the whole apparatus.

- **Rigor scaling dialed correctly.** 19 / 19 / 11 → MAX / MAX / HIGH. Slice 3 scored lower
  because the work was genuinely smaller (one endpoint, one contract), not because a
  threshold was gamed. The continuous score is doing its job.
- **Phase 2.9 collision gate caught a live parallel session** — a commit appeared from another
  session mid-setup; the gate turned it into a worktree decision instead of a collision.
- **Lessons paid on load.** Four existing entries governed the run (hand-written migrations,
  route-casing as wire contract, OpenAPI from a running API, checkpoints quote a runner).
- **TDD caught the PII leak.** Finding 01 — the test written in the same batch was right and
  the code was wrong.
- **The batch checkpoint caught the untranslatable query** — 12 tests red at once, before the
  batch could be reported complete.
- **The report's own honesty section is what made this analysis possible.** Section 05
  ("where the process was reduced, and said so") is the input to every P0 below.

---

## P0 — repeat offenders: the contract is wrong, not the run

### P0.1 Rigor MAX prescribes a path the environment forbids

**Evidence.** Phase 3 ran inline in all three slices; Stage 2's reviewer lanes were not forked
agents. Both recorded as ceremony reductions. The artifact notes *"the previous MTK run in this
repo had already recorded the same way"*, and `feedback_implement_dogfooding_wave1.md`
(2026-08-06) records the same thing a third time: *"rigor HIGH unreachable without subagents"*.

**Already covered.** `implement/SKILL.md:328-341` requires the reduction be recorded as
`ABSTAINED` with a reason — the run complied exactly, and `subagent-implementation/SKILL.md:52`
has a fallback for `Workflow` being unavailable.

**Gap.** There is no fallback for the `Agent` tool itself being unavailable or forbidden by a
standing instruction. So MAX rigor names a path that cannot run, the run correctly logs an
abstention, and Phase 4 is then *unreportable* under the very rule at line 332
("Phase 4 cannot be reported as passing while any lane is ABSTAINED"). Logging a reduction
three times is honest bookkeeping that never becomes a fix.

**Change.**
1. **Dispatch-capability pre-flight** in Phase 2.9: probe once whether subagent dispatch is
   actually available this session (`Workflow` exposed? `Agent` permitted? a standing
   instruction forbidding unrequested agents?) and record the verdict in the sidecar as
   `dispatch_capability: available | forbidden | unavailable`.
2. **A declared inline-MAX profile.** When dispatch is unavailable, MAX does not silently
   degrade — it selects a *named* path with named compensating controls for the context
   isolation it loses: per-batch re-read of the sealed manifest, reviewer lanes as sequential
   fresh-context passes carrying an explicit anti-anchoring instruction, and the existing
   orchestrator-side drift micro-check. Lane accounting then reports
   `ABSTAINED (by-policy: dispatch forbidden; compensations C1–C3 applied)` rather than an
   unexplained abstention that blocks Phase 4.
3. **`MTK_SUBAGENT_DISPATCH=0|1|auto`** so a repo like this one declares the constraint once
   instead of rediscovering it per run.
4. **Repeat-reduction escalation rule.** A ceremony reduction recorded for the same reason
   twice in the same repo stops being a log line and becomes a proposal — surface it at Phase 7
   as a config or contract change, not another identical entry.

**Files.** `.claude/skills/implement/SKILL.md` (Phase 2.9, Rigor Score, Lane Accounting),
`.claude/skills/subagent-implementation/SKILL.md`, `CLAUDE.md` env table.

### P0.2 No baseline capture before batch 1

**Evidence.** Three `export-csv` e2e tests fail on that machine. Proving them pre-existing cost
a throwaway worktree checked out at base commit `0f655d8` — archaeology, after the fact. The
"+60 / +21 / +13 tests" figures in section 01 were reconstructed by hand.

**Already covered.** Phase 2.9 is a *file*-collision gate (`implement/SKILL.md` Phase 2.9);
`verification-before-completion` demands fresh execution evidence for each claim.

**Gap.** Nothing captures the suite's state *before* the first edit. `grep -ril 'red baseline'`
across skills/hooks/scripts returns only `using-git-worktrees`, `mtk-doctor` and
`writing-skills` — none of them a pre-flight.

**Change.** Extend Phase 2.9 from "collision gate" to "pre-flight": run build + test +
typecheck at the base commit and store the result in the sidecar as
`baseline: {build, tests: "702/702", e2e: "160 passed / 3 failed (export-csv…)"}`. Then every
later checkpoint compares to baseline, a pre-existing failure is a known quantity at minute
zero rather than a suspicion at hour six, and the delta figures in the final report become
machine-derived instead of hand-counted.

**Cost note.** A full baseline is not free. Gate it on rigor ≥ HIGH, and let it reuse an
existing green checkpoint from the same base commit if one is already in the workflow artifact.

---

## P1 — new gaps this run proved

### P1.1 Manifest-path pre-flight: validate destinations *and their conventions* before sealing

**Evidence.** Section 04 — three manifest paths described a repository that does not exist:
a `Configurations/` directory (and not one `IEntityTypeConfiguration` in the whole solution —
every entity is configured inline in `OnModelCreating`), `components/app-sidebar.tsx` (the nav
lives in `components/shell/nav-items.ts`), and an unprefixed migration filename (migrations are
timestamp-prefixed, newest ships a Designer file). Downstream: 12 drift corrections across
three Phase 3.5 checks.

**Already covered.** Phase 0.7 reconciliation (`implement/SKILL.md:90`) classifies each batch
`already-satisfied` / `partially-done` / `not-started` and checks *cited anchors* — the artifact
confirms all 13 anchors in slice 1 existed.

**Gap.** Anchors are existing code the change attaches to. Nobody validates the
`change_manifest`'s **destination** paths or the conventions they imply. All three failures were
new-file destinations.

**Change.** A pre-seal check (new `scripts/manifest-preflight.sh`, called from Phase 0.8) that
for every new-file entry asks: does the parent directory exist? if not, does the *pattern* it
implies exist anywhere (grep the interface / idiom the path presumes)? does the filename match
its siblings' convention (timestamp prefixes, companion Designer files)? Emit corrections
**pre-seal**, so the manifest is right before approval instead of accruing 12 honest drift
records afterwards. This converts drift *recording* into drift *prevention* — the cheapest win
on this list.

### P1.2 Coverage claims need a grep, not a tag

**Evidence.** Finding 03, the highest-consequence defect on the list. The spec asserted
`TaskAssigned` "covers both manual and generated tasks with no lifecycle-specific code". False —
the generator writes `EmployeeTask` rows straight onto the context and never passes through
`CreateEmployeeTask`. Every generated onboarding checklist would have notified nobody: the exact
failure the slice existed to prevent. Caught only by someone choosing to read the second write
path.

**Already covered.** `spec-driven-development/SKILL.md:350-351` defines `[VERIFIED:path]` /
`[ASSUMED]`, and `[ASSUMED]` blocks `MTK_AUTO_PROCEED`. `scripts/verify-claims.sh` grep-verifies
claims — but only in setup docs (CLAUDE.md, architecture-principles.md), never in specs.

**Gap.** "One hook covers both callers" reads as design description, not as a checkable claim,
so it attracts neither tag. And it is a claim about a *write path*, which is exactly the kind a
grep settles in one command.

**Change.** Name **coverage claim** as a claim class in `spec-driven-development` with a
mandatory recipe: enumerate every write site for the entity or event (grep the entity name
against `.Add(`, `Attach`, `Update`, direct context writes) and list each with `file:line`
before the batch that depends on the claim. Record them in the sidecar as
`coverage_claims: [{claim, write_sites: [...], verified_at}]`, and have Phase 3.5 fail the
batch whose claim has an unenumerated site. In a codebase where a handler and a job both write
the same entity, there usually is no shared point — the toolkit should assume that.

### P1.3 Collateral-artifact blast radius guard

**Evidence.** Three incidents, one shape — the intended change is small and the commit is huge,
with the excess machine-generated or whitespace:
- one `npm install` rewrote **39,000 lines** of `website/package-lock.json` into a feature commit;
- `npm run screenshots` rewrote **78 of 84** images (mostly font rasterisation) — reverted twice;
- a 60-line addition to `InventhorContext.cs` produced a **2,013-line diff**, because it is the
  only CRLF file in `backend-server`.

All three were caught by a human reading a diffstat before pushing.

**Already covered.** `spec-drift-detection/SKILL.md:99-101` diffs lockfiles — but for
*dependency shift* (undeclared new deps), which is a different question. Churn thresholds
(300/500 net lines, `incremental-implementation:49`, `subagent-implementation:107`) trigger a
review; they do not ask whether the churn is *yours*.

**Change.** A collateral check in `pre-commit-review` (or a `hooks/collateral-guard.sh`) that
flags, with the exact revert command:
- generated / lockfile / binary paths **not in the `change_manifest`**;
- any file whose diff is ~entirely whitespace or EOL churn — `git diff --stat` versus
  `git diff -w --stat` divergence catches the CRLF class exactly, in one command;
- a generated-asset set where the rewritten fraction exceeds a threshold (78/84 trips; 5/84
  does not).

---

## P2 — cheap and concrete

### P2.1 Defect-class sweep after a confirmed finding

Finding 05 ends: *"Worth a look at the sibling handlers — their tests do pass, so it is a
caution, not a proven fault."* The run knew the sweep was owed and could not close it.
`grep -rn 'sibling\|sweep'` across `code-review-and-quality` and the reviewer agents returns
nothing. Add the rule: when a finding is **confirmed**, grep the defect *pattern* repo-wide and
report each hit as confirmed / not-applicable / needs-check. One bug becomes a class fix.

### P2.2 Two stack-reference gaps, found empirically

These are stack-general, so they belong in shared references rather than one repo's
`lessons.md`:

- `.claude/references/dotnet/ef-core-checklist.md` — ordering or filtering by a member of a
  **projected record** rather than the entity is untranslatable, and EF abandons the whole query
  rather than sorting in memory. The file currently has exactly one projection line
  (`:14`, prefer `.Select()` over `.Include()`) and nothing on translation. (Finding 06.)
- `.claude/references/typescript/` — (a) an `await` inside a mutation's `onSuccess` hands control
  back, so anything set *after* it races whatever the user did next; here it turned a create into
  a **rename** of the record the user thought they had left (finding 02, data loss, e2e-only —
  four passing component tests did not have that shape). (b) `request.headers.get('cookie')` is
  always `null` on an intercepted Request — Cookie is a forbidden header name; read MSW's parsed
  `cookies` argument instead (finding 05).

### P2.3 Conditional descopes as a sidecar field, not prose

Both spec-authorised reductions fired and correctly did not re-open the gate
(`AssetApprovalPending` → four write sites not one; away-today's public-holiday nuance →
`ResolveCountryCodeAsync` is per-user). That worked — as prose. Give it a field:
`conditional_descopes: [{condition, action, fired, evidence}]`, so the gate logic and the final
report both read the same record and a fired descope is recorded rather than narrated.

### P2.4 Standing approval should declare its scope

One human gate covered three slices; slices 2 and 3 record a standing approval from slice 1's
answer. Honest, but retroactive. Let the gate declare `gate_scope: [slice-1, slice-2, slice-3]`
**at answer time**, and expire the standing approval if a later slice's rigor score exceeds the
gated one.

### P2.5 The run record is gitignored

`tasks/lessons.md` (+180 lines, 10 entries) is the only tracked artifact of this run; the
sidecars and evidence live under gitignored `.mtk/`. The artifact exists because a human wrote
it. Consider an opt-in run receipt on a tracked path via the existing
`scripts/mtk-verify-run.sh` / `MTK_ARTIFACT_PUBLISH` machinery. Lowest priority here — but note
that this run is also the **first natural test case for the round-8 lesson-rent machinery**
(`lesson-refresh/SKILL.md:65`, `.mtk/recall-log.jsonl`): 10 fresh entries went in, so the next
that field run is where recall precision can actually be measured rather than argued.

---

## Sequencing

| Order | Item | Why first |
|---|---|---|
| 1 | P1.1 manifest pre-flight | Cheapest, prevents the largest volume of downstream work (12 corrections) |
| 2 | P1.3 collateral guard | One `git diff -w` comparison covers three separate incidents |
| 3 | P0.1 dispatch capability + inline-MAX | Unblocks Phase 4 reportability; third sighting, so the contract is the bug |
| 4 | P0.2 baseline capture | Depends on nothing, but costs a suite run — land after the cheap wins |
| 5 | P1.2 coverage claims | Highest-consequence defect class; needs a schema change to the sidecar |
| 6 | P2.1–P2.5 | Independent, small, land in any order |

**Not doing.** Nothing here proposes touching the rigor score formula, the collision gate, or
the lessons pipeline — all three performed as designed in this run.
