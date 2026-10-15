# Competitive Analysis — October 2026 (trending + new)

> Research note. Not a toolkit component; not manifest-listed (same as
> `competitive-analysis-2026-07.md` and `-08.md`). Snapshot of the 20 most relevant
> trending or newly created repos in MTK's domain as of **2026-10-13**, compared against
> MTK 9.0.0, with a prioritized borrow backlog. Read the August note first for the
> evidence/benchmark backlog; this one does not repeat repos covered there, in the July
> note, in the Aug-17 borrow rounds or in the September ECC note.

## Method & scope

Three parallel research lanes, ~100 `gh search repos` queries plus web search, then
shallow clones and source reads of ~45 repos:

- **A — workflow / plugin peers:** spec→plan→implement→review skill packs, Claude Code
  plugins, multi-harness kits.
- **B — guardrails, verification, review, evals:** hook packs, anti-tampering, review
  agents, skill eval harnesses.
- **C — context, memory, setup, cost:** AGENTS.md tooling, code indexes, memory/lessons,
  handoff, session cost.

Selection: lifetime **stars/day** × in-domain relevance, with release cadence in
Sept–Oct as the "trending now" signal for older repos (the stargazer-timestamp API
returned 404, so recent-window growth could not be measured). Confidence labels:
**[SRC]** = mechanism read in source, **[README]** = claim seen in docs only. Every
"MTK lacks X" claim below was re-checked against this repo; one lane claim that failed
the check is corrected inline.

### ⚠️ Star-count warning: the "Jev" cluster

15+ repos created Sept 16–24 are built on one paid third-party decision-model API
(`tamaratran/fast-jev-compaction` — 7,615★ in ~1 day, single push; `jev-review`,
`jevals`, `toolgate`, `skillranker`, `abide`, `jevgrep`, …). This looks like a
coordinated launch. Treat their stars as noise. Most also **send diffs or source to that
API**, which rules out the tools themselves for finance clients. Two of them still carry
borrowable *ideas* (abide's replay calibration, jevgrep's AGENTS.md line audit); they are
listed as honorable mentions, not in the top 20.

---

## The top 20

| # | Repo | ★ | ★/day | Created | Lane | What it is |
|---|---|---|---|---|---|---|
| 1 | `DietrichGebert/ponytail` | 162.6k | ~1,322 | 06-12 | A | Minimal-code ruleset + review skills; SubagentStart injection; agentic A/B bench |
| 2 | `mattpocock/skills` | 289.3k | ~1,148 | 02-03 | A | ~28 small composable skills; parallel ticket frontier; `retro` |
| 3 | `Graphify-Labs/graphify` | 126.1k | ~654 | 04-03 | C | Tree-sitter code graph + per-harness always-on integration |
| 4 | `garrytan/gstack` | 136.3k | ~631 | 03-11 | A | CLI state machine for plan/review/ship; pregate; cross-model review |
| 5 | `addyosmani/agent-skills` | 106.1k | ~442 | 02-15 | A | MTK's lineage; new floor-guard, doubt-driven-dev, revalidating cache |
| 6 | `alibaba/open-code-review` | 46.9k | ~317 | 05-18 | B | Hybrid deterministic + LLM review CLI; fact-check + re-anchor passes |
| 7 | `DeusData/codebase-memory-mcp` | 46.5k | ~201 | 02-24 | C | Native code-graph MCP; fail-open context hooks; per-harness withhold policy |
| 8 | `Yeachan-Heo/oh-my-claudecode` | 39.9k | ~144 | 01-09 | A | Orchestration plugin; off/shadow/active enforcement rollout |
| 9 | `tigerless-labs/autoharness` | 11.0k | ~88 | — | A | Deterministic skill lifecycle: probation, graduation, capacity cap |
| 10 | `tigerless-labs/agent-memory` | 3.4k | ~81 | 09-01 | C | Markdown-first memory; decision ledger; watermark mining; live-preflight setup |
| 11 | `EveryInc/compound-engineering-plugin` | 25.5k | ~69 | — | A | Learnings with `retire_when`; measurement-first retune |
| 12 | `akitaonrails/ai-memory` | 9.2k | ~64 | 05-21 | C | Cross-harness memory; typed handoff state machine (offer, not claim) |
| 13 | `getagentseal/codeburn` | 11.4k | ~62 | 04-13 | C | Local cost analyzer; transcript waste detectors; promise-vs-realized |
| 14 | `Leonxlnx/unlazy` | 3.9k | ~60 | 08-09 | A | Pre-declared CHECK/EXPECT gate ledger; approval-bound commands; ABANDON |
| 15 | `openqodex/openqodex` | 645 | ~59 | 10-02 | B | Pre-push review: scanners → separate reviewer → diff-bound receipt |
| 16 | `lennney/stop-that-shit` | 2.6k | ~41 | 08-11 | B | Intent/scope guard; read-only mode; paired good/bad decision cases |
| 17 | `redhat-et/ripwire` | 2.4k | ~32 | 07-29 | C | Ranked call-graph CLI; symbol-pinned notes; output disclosure contract |
| 18 | `kunchenguid/backpass` | 1.4k | ~26 | 08-21 | A | Evidence-gated AGENTS.md edits from transcripts of 7 harnesses |
| 19 | `aoci-spec/aoci-code` | 1.5k | ~23 | 08-08 | C | Per-entry drift-tracked code index (FSL license — concepts only) |
| 20 | `umputun/revmux` | 99 | ~1.3 | 07-26 | B | Supervised find → synthesize → verify review; five verdicts |

`revmux` is in on engineering, not stars — it is the cleanest review protocol seen in
any sweep so far.

**Honorable mentions (low stars, high signal):** `alifurkangokce/driftlint` (60★ —
closest overlap with `instructions`; load-budget and silent-config checks MTK lacks),
`hahahahahahahahah6/agent-guard` (66★ — test-tamper, Bash-write and hook-liveness
guards), `smixs/code-quality` + `svetdev/cleat` + `hidevinliu/red-green-mode` (paired
assertion weakening, ratchets, stall detection), `GGGODLIN/claude-pr-review` (per-file
disposition, finding UIDs across rounds), `coldteadotai/abide` (Jev; replay calibration),
`dzhng/jevgrep` (Jev; `audit-agents` skill), `BayramAnnakov/claude-reflect` (tool-rejection
mining), `kharmanskyi/open-steps` (per-model skill-trigger matrix with off-topic row).

**Screened, not deep-read:** `headroomlabs-ai/headroom` (75k★, proxy compression — its
cache-prefix volatility lint is worth a look), `TencentCloud/TencentDB-Agent-Memory`,
`rohitg00/agentmemory`, `paladini/harness-score`, `QoderAI/better-harness`,
`coleam00/Archon` (curl|bash installers).

### Big-repo deltas since 2026-08-05

1. **obra/superpowers v7.0.0 (10-10) — builder check.** A fresh subagent reads the design
   doc *as the builder* and lists what it would still have to ask; the orchestrator sorts
   each question into "answered in doc", "my call" (settle + mark) or "theirs" (one batched
   round to the user). Ceremony is sized *after* understanding. [SRC]
2. **github/spec-kit 1.0 → 1.2 (08-21 → 10-13)** — from templates to a workflow engine:
   step types, bundles, exact-release pinning of catalogs, MCP artifact tools. [README]
3. **BMAD-METHOD v6.12 (09-04)** — ceremony decided after investigation; review triage
   logs a verdict + evidence for every finding; adopts a handwritten AGENTS.md instead of
   rewriting it. [README]

---

## The through-line: July was enforcement, August was evidence, October is receipts

Gates are assumed now, and published numbers are spreading. October's new mechanism is
the **receipt**: a gate has to prove *that it ran, on exactly what, and that its false
positives are worth it*.

- **Bound to the artifact:** gstack refuses a review whose `INPUT:` sha256 doesn't match
  the current plan snapshot. openqodex's push receipt is a hash of base + diff, so a force
  push over unseen commits isn't covered.
- **Coverage from the trace, not the reviewer's word:** openqodex counts a changed range
  as reviewed only if the reviewer's own Read calls covered it. claude-pr-review requires
  every changed file to be `finding | REVIEWED_NO_ISSUES | INTENTIONALLY_SKIPPED`.
- **Liveness:** agent-guard reports a configured guard that fired zero times in N days as
  a silent failure. agent-memory reports READY only after a live hook round-trip.
- **Rollout economics:** OMC ships blocking guards as `off | shadow | active`, default
  shadow, logging would-have-blocked events. abide replays a rule over past transcripts
  to measure its precision *before* enabling it. stop-that-shit requires an allow twin for
  every deny case.

This lines up with what MTK's own 8.2/9.0 evals found: the value sits in deterministic
gates and the approval stop, not in prose. The receipt mechanisms make those gates
cheaper to trust and cheaper to adopt.

**The usability signal points the same way.** The two biggest repos by velocity
(ponytail, mattpocock/skills) are small, composable and explicitly anti-ceremony;
mattpocock's README pitches against spec-kit and BMAD by name. openqodex's
`npx openqodex init` detects the installed agents, lists every file it will write, asks
once, and finishes with a first real review. MTK's 9.0 diet was the right direction; the
remaining friction is in setup and in gates that can't be trialled before they block.

---

## Head-to-head: where MTK stands

### Where MTK is still ahead

- **Org-standard distribution + claim verification.** None of the 20 distributes
  standards across a fleet or verifies the claims in a generated AGENTS.md against the
  code. The closest are driftlint (dead paths/commands) and backpass (evidence-gated
  edits) — both check *references*, not *claims*.
- **Approval workflow with measured lift** (implement-stops-for-approval: bare 0.11 →
  MTK 1.00). gstack and unlazy have comparable interlocks; nothing else does.
- **Review accounting.** Two-stage lanes with `ABSTAINED` and `ABSTAINED(by-policy)`
  already cover the August P1-4 gap that most peers still have.
- **Parallel waves with drift checks.** Dependency-derived waves (≤ `MTK_BATCH_WAVE_MAX`)
  with orchestrator-side drift micro-checks. *(Lane A reported MTK batches as strictly
  sequential; that is wrong — `subagent-implementation` SKILL.md "Waves come from
  `depends`". The remaining delta vs mattpocock is per-batch worktree isolation only.)*

### Where MTK is now behind

| Dimension | Field's state | MTK's state (verified) |
|---|---|---|
| Subagent context | ponytail: SubagentStart hook injects the ruleset into every subagent | `hooks.json` registers only SessionStart / PreToolUse / PostToolUse / Stop |
| Test weakening | 4 repos ship deterministic tamper detection (paired assertion weakening, `.skip`, deleted tests, suppressions) | `config-guard` covers lint/analyzer config only; test weakening reaches only an LLM reviewer |
| Gate rollout | OMC off/shadow/active; abide replay calibration; agent-guard liveness | `MTK_*_ENFORCE` on/off only; no shadow log, no zero-fire WARN |
| Review binding | gstack snapshot sha; openqodex diff-bound push receipt + trace coverage | Seals cover spec/plan; review lanes not bound to a diff hash; `security-gate` only stops force pushes |
| Review verification | revmux verify stage (confirmed/refined/rejected/immaterial/pre_existing); OCR asymmetric fact-check | Findings go straight from lane to remediation |
| Remediation loop | red-green-mode stops on no progress | Fixed cap `MTK_MAX_REMEDIATION_ITERS` (default 3) |
| Lesson mining | agent-memory decision ledger + watermark; backpass ≥2-session floor | `lessons mine` rescans last 7 days; rejected candidates resurface every sweep |
| Handoff | ai-memory: open/accepted/expired, offer-not-claim | `session-start:125` surfaces any handoff modified < 24h, no branch/state check |
| AGENTS.md budgets | driftlint: Codex 32 KB silent truncation, CLAUDE.local.md disabling AGENTS.md | MTK generates AGENTS.md for Codex but checks only its own skill-description budget |

---

## Good / borrow, by repo (condensed)

**ponytail** — SubagentStart hook (`hooks/ponytail-subagent.js`) exists because
SessionStart context never reaches subagents. The 2026-09 perf audit named subagent
standards re-reads as a top MTK cost. Also an agentic with/without-skill A/B harness
(`benchmarks/agentic/`), 39 tasks × 5 runs. [SRC]

**mattpocock/skills** — `retro`: a *mechanical* violation gets a lint/hook/CI check, never
a prose rule; a repo with no guardrail is itself a finding. Skill-invocation wording
convention ("Call the Skill tool with `x`") to raise skill-load hit rate. [SRC]

**gstack** — snapshot-bound review results (`INPUT: <phase> <sha256>`); gate reply
grammar (`all except d3b`, a bare "yes" is never guessed); `PLAN_AMEND_PENDING`
interlock; pregate reads policy from `origin/<base>` so a branch can't smuggle a
command into its own gate. Too heavy to adopt whole (Bun, dozens of binaries). [SRC]

**addyosmani/agent-skills** — `floor-guard`: diff-scoped (merge base + untracked) detection
of five bar-lowering moves, exit 0/1/2 where 2 ("could not run") is never clean. [SRC]

**open-code-review** — fact-check filter that removes only findings the diff *proves*
wrong ("I cannot verify this" means keep); snippet-quoted re-anchoring so line numbers
can't drift; public AACR-Bench (200 PRs, 1,505 labelled issues). [SRC prompts]

**codebase-memory-mcp / graphify** — fail-open, context-only hooks; per-harness
"documented contract or withhold" matrix with deliberate no-ops (Codex rejects
`additionalContext` on PreToolUse). [README]

**oh-my-claudecode** — `OMC_BUDGET_ENFORCE=off|shadow|active`, default shadow; budget
Stop-guard that sends the model back to write a resumable report; SessionStart
stale-run reconciler. [SRC header]

**autoharness / compound-engineering** — skill probation and capacity cap by call-rate;
`retire_when` on learnings (the *external* condition that retires a lesson). [SRC]

**agent-memory** — stable proposal IDs (`sha256(kind|targets)[:12]`) + append-only
decisions ledger, so a refusal is never re-proposed; per-session mining watermark;
"READY" only after a live preflight. [SRC]

**ai-memory** — handoff `Open → Accepted | Expired`; field-learned "offer, not claim"
after an auto-claim was consumed by an unrelated session. [SRC + design doc]

**codeburn** — transcript waste detectors: redundant re-reads, build-dir reads,
recurring pasted openers ("give it a permanent home"), low cache-hit sessions; each with
estimated savings, later checked against reality. [SRC]

**unlazy** — CHECK/EXPECT per acceptance criterion written before work; command approval
hashed over command + cwd + PATH so a weaker command can't be swapped in; `ABANDON: <id>
<reason>` must name a real gate. [SRC]

**openqodex** — reviewer must `raise` or `drop` every scanner candidate with a citation;
three-state `complete | complete_blocking | incomplete` (exit 2); receipts under
`~/.openqodex/receipts/` where a branch can't write. [SRC]

**stop-that-shit** — read-only mode for review requests enforced by hook; subagent
fan-out budget; every Bad case has a Good twin that must be allowed. [SRC]

**ripwire** — output disclosure contract: a zero is a measurement, floors are labelled,
truncation carries `shown/total/capped`, a refusal is not a zero. [README spec]

**backpass** — an AGENTS.md edit needs verbatim quotes from ≥ N *distinct sessions*,
counted by code; additions route to the most specific nested AGENTS.md. [SRC]

**aoci-code** — drift tracked per index entry, not per document; admission rule
"non-inferable and error-preventing". Concepts only (FSL-1.1). [README + tree]

**revmux** — find → synthesize → verify; corroboration counted by distinct processes, not
lenses; verify verdicts include `immaterial` and `pre_existing`; "a search that could
not run is a finding of its own". [SRC]

---

## Borrow backlog

Priority = value × portability to MTK's markdown/bash/JSON stack, weighted toward
**mechanisms** (what 9.0's evals say carries the value) and **adoption ergonomics**.

### P0 — do these (small, verified, gate-shaped)

**P0-1. SubagentStart constitution digest.** Register a SubagentStart hook that injects
`constitution-digest.sh` output for MTK agent types (implementer, reviewers). Replaces
per-subagent re-reads of AGENTS.md and rules. **S.** *Source: ponytail.* Check the
current SubagentStart `additionalContext` contract before building.

**P0-2. Lesson-mining hygiene pack.** (a) Stable candidate IDs + append-only
`.mtk/lessons-decisions.md` so rejected candidates never resurface; (b) per-session
watermark instead of "last 7 days"; (c) ≥2 distinct sessions of evidence, counted by
script; (d) mechanical lessons route to a check (`hooks/linter-patterns`, CI) instead of
`tasks/lessons.md`; (e) optional `retire_when`. Each **S**. *Sources: agent-memory,
backpass, mattpocock retro, compound-engineering.*

**P0-3. Handoff offer-not-claim.** Handoff frontmatter `state: open|accepted|expired`,
`branch`, `worktree`. Session-start offers only open handoffs matching the current
branch/worktree; mark accepted only on actual resume; expire after N days. **S.**
*Source: ai-memory.*

**P0-4. AGENTS.md load-budget + silent-config checks** in `instructions audit` and
`mtk-doctor`: Codex 32 KB shared-chain truncation, `CLAUDE.local.md` / CLAUDE.md
shadowing AGENTS.md, `globs:` vs `paths:`. Add a "Move → named owner" verdict to the
line audit. **S.** *Sources: driftlint, jevgrep audit-agents.* MTK generates AGENTS.md
for Codex, so silent truncation is our bug to catch.

### P1 — high value, moderate effort

**P1-5. Test-tamper guard** (sibling to config-guard, PreToolUse Edit/Write + Stop
pre-pass). Same-target strong→weak assertion pairing, `.skip`/deleted tests, new
suppression comments, plus .NET patterns nobody ships: `[Fact(Skip=`, `[Ignore]`,
`Assert.Equal(x,y)` → `Assert.NotNull(y)`, `[Theory]` rows removed. Exit "could not run"
is never clean. Bypass only with a recorded reason. **M.** *Sources: agent-skills
floor-guard, smixs/code-quality, agent-guard, cleat — four independent repos converged
here.*

**P1-6. Gate economics: shadow mode + liveness + allow twins.**
`MTK_<HOOK>_ENFORCE=off|shadow|active` for blocking hooks; shadow writes
would-have-blocked events to `.mtk/enforcement-shadow.jsonl`; `mtk-doctor --usage`
reports them and WARNs on registered hooks with zero fires; `run-fixtures.sh` fails a
deny rule with no allow twin. **M.** *Sources: OMC, agent-guard, stop-that-shit.* This is
the strongest fit with the no-mandates adoption strategy: senior engineers can trial a
gate and see its false positives before it ever blocks them.

**P1-7. Review disposition + verify stage.** (a) Per-file disposition set
(`finding | no_issues | skipped`), checked by script; (b) deterministic findings
(linters, secret-scan, analyzers) handed to `compliance-reviewer` as candidates it must
raise or drop with a citation; (c) a fresh read-only verify pass with verdicts
`confirmed | refined | rejected | immaterial | pre_existing`, removing only what the
diff proves wrong. **M.** *Sources: claude-pr-review, openqodex, revmux, open-code-review.*
`pre_existing` maps directly onto MTK's "scope to this run's files" rule.

**P1-8. Bind reviews to what they reviewed.** Lane results carry `INPUT: <artifact>
<sha256>`; workflow-artifacts refuses a stale one. Finding UIDs reconciled as
`FIXED | STILL_OPEN | STALE` across remediation iterations. Optional pre-push receipt
(hash of base + diff, stored under `~/.mtk/receipts/`) checked by a narrow
`Bash(git push*)` hook, advisory by default. **M.** *Sources: gstack, claude-pr-review,
openqodex.*

**P1-9. Remediation stall detection + loud empty results.** Escalate when the failing
check count does not drop over two iterations, instead of only at the fixed cap.
`context-miner` and every lane must distinguish "searched, found nothing" from "could not
search". **S each.** *Sources: red-green-mode, revmux.*

### P2 — worth adopting, lower urgency

**P2-10. Builder check on specs.** Fresh subagent reads the approved spec as the
implementer and lists open questions; triage into answered / my-call / ask-the-engineer
(one batched round). Complements plan-gap-reviewer. **M.** *Source: superpowers v7.*

**P2-11. Gate reply grammar** for spec/plan approval (`all`, `all except 3`, ids) and
an amendment interlock: accepted review changes must be incorporated before the gate
passes. **S–M.** *Source: gstack.*

**P2-12. Stale-run reconciler + `ABANDON` state.** SessionStart marks
`.mtk/workflows/*` runs whose session died as `interrupted`; ledger supports
`ABANDON: <criterion> <reason>` instead of falsely ticked boxes (a gap seen in an August field run).
**S.** *Sources: OMC, unlazy.*

**P2-13. Transcript waste detectors** in `session-cost.sh` / `repo-health`: redundant
re-reads, build-dir reads, recurring pasted openers (→ `instructions capture`), low
cache-hit sessions. **M.** *Source: codeburn.*

**P2-14. Disclosure contract for MTK reports** (`repo-health`, `mtk-doctor --json`,
savings): zero is a measurement, labelled floors, `shown/total/capped`, refusal ≠ zero.
**S.** *Source: ripwire.* Extends the August "never silently zero" rule.

**P2-15. Measured value, round two.** MTK-on vs MTK-off agentic A/B on a fixture repo
with hidden checks; review lanes scored on AACR-Bench or ReviewBench (precision, recall,
$/review). **M–L.** *Sources: ponytail, open-code-review, openqodex.* Continues August
P0-1 with an external benchmark instead of only our own fixtures.

**P2-16. Per-harness hook-contract matrix** in `generate-tool-configs.sh`: emit a hook
only where the vendor's context contract is documented, with deliberate no-ops (Codex
PreToolUse `additionalContext`). **S.** *Sources: codebase-memory-mcp, graphify.*

**P2-17. Per-claim source binding** in `architecture-principles.md`: hash each evidence
anchor's file so `setup-refresh` lists only the claims whose anchors changed. **M.**
*Source: aoci-code (concept only).*

### Tension with the 8.2 runtime diet — decide before building

Two attractive ideas reverse a deliberate 8.2 decision (zero hook processes on Read /
Grep / Glob): an **index-first nudge** before Grep/Read (graphify, codebase-memory) and
**surfacing a lesson when its anchor file is touched** (ripwire notes). Recommendation:
deliver both through the context pack and subagent briefs, not a hot-path hook.

### Explicitly not borrowing

- **Any tool that ships code or diffs to a third-party model** (the Jev cluster,
  jevgrep, abide, agent-guard's `semreview`). Ideas only.
- **gstack's runtime** (Bun, dozens of binaries, several releases a day) and OMC's
  notification integrations. Too much surface for organic team adoption.
- **Graph engines as dependencies** (graphify, codebase-memory-mcp, ripwire). MTK has
  `repomap.sh` / `query-code-index.sh`; borrow the integration policy, not the engine.
- **curl|bash installers** (codebase-memory-mcp, Archon) — same safety line as August.
- **aoci-code code or text** — FSL-1.1 is not OSI-approved.
- **Cache-warm idle handoff** (`obie/auto-handoff`) — depends on an early-access API.

---

## Fastest wins

If only three things get done: **P0-1** (SubagentStart digest — one hook, directly
attacks a measured cost), **P0-2** (lesson ledger + watermark + corroboration floor —
stops the same rejects resurfacing, all small scripts) and **P1-6's shadow mode** (lets
every blocking gate be trialled before it blocks — the adoption lever that matches how
the team actually takes on tools).
