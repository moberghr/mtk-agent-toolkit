# Competitive Analysis — July 2026 Claude Code Plugins (in MTK's domain)

> Research note. Not a toolkit component. Snapshot of the July-2026 plugin landscape in
> MTK's domain (team-engineering AI-coding workflow toolkits), with a prioritized
> "borrow backlog" mapped to MTK's actual components. Sources are public GitHub repos as
> of 2026-07-20.

## Method & scope

Searched GitHub for Claude Code plugins/skills created after 2026-06-30 (584 hits), then
narrowed to the plugins closest to MTK's center of gravity: spec-driven development,
planning/batching, reviewer agents, verification, repo-health, lessons/memory, hooks,
tech-stack awareness. Each was deep-read (README + skills/agents/hooks/plugin structure)
with the explicit question: *what can MTK borrow?*

## The set examined

| Plugin | Stars | What it is | Center of gravity |
|---|---|---|---|
| `richkuo/rk-skills` | 38 | 34-skill GitHub-lifecycle automation + JS workflow engine | Issue→PR→release, base/loop skill duality |
| `EternallLight/tgc-skills` | 3 | 9-skill linear shipping pipeline | ship-to-PR, review-fix loop, post-merge cleanup |
| `jsampieri/tandem-skills` | 5 | 4-skill ceremony-scaled delegation | triage → phased plan → gated review |
| `xushuodasd/VIBE-Claude-Plugin` | 4 | 25-skill document-driven full SDLC | contract docs as prereqs, E2E, delivery |
| `kyzodb/plan` | 3 | FastMCP control plane + skills + git gates | **enforcement, not instruction** |
| `daniyalahmed21/skillforge` | 6 | Monorepo-of-plugins marketplace | adversarial-review, system-design |
| `chawdamrunal/assay` | 4 | Go LLM security scanner for CC artifacts | prompt-injection / supply-chain of skills |
| `frsorrentino/fable-director` | 3 | Hook-enforced token governance | pre-budget gate, statusline, MCP metering |
| `TurniSaha/boris-says` | 6 | Local real-time coaching plugin | quiet adaptive hooks, repetition→draft |
| `felixross66/claude-ai-coding-kit-2026` | 10 | ⚠️ **Facade** — no plugin, obfuscated `index.html` | SEO/cloaking only — nothing to borrow |

The nominal "closest competitor" (`claude-ai-coding-kit-2026`) is not a real plugin: the
repo is 100% HTML, has no `skills/`/`agents/`/`plugin.json`, and its `index.html` is a
self-decoding Base64+XOR `document.write` blob (SEO/cloaking pattern). Dropped it and
substituted the reviewer/security/coaching plugins to keep ten genuine in-domain
data points. Honorable mentions in adjacent domains: `openwiki-cc`, `chicken-noodle-chris/tome`
(doc-wiki-from-git-history — a recurring theme also in skillforge's `wiki-sync`), and
`vagkaratzas/token-saviour` (per-task tool routing for token efficiency).

---

## The through-line

Across the strongest plugins, one theme dominates and it is exactly MTK's soft spot:
**enforcement moves out of the prompt and into deterministic code.** MTK's
`verification-before-completion`, `spec-drift-detection`, and scope discipline are all
*instructions the model is asked to follow* — which it can rationalize past. Kyzo's plan,
fable-director, and assay all replace "please verify" with a hook that returns
`permissionDecision: deny`, a script that exits non-zero with a named failure, or a
verdict computed by arithmetic instead of by the model. MTK has no MCP server, but it
*does* ship hooks and bash — so most of these are portable as `PreToolUse`/`Stop` gate
scripts reading `.mtk/workflows/` state.

---

## Borrow backlog (prioritized)

Priority = value × portability to MTK's markdown/bash/JSON stack.

### P0 — high value, directly portable

1. **PreToolUse allowlist guard armed from the approved plan.** *(kyzodb/plan, fable-director)*
   A `PreToolUse` hook on `Edit|Write` that denies edits to any path outside the approved
   planning manifest; deny increments an offense counter in `.mtk/workflows/` session state
   and returns `permissionDecision: deny`. Converts MTK's "stay within approved scope" from a
   skill instruction into a harness-enforced block. Kyzo's `kyzo_allowlist_guard.py` is
   ~one file. **Targets:** `subagent-implementation`, `incremental-implementation`, hooks.

2. **Deterministic gate scripts with named exit codes.** *(kyzodb/plan `GateRefusal`, fable-director)*
   Replace prose verification with `scripts/mtk-gate-*.sh` that exit non-zero emitting one
   named failure (`MTK_GATE: DIRTY_TREE`, `MTK_GATE: NO_FRESH_EVIDENCE`), wired to
   `Stop`/pre-commit. The block becomes deterministic, not persuasive. **Targets:**
   `verification-before-completion`, `pre-commit-review`.

3. **Completion predicate = non-empty diff ∩ declared manifest.** *(kyzodb/plan `verify_task_completion`)*
   A script that diffs the working tree against the spec's declared file manifest and fails on
   (a) empty diff under a completion claim, or (b) any changed path outside the manifest.
   Pure git+bash+JSON. **Targets:** `spec-drift-detection` (make it mechanical, not narrative).

4. **Byte-equal verify-command binding.** *(kyzodb/plan)*
   Record the verify command in the spec/workflow artifact; a hook asserts the executed
   command string byte-equals the recorded one — kills MTK's biggest verification leak (model
   runs a *narrower* command than the spec implies and calls it green). **Targets:**
   `verification-before-completion`, workflow-artifacts.

5. **Poison-floor lint in `validate-toolkit.sh` / `mtk-doctor`.** *(assay `internal/poison`)*
   Pure-regex, no-LLM scan over the artifacts MTK itself ships and ingests (skill `.md`,
   `plugin.json`, `.mcp.json`, hook configs). Copy the rule bank near-verbatim:
   prompt-injection phrases (`ignore previous instructions`, `you are now`, `from now on`),
   fake role tags (`<system>`, `## SYSTEM`), hidden/bidi Unicode (`U+200B`, `U+202E`,
   `U+E00xx`), credential-path directives (`~/.ssh`, `~/.aws`), over-broad skill descriptions
   (`any/all/every task`, `always use`, `default behavior`), and skill capability grants
   (read-only skill granting `Bash`/`Write`/`WebFetch`). MTK is a *skill publisher* and
   `lesson-mining`/`promote-lesson` ingest external text into shipped files — those are the
   injection ingress points. **Targets:** `validate-toolkit.sh`, `mtk-doctor`, `writing-skills`.

### P1 — high value, moderate effort

6. **Closed review→fix→re-review loop with convergence guards.** *(tgc-skills `review-loop`)*
   MTK's reviewer agents are one-shot. Add a bounded loop: up to N iterations, 2 concurrent
   independent review lenses, dedupe findings against the current tree, fix critical-first,
   re-run gate. Hard stop conditions: both approve / max iterations / **non-convergence**
   (same finding survives 2 consecutive fix attempts) / **divergence** (remote changed →
   refuse force-push). **Targets:** `code-review-and-quality`, new "review loop" skill.

7. **Reviewer/fixer firewall + conditional re-review.** *(skillforge, tgc-skills)*
   Reviewers never edit; the fixer never re-reviews; re-review fires *only* if a fix touched
   program logic (mechanical fixes don't loop). Prevents reviewer self-justification and
   unbounded loops. Pair with the **fixer uncertainty protocol**: apply only listed defects,
   leave contested ones unfixed with a documented reason, never weaken tests. **Targets:**
   `batch-fix`, `fix`, reviewer agents.

8. **Reproducible complexity→depth score.** *(rk-skills `[C0–C100]`, tandem 3-tier triage)*
   Replace MTK's fuzzy prose thresholds ("3+ batches, 6+ files, non-none security") with an
   auditable formula. rk-skills: five 0–4 axes (Scope, Coupling, Risk, Uncertainty,
   Verification) → `score = 25×map(max(Risk,Uncertainty)) + 2×(Scope+Coupling+Verification)`
   → bands map to model + effort + reviewer depth, with golden-example rows as a consistency
   check. tandem's rule is the key discipline: *"pick the lightest execution path that will
   still catch a likely bug"* and **a plan doc's mere existence does not justify heavy
   ceremony** — MTK over-triggers full machinery once a spec exists. **Targets:** `/mtk` router,
   `implement` escalation.

9. **ship-to-PR skill (human owns merge).** *(tgc-skills `ship`)*
   Chain preflight (not on default branch, git-status coherent, intended work in diff) →
   polish → local gate → intentional commit (explicit paths, never `git add -A`) → rebase base
   if branch lags + rerun gate → normal push (never force) → create-or-reuse PR with a body
   stating what changed + how tested → hand to review loop. Closes MTK's last mile; keeps merge
   human-owned (matches MTK's safety posture). **Targets:** new skill downstream of
   `pre-commit-review`.

10. **`behaviorChanging` AUTO/REVIEW gate for cleanups.** *(tgc-skills `polish`)*
    Three parallel lenses (correctness / simplification / over-engineering) tag each finding
    `behaviorChanging: true|false` + confidence. AUTO-apply only high-confidence
    non-behavior-changing (or low-risk corroborated by ≥2 lenses); everything behavior-altering
    goes to REVIEW. The sharp inversion: *a correct bug fix still needs approval because
    auto-changing runtime behavior unseen is the dangerous case*, while mechanical refactors
    auto-apply. MTK's `code-simplification` is single-lens and behavior-preserving-only.
    **Targets:** `code-simplification`.

### P2 — worth adopting, lower urgency or narrower

11. **Deterministic verdict + verbatim-citation validator.** *(assay `ComputeVerdict`)*
    Require each review finding to carry `file:line` + a quoted snippet; a post-validator
    re-reads the cited file and drops findings whose snippet isn't within ±3 lines
    (whitespace-normalized). Compute pass/block from severity counts *in code*, not by letting
    the model self-grade. Hardens MTK's reviewers against confabulation. **Targets:**
    reviewer agents, `pre-commit-review`.

12. **Quiet, adaptive tier-2 hooks.** *(boris-says `judge-cascade`)*
    MTK's tier-2 hooks fire on structural triggers with no budget. Borrow the quiet cascade:
    reflex pre-filter (no-LLM), per-session cooldown, **one nudge per session**, a cheap
    Haiku "prospector" gate before any expensive call, an observe-only warmup window for fresh
    installs, and a ≥3-rating feedback-adaptive floor (downvoted nudges fire less). Plus the
    **detached-judge + Stop-hook mailbox drain**: `UserPromptSubmit` spawns a detached unref'd
    process doing slow work into a mailbox file; the `Stop` hook drains it so coaching lands in
    the *same* turn; consume-once via atomic `rename()`. **Targets:** tier-2 hook design.

13. **Capture drafts *runnable artifacts* with false-positive gates.** *(boris-says `habit/`)*
    MTK's golden-path/lesson capture records lessons; boris drafts a runnable
    `SKILL.md.draft` / CLAUDE.md rule / hook (`.draft` suffix blocks auto-load; activation =
    `mv`). More importantly, borrow its three false-positive gates: **temporal-separation**
    (require 3 distinct time windows, not 3 concurrent sessions), **self-match calibration**
    (a mined pattern must re-match ≥3 of its own historical occurrences or it's rejected as
    non-generalizing), and **dismissal-similarity** (Jaccard ≥0.6 against dismissed patterns →
    drop). **Targets:** `golden-path-capture`, `lesson-mining`, `correction-capture`.

14. **Semantic drift-guard CI test for sibling skills.** *(rk-skills `contract-inventory`)*
    MTK's ~50 skills restate cross-cutting rules (verification, worktree usage, C0.x). A test
    that fails the build when a consumer skill drops or contradicts a required shared *semantic*
    marker (thresholds, STOP co-located with terms in the body) — checking meaning, not string
    equality, with an explicit intentional-exceptions section. Catches drift `validate-toolkit.sh`
    (structural only) misses. **Targets:** new test, `validate-toolkit.sh`.

15. **Budget-floor resumability for long runs.** *(rk-skills `milestone-pipeline.js`, fable-director)*
    On a multi-batch run, take a `budgetFloor`: instead of dying at the ceiling, defer
    remaining work and return partial results; anchor `runId` in a durable artifact so re-running
    skips completed batches and resumes in-flight ones idempotently. MTK's `.mtk/workflows/`
    already persists state — add the floor + resume-skip logic. **Targets:**
    `subagent-implementation`, `workflow-artifacts`.

16. **PR-review output grammar.** *(rk-skills `pr-review-format`)*
    Machine-actionable review format: verdict keys off *blocking sections only*; a materiality
    filter drops trivia (and never mentions it); an absolute safety carve-out overrides
    materiality; each finding "plain English, <55 words" + `Invariant:` + `Must survive: 1–3
    adversarial cases`. **Targets:** reviewer agents' output contract.

### P3 — adopt selectively / avoid

17. **system-design skill (genuine gap).** *(skillforge)* MTK has no architecture-altitude design
    skill; `brainstorming` explores approaches but does no capacity estimation, storage
    selection, or scaling-ladder review. Borrow the 8-step method and especially the
    **right-sizing gate** (every component must answer: what bottleneck does this eliminate?
    what cost does it add? what simpler solution still meets requirements? — *"over-engineering
    is a bug; under-engineering is also a bug"*) and the **Design vs Review dual mode**.

18. **Demolition-first "Condemned" block + banned-language grep.** *(kyzodb/plan)* Every spec
    names the rejected/removed path + an auditable closure test before naming the replacement;
    mood verbs and escape hatches ("for now", "improve", "phase 2") are mechanically greppable
    violations. Zero-infra authoring convention; add the banned-phrase pass to `lint-ears.sh`.
    **Targets:** `spec-driven-development`, `lint-ears.sh`.

19. **Contract-prereq gate + executor-bound task ledger + circuit breaker.** *(VIBE)* A
    prerequisite check that refuses to code a slice touching a public API/schema until a
    contract stub exists; a task ledger line format `- [ ] MODULE | skill | status` for
    deterministic dispatch/resume; an N-failure circuit breaker that marks a slice `[Blocked]`
    and continues instead of thrashing the whole run.

20. **Adversarial reviewer persona (liftable verbatim).** *(skillforge)* Stance lines to graft
    into MTK reviewers: *"Assume the code is WRONG until proven otherwise. You did not write
    this code and have no stake in it merging. If you find yourself inventing reasons the code
    works, stop — that is the author's job."* Plus no-padding output (say "no defects" rather
    than pad) and a turn cap for cost.

**Anti-patterns to avoid** (mostly from VIBE): skill sprawl (25 skills, one-per-document
granularity — borrow the *stages*, not the granularity); heavy contract docs with no drift
detection; "absolute silence" full autonomy after a single approval; silent auto-install of
security tooling (semgrep/gitleaks) — a supply-chain/egress concern for regulated repos.

---

## Fastest wins

If picking three to do first: **(1)** the PreToolUse allowlist guard (P0-1) and **(2)** the
diff∩manifest completion predicate (P0-3) — together they convert MTK's two weakest
"please-behave" guarantees into harness-enforced checks with ~two small scripts; **(3)** the
assay poison-floor lint (P0-5) — MTK is a skill publisher that ingests external text, and this
is copy-paste regex with immediate self-security value.
