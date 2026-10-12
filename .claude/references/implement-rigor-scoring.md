---
description: Rigor Score detail for implement — signal/points table, contract-surface rule, mechanical definition, and scope-reduction recompute guardrails
globs: []
alwaysApply: false
---
# Rigor Score — continuous ceremony scaling for `implement`

> Extracted from `.claude/skills/implement/SKILL.md` (S2.26: a SKILL.md is a
> navigation layer, not a payload). The skill keeps the decision — when this
> fires, what it outputs, and what stops the run. This file holds the detail,
> and is read **only** when that phase is actually reached.

---

## Rigor Score (Continuous Ceremony Scaling)

Compute after Phase 2, from the JSON sidecar at `docs/specs/<date>-<slug>.json`, and **recompute when the approved scope shrinks** (see *Recompute on scope reduction* below). Ceremony scales with the change's blast radius — a small fix gets a light pass, a breaking multi-batch change gets the full apparatus, and everything in between gets *proportional* rigor rather than a binary jump.

| Signal | Points |
|---|---|
| Implementation batches | +1 per batch |
| Change manifest size | +1 per 3 non-mechanical files (rounded up) |
| `security_impact != "none"` | +3 |
| External public contracts added or modified (`surface: external`) | +1 each (cap +4) |
| Internal-tooling contracts (`surface: internal-tooling`) | +1 total if any present |
| `scope == "breaking-change"` | +3 |

> **Contract surface matters (do not conflate the two).** A `public_contracts[]` entry scores by its `surface` field (schema default `external`). **External/wire contracts** — HTTP endpoints, published events, library methods callers depend on, persisted or wire schemas — score +1 each (cap +4). **Internal-tooling contracts** — repo-internal build/IaC/CLI knobs (CDK config props, an internal CLI flag, a build-script option) with no external consumer — score **+1 total regardless of count**, because an internal flag carries nowhere near the blast radius of a public endpoint. This stops a handful of CDK props or an internal CLI flag from swinging the score ±4 and flipping HIGH↔MAX. When genuinely unsure whether a surface is external, treat it as external (the safer, higher-ceremony choice).

| Score | Rigor level |
|---|---|
| ≤ 3 | LIGHT |
| 4–7 | STANDARD |
| 8–11 | HIGH |
| ≥ 12 | MAX |

**Hard-trigger floor:** any of `plan.batches.length >= 3`, the count of non-mechanical `change_manifest` entries `>= 6`, or `security_impact != "none"` forces the level to at least HIGH regardless of score. An entry is **mechanical** only when it changes no logic and no public contract — rename-only, formatting-only, or otherwise no-behavioral-change (cf. the TDD `skip_when` categories `rename-only|formatting-only|no-behavioral-change`); an entry touching any public contract — including a serialized shape, persisted schema, or wire format — is never mechanical; mechanical entries are still implemented and verified, they just don't count toward the floor or the size score. These are the long-standing subagent-path triggers — the score scales ceremony continuously *between* them; it never relaxes them.

What the level dials:

| Dial | LIGHT | STANDARD | HIGH | MAX |
|---|---|---|---|---|
| Phase 3 path | inline | inline | subagent | subagent |
| Phase 4 Stage 2 reviewers | conditional (per Stage 2 rules) | conditional | `test-reviewer` always; `architecture-reviewer` if boundary/slice condition applies | both + `silent-failure-hunter` |
| `MTK_AUTO_PROCEED` eligibility | yes | yes | no | no |

> **The Phase 3 dial names a path, not a guarantee.** `subagent` is what HIGH/MAX *prescribes*; whether the session can dispatch at all is probed at Phase 2.9 and recorded as `dispatch_capability`. When dispatch is forbidden or unavailable, HIGH/MAX runs the **inline-MAX profile** (Phase 2.9) with its compensations named — it does not silently become a STANDARD-shaped inline run, and it does not lower the level.

**Per-batch mechanical exception (Phase 3 path).** Even at HIGH/MAX, an individual batch whose `change_manifest` entries are *all* mechanical (per the mechanical definition above) runs **inline**, not through a fresh implementer subagent — context isolation buys nothing when a batch changes no logic and no contract. The subagent path governs the non-mechanical batches; a pure config/rename/formatting batch inside an otherwise-HIGH run is implemented inline, with the orchestrator's drift micro-check and verification still applied. See `subagent-implementation/SKILL.md`.

State the score and level in one line in the Phase 2.5 gate rendering (e.g. `Rigor: HIGH (score 9 — 3 batches, 8 files, security_impact=new-auth-path)`) so the engineer sees why the ceremony is sized the way it is. When any `change_manifest` entries are mechanical, surface the split in that line so the engineer can veto the discount (e.g. `Rigor: STANDARD (score 4 — 8 files, 6 mechanical)`).

**Recompute on scope reduction.** The score is set at Phase 2, but the approved batch set can shrink mid-run — a batch is deferred, dropped, or split to a follow-up. When it does (detected at a **phase boundary** — a batch deferral during Phase 3, or the Phase 3.5 drift check — never mid-batch), **recompute the score and level from the batches that remain in scope** and their `change_manifest` entries, then adopt the recomputed level for the rest of the run (Phase 4 reviewer set and `MTK_AUTO_PROCEED` eligibility both follow it). Guardrails:

- **Recompute only relaxes — it never drops below the hard-trigger floor of the *remaining* work.** If the deferred batch removed the only `security_impact` or the last public-contract change, that floor legitimately lifts; if the remaining batches still count `>= 3` or `>= 6` non-mechanical files, the floor holds at HIGH regardless of the lower score.
- **A scope *increase* is never a silent recompute — it re-opens the Phase 2.5 gate** (unchanged; see Phase 3.5). Only a *reduction* auto-relaxes: the engineer already approved the larger scope, so shipping less of it needs no new approval.
- **Log the transition.** Record it on the workflow artifact (`"$WFA" set "$MTK_WF_UUID" results.rigor_recomputed="HIGH->STANDARD (2 of 4 batches deferred; score 9->5)"`) and state it to the engineer in one line mirroring the rendering above, so the ceremony change is visible rather than silent.
