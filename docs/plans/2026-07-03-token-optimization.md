# Token Optimization — 5-item plan

> Drafted 2026-07-03. Shipped as v7.20.0 (2026-07-06) — main had advanced past the drafted v7.18 target.
> Items 1, 3, 4, 5 implemented in full. Item 2 shipped as the **safe subset** (setup-bootstrap Root CLAUDE.md template → on-demand reference); deeper restructuring of the other large workflow skills, and the tech-stack scan-recipe split (cross-consumed by setup-audit), are deferred to their own reviewed change.
> Goal: push MTK's always-on context floor down, shrink the fattest on-demand loads,
> and make MTK's (largely already-real) token savings **visible and quantifiable to users**.

---

## Context — what we're optimizing against

Measured footprint of the installed toolkit (byte counts via `wc -c`, ~4 chars ≈ 1 token).
MTK is **already heavily context-optimized**: progressive disclosure via `rules/INDEX.md`
+ path-gated rule bodies, deferred references (43/44 `alwaysApply=false`), the 94 KB manifest
kept out of context behind the `mtk-context` MCP server, guarded hooks (0 tokens/tool-call at
baseline), 6 review agents offloaded to separate contexts, and `mtk-compress` for large output.
The items below are **incremental** and, for Item 4, about *surfacing* savings we already make.

**Always-on baseline ≈ 5,100–5,600 tokens / session (main thread):**

| Rank | Always-on cost | ~tokens | Owner |
|---|---|---|---|
| 1 | **40 MTK skill `description` fields** (git-tracked; excludes 7 vendored gitnexus skills) | **~1,500** | MTK |
| 2 | `CLAUDE.md` (auto-loaded) | ~1,665 | MTK |
| 3 | 7 MCP tool schemas (standard install; 0 in this ToolSearch-deferred harness) | ~574 | MTK |
| 4 | `references/security-checklist.md` (`alwaysApply=true`, glob `**/*`) | ~443 | MTK |
| 5 | `rules/INDEX.md` (wake-up layer) | ~285 | MTK |
| 6 | 6 agent `description` fields | ~256 | MTK |
| — | Per-tool-call / per-prompt hook baseline | **0** (guarded) | MTK |

**Correction vs. first-pass analysis:** the 7 `gitnexus-*` skills under `.claude/skills/gitnexus/`
are **not tracked by this repo** (`git ls-files .claude/skills/gitnexus/` → 0) and the validator
already skips non-manifest skills. They are a separately-installed plugin (~385 always-on tokens)
and are **out of scope** — we cannot optimize another plugin's descriptions, and they should not
be counted as MTK cost.

**The headline pressure point:** Claude Code reserves `skillListingBudgetFraction` = **1% of the
context window** for all skill metadata (~2,000 tokens on a 200K Sonnet). MTK's 40 descriptions
(~1,500 tok) **plus** any co-installed plugins' skills (gitnexus adds ~385, others add more) push
a real user's total toward/over that ceiling. Past it, Claude Code truncates descriptions
(`skillListingMaxDescChars`, default 1536) then drops the least-used ones — wasting tokens **and**
silently degrading routing. On the maintainer's Opus 1M context the budget is ~10K (fine); the risk
lives on teammates running 200K models.

**Biggest on-demand loads** (one at a time, only when invoked): SKILL.md bodies total ~121K tokens;
fattest are `setup-bootstrap` (13.4K), `setup-audit` (8.8K), `subagent-implementation` (6.8K),
`implement` (6.0K), `spec-driven-development` (5.9K), `tech-stack-typescript` (5.6K),
`verification-before-completion` (4.4K).

---

## Item 1 — Enforce a skill/agent description budget (extend the existing gate)

**Problem.** Skill descriptions are the #1 always-on cost and are near the 1% skill-listing budget
on 200K models. `validate-toolkit.sh` already has a "Token budget enforcement" block (line ~237)
and an *advisory-only* multi-sentence-description warning tied to S2.5 (line ~313), but nothing
caps per-description length or the aggregate budget, so drift is invisible until a user's `/doctor`
warns about truncation.

**Change.**
1. Promote the advisory description check to an enforced **per-description char cap** (proposed
   **≤ 200 chars**, keyword-dense, third-person "what + when" per S2.5/S2.6). Keep it a `WARN`
   for one release, flip to `fail()` in v7.18.
2. Add an **aggregate budget check**: sum of all manifest-tracked skill descriptions must stay
   under a declared ceiling (proposed **6,000 chars ≈ 1,500 tokens**); print the current total on
   every run so drift is visible in CI.
3. Apply the same per-field cap to the 6 agent descriptions.
4. One-time trim of the current longest MTK descriptions (`research-context` 296, `source-driven-
   development` 212, `handoff` 211, `golden-path-capture` 209, and the rest > 200) down to the cap.

**Touches.** `scripts/validate-toolkit.sh` (extend existing token-budget + description blocks);
the ~10 longest `.claude/skills/*/SKILL.md` frontmatter descriptions; `.claude/rules/skill-authoring.md`
(document the cap under S2.5/S2.6); `.claude/rules/toolkit-structure.md` if the budget constant lives there.

**Estimated savings.** ~250–450 always-on tokens now (trim longest to cap), and — more valuable —
a hard stop on future growth past the 1% ceiling, protecting routing quality on 200K models.

**How we measure & report.** Before/after = sum of description chars ÷ 4. The validator prints
`skill descriptions: N chars (~M tokens) / budget 6000` on every run; the delta from this change is
the reported saving.

**Effort:** S. **Risk:** Low — trimming must preserve trigger keywords (descriptions drive routing);
review each edited description against its skill's real invocation triggers.

---

## Item 2 — Progressive-disclosure the 7 fattest skill bodies

**Problem.** When a skill fires, its **entire** SKILL.md body loads. `setup-bootstrap` alone is
~13.4K tokens per invocation; the top 7 are ~50K combined. Anthropic guidance: keep SKILL.md body
< 500 lines and move templates / rare branches / edge-case handling into sibling files read only when
that branch is reached (one level deep — no nested references). Comparable plugins report ~60%
per-trigger reductions doing exactly this.

**Change.** For each of the top 7, pull rarely-hit content out of the main body into
`references/` or skill-local files linked one level deep:
- `setup-bootstrap` — per-stack customization tables and monorepo generation are **already**
  partially externalized (`bootstrap-customization.md`, `monorepo-bootstrap.md`); finish the job by
  moving remaining rare-stack STEP content and long templates out of the hot path.
- `setup-audit`, `spec-driven-development`, `subagent-implementation`, `implement`,
  `tech-stack-typescript`, `verification-before-completion` — extract long inline templates,
  example blocks, and low-frequency conditional branches.

**Touches.** The 7 SKILL.md bodies; new/expanded files under `.claude/references/` (register each in
`.claude/references.index` with a scoped `globs` and `alwaysApply=false`); `manifest.json` (C0.2 —
every new file must be listed). Respect S3.16 shrink-guard on any regenerated index.

**Estimated savings.** ~40–60% off each body *when triggered* → ~20–30K tokens saved per invocation
of the heavy setup/implement flows (not always-on).

**How we measure & report.** Per-skill `count-tokens.sh <SKILL.md>` before/after; the migrated
reference bytes still exist but are now conditional. Report as "`setup-bootstrap` loads N% lighter
per trigger; rare-path content moved to on-demand references."

**Effort:** M–L (largest item). **Risk:** Medium — must not break workflow correctness; extracted
content must still be reachable exactly when the skill needs it. Keep references **one level deep**
from SKILL.md (Anthropic anti-pattern: nested references get partially read). Validate each skill's
anatomy (C0.3) after splitting.

---

## Item 3 — Close the two always-on leaks (`alwaysApply` reference + MCP schema scope)

**Problem.** Two costs escape progressive disclosure:
1. `references/security-checklist.md` is the **only** reference with `alwaysApply: true` and glob
   `**/*` (~443 tokens on every reference-resolution pass, security-relevant or not).
2. The 7 `mtk-context` MCP tool schemas (~574 tokens) register on every standard install whether
   used or not.

**Change.**
1. Scope the checklist to security-relevant paths instead of universal apply. Two sub-options:
   - Keep `alwaysApply: true` but narrow `globs` to auth/secrets/infra/external-input paths
     (e.g. `**/*auth*`, `**/*Secret*`, `**/*.env*`, `**/Startup*.cs`, `**/Program.cs`, infra dirs); **or**
   - Set `alwaysApply: false` and let `security-and-hardening` / `pre-commit-review` pull it explicitly
     (it already owns the security lane). *Recommended:* the second — it matches how every other
     reference behaves and removes the special case entirely.
   Confirm no skill relies on it being universally present before flipping.
2. Trim the 7 MCP tool `description`/`inputSchema` text in `mcp/src/index.ts` to one tight sentence
   each (mirror S2.5), then rebuild the `dist/mtk-mcp-server.cjs` bundle (S3.12 — the bundle is the
   only runtime artifact).

**Touches.** `.claude/references/security-checklist.md` frontmatter; `.claude/references.index`
(regenerate via the sync path, shrink-guarded per S3.16; validator asserts sync at line ~280);
`mcp/src/index.ts` + rebuilt `dist/mtk-mcp-server.cjs`.

**Estimated savings.** ~443 tokens off every non-security reference-resolution pass; ~150–250 tokens
off MCP schemas on standard installs.

**How we measure & report.** Reference-resolution token delta (compare `mtk_resolve_references`
output size on a non-security file before/after); MCP schema char count before/after.

**Effort:** S. **Risk:** Low–Medium — the security checklist is a safety asset; if we make it
on-demand we must verify `security-and-hardening` and `pre-commit-review` still load it on every
security-touching change (add a pressure test per S2.7 to prove it still fires).

---

## Item 4 — `mtk savings` report: make the savings visible (the "tell users how much we save" ask)

**Problem.** Most of MTK's token efficiency is already real but **invisible**. We have the raw
material — `scripts/count-tokens.sh`, `scripts/analytics-report.sh`, the `mtk-compress` logs, and a
"Reference Footprint" section already in the `context-report` skill (STEP 1h) — but nothing rolls it
into a single "here's what MTK kept out of your context" number.

**Change.** Add `scripts/mtk-savings.sh` (coreutils-only per S3.3) that computes and prints, per
session where data exists:
1. **Deferred-not-loaded** — references + rule bodies that stayed on disk this session vs. the naive
   "inline everything into CLAUDE.md" baseline (~90K+ tokens MTK does *not* dump). Reuse the footprint
   math already in `context-report` STEP 1h and `count-tokens.sh`.
2. **Output compressed** — bytes/tokens reclaimed by `mtk-compress` (already logged; sum them).
3. **Offloaded to subagents** — agent bodies (~12.7K) + file-dump reads that ran in isolated review
   contexts instead of the main thread (from analytics / workflow-artifact records).
4. **Always-on baseline** — the live figure from Item 1's budget check, so users see the floor.

Surface it two ways: a `--savings` branch added to the `context-report` skill (route `/mtk savings`
to it via the `mtk` router), and a standalone CLI (`bash scripts/mtk-savings.sh`) for CI/README badges.
Output must be **honest and grounded** — every number traceable to a measured count, never a marketing
estimate. Frame the big number as "kept out of main context," not "saved you $X."

**Touches.** New `scripts/mtk-savings.sh`; extend `.claude/skills/context-report/SKILL.md`
(add a savings section; consider making it user-invocable or add a router entry in `mtk`);
`manifest.json` (register the new script); README (document the command); `.claude/rules/` if a new
S-rule is warranted for the report contract.

**Estimated savings.** None directly — this is the **reporting vehicle**. It lets us state, with real
counts, e.g. "this session MTK kept ~N tokens out of your main context (references deferred, output
compressed, review offloaded)."

**How we measure & report.** It *is* the measurement. Ship with a worked example in the README so the
numbers are reproducible.

**Effort:** M. **Risk:** Low — read-only reporting. Main risk is **overclaiming**: label estimates as
estimates, cite the `count-tokens.sh` approximation (words × 1.3), and never imply billing-grade precision.

---

## Item 5 — Analytics-driven skill hygiene + stable cache prefix

**Problem.** Every skill description is always-on tax; industry evals show a large fraction of skills
go uninvoked. MTK has 40 tracked skills and no signal on which ones earn their always-on cost.
Separately, `CLAUDE.md` opens with a ~600-char v7.14.0 changelog banner (line 3) — prose that changes
**every release**, busting the prompt cache on the auto-loaded prefix, and competing for the CLAUDE.md
line ceiling the validator already enforces (~150 lines, line ~266).

**Change.**
1. Add an **invocation-frequency view** to `analytics-report.sh` (it already reads `analytics.json`
   via `session-analytics.sh`): flag MTK skills invoked in < X% of sessions over the last N sessions
   as always-on-cost candidates. **Suggest-only** — output a list, never auto-delete (matches MTK's
   reject-by-default, no-auto-write posture). Human decides: merge, or accept the cost.
2. Move the changelog banner out of `CLAUDE.md` into the existing `CHANGELOG.md` (already required by
   the validator, line ~160). Replace the banner with a single stable line
   (`> Source of truth for AI agents. See CHANGELOG.md for version history.`) so the auto-loaded prefix
   stops changing every release → better prompt-cache hit rate + a few reclaimed tokens.

**Note on gitnexus:** moving the vendored `gitnexus-*` skills to opt-in is **not an MTK change** —
they're a separate installed plugin, not in this repo. If a teammate is over the skill budget, the fix
is on their side (`/skills` picker to disable unused plugins, or raise `skillListingBudgetFraction`).
Document this in the README's token section rather than acting on it here.

**Touches.** `scripts/analytics-report.sh` (new frequency view); `CLAUDE.md` (banner → CHANGELOG.md);
`CHANGELOG.md`; README token section (guidance on `/skills` + `skillListingBudgetFraction` for users
running many co-installed plugins).

**Estimated savings.** ~150 tokens/session from the banner, plus prompt-cache-hit improvement on the
stable prefix (harder to quantify, real on repeated sessions); pruning candidates surface further
always-on savings for humans to accept case-by-case.

**How we measure & report.** Banner: `count-tokens.sh CLAUDE.md` before/after. Frequency view: report
"these K skills fired in 0 of the last 50 sessions, costing ~M always-on tokens" as accept/merge candidates.

**Effort:** S–M. **Risk:** Low — suggest-only; no automatic skill removal. Keep CLAUDE.md's routing
table and Critical Rules (C0.x) intact when moving the banner.

---

## Rollout

1. **Sequencing:** Item 1 (cheap, protects the ceiling) → Item 3 (cheap leaks) → Item 5 (banner +
   analytics) → Item 4 (report — depends on Item 1's budget figure) → Item 2 (largest, most careful).
   Items 1/3/4/5 can land in one v7.18.0; Item 2 can be a follow-up wave if time-boxed.
2. **Versioning (S4.5–S4.7):** bump `.claude/manifest.json`, `.claude-plugin/plugin.json`, and
   `.claude-plugin/marketplace.json` in lockstep (C0.1); update `manifest.updated`. New `mtk-savings`
   skill/command = **minor** (v7.18.0).
3. **Every new file** (references extracted in Item 2, `scripts/mtk-savings.sh`) must be registered in
   `manifest.json` (C0.2) and pass anatomy checks (C0.3).
4. **Gate:** `bash scripts/validate-toolkit.sh` must print "Toolkit validation passed" before any
   change is called complete (C0.8). Regenerate `checksums.sha256` via
   `bash scripts/generate-checksums.sh` as the **last** change in the release commit (S4.11).
5. **Pressure tests (S2.7):** required for Item 3 (prove the security checklist still fires on
   security-touching changes after de-eager-ing it).
6. **Docs:** README gets a "Token footprint & savings" section (Item 4 command + Item 5 user guidance);
   AGENTS.md routes to `/mtk savings` (S4.9–S4.10).

## Honest framing for the team

MTK's architecture already realizes the large savings (deferred references, MCP-gated manifest,
offloaded review, guarded hooks). These five make that efficiency **measurable and reportable**
(Item 4), push the always-on floor down a further ~800–1,100 tokens/session (Items 1+3+5), and cut
~20–30K tokens per heavy-skill invocation (Item 2). The floor reductions matter most for teammates on
200K-context models, where MTK plus co-installed plugins crowd the 1% skill-listing budget.
