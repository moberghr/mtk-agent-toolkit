# Spec: v7.15.0 — Seven Borrowed Capabilities

> Date: 2026-06-25 · Slug: `v715-borrowed-capabilities` · Scope: feature (multi-file, toolkit-internal) · Security impact: none

## Goal

Fold seven capabilities — surfaced by a competitive analysis of trending (last-30-day) Claude Code toolkits — into a single minor release, **v7.15.0**. Each is a *delta on existing MTK infrastructure*, not greenfield. None overlaps the v7.13/v7.14 borrow wave (delta-spec, constitution-cited-input, skill-eval coverage, rule taxonomy), which explicitly deferred model-routing as a non-goal.

| # | Capability | Borrowed from | MTK delta |
|---|---|---|---|
| F1 | Explicit per-phase model routing | specwright, vibecode, prospec | Promote the advisory routing table to an enforced policy reference; wire defaults into subagent/plan/review skills |
| F2 | Context-budget checkpoint (~60%) | tworkflow (40% rule) | Add a token-estimate checkpoint to `context-budget.sh`; document in handoff/context-engineering |
| F3 | Loop circuit-breaker + plateau detection | vibecode, agentic-engineering | Configurable max-iteration cap + plateau detection + escalate-to-human, on top of the v7.14 gate machinery |
| F4 | Runtime smoke-test evidence channel | dryforge, fablize | Add `smoke-boot` ("boots-and-responds-live") to the v7.14 named evidence channels |
| F5 | Comment/doc-drift guard | omo comment-checker, guard-skills docs-guard | New heuristic `core/docdrift.txt` linter pack |
| F6 | Phase-locked tool capability limits | vibecode step-locked tools | Read-only toolsets on pure-read planning skills; tool-discipline note on artifact-writing planning skills |
| F7 | Stack/domain guard packs as shippable units | guard-skills wp/woo | Enrich `domain-finance` + `stack-dotnet` linter packs; document the guard-pack authoring model |

## Decisions (resolved at ambiguity gate)

- **F2 threshold:** default **60%** consumed of `MTK_CONTEXT_WINDOW_TOKENS` (default 200000), via `MTK_CONTEXT_BUDGET_PCT` (default 60). The estimator counts read bytes only (`bytes_read / 4`); it is an honest *floor*, labelled as an estimate. Single nudge, fires once per session.
- **F5 form:** **heuristic linter pack** only (deterministic regex smells). Bash cannot verify symbol existence or prose-vs-behavior; the pack catches falsifiable doc *smells* and is honest about being heuristic. No edit-time hook, no standalone skill.

## Constitution Check (which Critical Rules / S-rules constrain this design)

- **C0.1 / S4.6** — bump `.claude/manifest.json` and `.claude-plugin/plugin.json` versions together to 7.15.0; `manifest.updated` to 2026-06-25 (S4.7).
- **C0.2 / S1.1** — every new file (`model-routing.md`, `docdrift.txt`, `guard-packs.md`) added to `manifest.json`; every manifest path must exist.
- **C0.3 / S2.x** — no new *skills*; only sections added to existing skills (anatomy preserved). New references carry `description:`/`globs:`/`alwaysApply:` frontmatter (S2.13).
- **C0.5 / S3.x** — any bash edits keep `set -euo pipefail`, stay `chmod +x`.
- **S2.19–S2.21** — F6 uses the existing toolset mechanism; `read-only` toolset already exists; validator enforces toolset names resolve.
- **S4.11** — regenerate `checksums.sha256` as the **last** change of the release commit, after the version bump.
- **C0.8** — `bash scripts/validate-toolkit.sh` must print "Toolkit validation passed" before completion.
- Global rule "Fix ONLY the specific issue; minimal scope" — every change is additive at a cited insertion point; no refactor of existing skill behavior beyond the named edits.

## Non-Goals (out of scope)

- Editing `CLAUDE.md` (protected, C0.7; 120-line budget). New env vars are documented in the hook header, `context-engineering`, and `settings.local.json` example — not in `CLAUDE.md`.
- A semantic comment-vs-code verifier or edit-time doc hook (F5 explicitly scoped to a linter pack).
- Read-only enforcement on `spec-driven-development` / `planning-and-task-breakdown` (they legitimately write spec/plan/todo artifacts) — they get a *tool-discipline note*, not a toolset lock.
- Per-criterion failure counters beyond what F3 needs; no rework of the re-arm mechanism itself.
- Changing how `applyTo` references load.
- New stacks or new domains; F7 enriches the existing `domain-finance` and `stack-dotnet` packs only.

## Design

### F1 — Per-phase model routing
- **New reference** `.claude/references/model-routing.md` — canonical per-phase tier policy: `haiku` (scan/discovery), `sonnet` (plan, implement, drift, most reviews), `opus` (compliance review, security, brainstorming, and any batch flagged novel/tricky). Includes the enforced agent-frontmatter rows and the advisory skill rows, with the rationale that skills run on the session model while agents pin theirs.
- **Wiring:** `context-engineering`'s existing Model Routing table gains a one-line pointer to the reference as the source of truth (no table move — minimal). `subagent-implementation` frames its Sonnet/Opus question with the policy default (Sonnet unless the batch is flagged novel → Opus). `planning-and-task-breakdown`, `code-review-and-quality`, and `research-context` each gain a one-line "runs on <tier> per `model-routing.md`" note.

### F2 — Context-budget 60% checkpoint
- **`hooks/context-budget.sh`:** add a checkpoint that, once per session, warns when `estimated_context_tokens` (= `bytes_read / 4`, already tracked) crosses `MTK_CONTEXT_BUDGET_PCT`% of `MTK_CONTEXT_WINDOW_TOKENS`. Message points at the `handoff` skill and labels the figure an estimate (read-bytes floor). Advisory only; never blocks. New `warned_ctxpct` once-flag in session state.
- **Tests:** extend `tests/hooks/test-context-estimator.sh` with a scenario crossing the threshold (fires) and one below (silent), plus env-override of the percentage.
- **Docs:** `handoff` "When To Use" and `context-engineering` budget section note the 60% checkpoint and the two env vars.

### F3 — Loop circuit-breaker + plateau detection
- **`scripts/workflow-artifact.sh`:** new `remediation` subcommand — `remediation <uuid> <trigger> [--score N]` increments `results.remediation.<trigger>.iterations`, records the optional score, sets `results.remediation.<trigger>.plateau=true` when the last two scores did not improve, and prints `ESCALATE` (exit 0, stdout token) when iterations ≥ `MTK_MAX_REMEDIATION_ITERS` (default 3) or plateau is detected. Append-only; idempotent shape.
- **Schema:** `workflow-artifact-schema.md` documents the new `results.remediation` map and the `remediation_escalated` event.
- **Docs:** `orchestration-gates.md` `failure_stop_gate` cites the configurable N and the plateau definition; `code-review-and-quality` iteration cap and `verification-before-completion` reference the breaker.
- **Test:** `tests/hooks/test-remediation-tracker.sh` — iterations below N (no escalate), at N (escalate), plateau on equal scores (escalate).

### F4 — `smoke-boot` evidence channel
- Add `smoke-boot` to the channel taxonomy in `verification-before-completion` (the strongest "real execution surface": the built artifact/service boots and responds live), to the `evidence_channel` enum in `spec-driven-development`, and to the enum list in `workflow-artifact-schema.md`. Text-only.

### F5 — `core/docdrift.txt` linter pack
- **New pack** `hooks/linter-patterns/core/docdrift.txt` (TSV: `RULE_ID  SEVERITY  ERE  RATIONALE  FIX`). Heuristic smells: empty `<see cref=""/>`; absolute doc claims ("always returns" / "never throws" / "guaranteed to") in doc comments; broken local doc links `](./…)` to nonexistent-looking paths; placeholder/`TODO`/`FIXME`/`lorem ipsum` left in shipped doc comments; `@deprecated`/`<deprecated>` with no replacement note. All `warning` severity. Auto-discovered by `pre-commit-linters.sh` (core packs always active) — no script change.
- **Cross-ref:** `ai-failure-modes.md` F12 (docs drift) and F3 (hallucinated APIs) gain a one-line pointer to the pack.
- **Test:** extend a linter test (or add `tests/hooks/test-docdrift-pack.sh`) asserting a known smell matches and clean docs do not.

### F6 — Phase-locked tool limits
- `brainstorming` and `research-context` (pure-read planning skills) gain `required-toolsets: [read-only]` in frontmatter.
- `spec-driven-development` and `planning-and-task-breakdown` gain a **Tool discipline** note: may write *only* spec/plan/todo artifacts under `docs/` and `tasks/`; never source or test code (scope-guard backs this — no source file is in a change_manifest that does not yet exist during planning).
- `skill-authoring.md` S2.20 note extended: pure-read planning/research skills declare `read-only` too (kept within the 120-line rule budget).

### F7 — Stack/domain guard packs
- **`hooks/linter-patterns/domain-finance/patterns.txt`:** add patterns for missing capability/authorization checks on state-changing handlers, direct mutation of audited state without an audit-trail write, and unescaped interpolation into output/log sinks.
- **`hooks/linter-patterns/stack-dotnet/patterns.txt`:** add a small number of security smells (e.g. `HttpClient` per-request `new`, missing `CancellationToken` on async public APIs) — guarded to avoid false positives.
- **New reference** `.claude/references/guard-packs.md` — documents the guard-pack model as a first-class shippable unit: directory layout (`core/`, `stack-*/`, `domain-*/`, `project/`), TSV format, discovery/activation order, severity meanings, and how to author + ship a new pack (manifest entry + test).
- Manifest entries for any new files; `pre-commit-linters.sh` already discovers domain/stack packs (no script change).

### Release (F-rel)
- Bump `version` to `7.15.0` in `manifest.json` (+ `updated: 2026-06-25`) and `plugin.json`.
- Add new files to `manifest.json` `files`.
- `CHANGELOG.md` — new `## [7.15.0] - 2026-06-25` section under Added.
- Regenerate derived indices: `build-references-index.sh`, `build-rule-index.sh`, `build-triggers-index.sh` (new references/rules touched).
- **Last:** `bash scripts/generate-checksums.sh` (S4.11), then `validate-toolkit.sh`.

## Public Contracts (added)
- Reference docs: `model-routing.md`, `guard-packs.md`.
- Env vars: `MTK_CONTEXT_WINDOW_TOKENS`, `MTK_CONTEXT_BUDGET_PCT`, `MTK_MAX_REMEDIATION_ITERS`.
- Evidence channel: `smoke-boot`.
- `workflow-artifact.sh remediation` subcommand + `results.remediation` artifact field + `remediation_escalated` event.
- Linter rule IDs in `core/docdrift.txt`, plus new IDs in `domain-finance` / `stack-dotnet` packs.

## Success Criteria
- **SC1** `bash scripts/validate-toolkit.sh` prints "Toolkit validation passed". Evidence: `script-output`.
- **SC2** `bash scripts/generate-checksums.sh --verify` reports 0 mismatched after regeneration. Evidence: `script-output`.
- **SC3** `manifest.json` and `plugin.json` both read `7.15.0`. Evidence: `cli-stdout`.
- **SC4** `tests/hooks/test-context-estimator.sh` passes including the new 60%-threshold scenarios. Evidence: `test-run`.
- **SC5** `tests/hooks/test-remediation-tracker.sh` passes (escalate at N and on plateau). Evidence: `test-run`.
- **SC6** New docdrift pack: a seeded smell line matches via `pre-commit-linters.sh`/grep; clean docs do not. Evidence: `cli-stdout`.
- **SC7** `bash scripts/build-references-index.sh --check` and `build-rule-index.sh --check` pass (indices in sync). Evidence: `script-output`.

## Assumptions & Risks
- **[VERIFIED]** `read-only` toolset exists (`.claude/toolsets/read-only.yaml`).
- **[VERIFIED]** Linter packs auto-discover `core/*.txt`; no script change for F5.
- **[ASSUMED→accepted]** New doc-drift regexes risk false positives; mitigated by `warning` severity (never blocks commits) and conservative patterns.
- **Risk:** F6 read-only on `research-context` assumes it never writes code — confirmed by its design (returns a cited brief). If a consumer expects it to edit, that breaks; mitigated because it is documented as non-editing.
- **Risk:** line-budget overruns on rule/skill files — each edit is a few lines; will re-check budgets at validate.
