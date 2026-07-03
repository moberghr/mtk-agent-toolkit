# v7.19.0 — Setup improvements wave (11 items)

**Date:** 2026-07-03
**Scope:** feature
**Security impact:** none (no auth/secrets/audited state; F7 executes only commands sourced from the toolkit's own tech-stack skills, timeboxed, never from repo content; all generated writes go through the existing secret-scan gate)
**Baseline area:** setup (mtk-setup / setup-audit / setup-bootstrap / setup-refresh)

## Context

A competitive analysis (2026-07-03) of the setup/bootstrap landscape (spec-kit, BMAD, Kiro steering, Agent OS, Claude Code `/init`, rulesync/Ruler, Copilot, Aider, Repomix) confirmed MTK's claim-verification machinery is unique, and surfaced a ranked borrow-list. A same-session local review found five defects/gaps. This release implements all 11 items: three local fixes (F1–F3), four Tier-2 borrows (F4–F7), and four Tier-3 borrows (F8–F11).

Design decisions locked at spec time (defensible defaults, revisable at the gate):

- **D1 (F4):** converge is read-only. It writes its report to `.claude/.mtk-cache/converge-report.md` and prints a summary; appending remediation items to `tasks/todo.md` is offered via `AskUserQuestion` only in interactive runs, never automatic.
- **D2 (F7):** build commands run fully (timeboxed 300s each); test commands run in list/collect-only mode where the stack supports it, otherwise skipped as `[UNVERIFIED]`; format commands run in check mode. Opt-out flag `--no-verify-commands`. A failing command is never written silently — it gets an `[UNVERIFIED — <one-line reason>]` annotation and a report line.
- **D3 (F9):** product context lives at `.claude/references/product.md`; decision log at `.claude/references/decisions.md` (append-only). Both join the File Preservation Policy's never-overwrite set and route through the regen-diff-contract on re-runs.
- **D4 (F11):** `.claude/tech-stack` stays a single primary stack (every workflow skill reads it — contract preserved). Secondary stacks are recorded in `detected-tools.json` as a new `secondary_stacks` array; bootstrap runs secondary-stack scan recipes for conventions and reference pruning only. Workflow skills remain primary-stack; this is documented as a limitation.
- **D5 (F10):** the CI staleness workflow checks out the toolkit repo pinned to the version in the target repo's `.claude/mtk-version.json` — target repos never vendor MTK scripts.
- **D6 (F8):** live references replace restated facts with backtick path pointers read on demand; `@`-imports are reserved for files under ~50 lines (imports inline content — importing a large manifest would blow the instruction budget the rule exists to protect).

## Features

### F1 — `--update-guidelines` works from marketplace installs

`mtk-setup/SKILL.md` inline workflow currently reads/writes `.claude/manifest.json` with no plugin-root resolution. Fix:

- Resolve the pin source: `PM="${CLAUDE_PLUGIN_ROOT:-.}/.claude/manifest.json"; [ -f "$PM" ] || PM=".claude/mtk-version.json"`.
- **Write rule:** never write into the plugin cache. If the resolved read path is under the plugin root (or `~/.claude/plugins`), the updated pin is written to the repo-local `.claude/mtk-version.json` (`coding-guidelines` block), creating the block if absent. In the toolkit repo itself (manifest present locally, not plugin-prefixed), update `.claude/manifest.json` as today.
- Report line states which file carries the updated pin.

**Acceptance:** skill text contains the resolution + write rule; no path writes into `$CLAUDE_PLUGIN_ROOT`.

### F2 — Mechanized detection: `scripts/setup-detect.sh --json`

New read-only script consolidating every deterministic detection currently inlined in the skills: stack markers (dotnet/python/typescript/go), package manager by lockfile priority (bun > pnpm > yarn > npm), React Native/Expo markers, monorepo classification signals + package enumeration (workspaces globs, csproj/pyproject counts, conventional dirs, 20-package cap), and mixed-stack listing (all stacks found, not just first).

- Output (single JSON object): `{stacks:[...], primary_candidate, package_manager, react_native:{detected,expo}, monorepo:{is_monorepo, ambiguous, signals:[...], packages:[...]}, go_detected}`. Empty arrays over null (matches detected-tools convention). Exit 0 with valid JSON even when nothing is detected; exit 2 on usage error.
- `set -euo pipefail`, shellcheck-clean, coreutils-only (S3.3), honors `.mtkignore` exclusions where applicable.
- `setup-bootstrap` STEP 0 + package-manager + RN/Expo + STEP 4.5 detection bash blocks and `setup-audit` STEP 0 detection block are replaced by "run `setup-detect.sh --json`, read fields" (the AskUserQuestion forks for multi-stack/ambiguous-monorepo remain in the skills). Net effect: setup-bootstrap and setup-audit shrink; no inline detection bash remains for these concerns.
- Test `tests/hooks/test-setup-detect.sh`: fixture repos (dotnet single, ts+pnpm+expo, pnpm-workspace monorepo, mixed ts+dotnet); exit-1-on-failure assertions (no subshell counters).

**Acceptance:** test passes; skills reference the script instead of inline detection; `grep -c 'find . -maxdepth' .claude/skills/setup-bootstrap/SKILL.md` drops to ≤1.

### F3 — Eval coverage for the setup family

New `evals/setup-bootstrap/` (grader.md + 2 scenarios) following the `evals/fix/` format, discovered by `scripts/run-evals.sh`:

- `eval-01-clean-bootstrap.md` (positive): small fixture repo; expected signals — CLAUDE.md ≤120 lines, verify-claims/verify-references run, preservation report printed, no placeholder rows in CODE_INDEX.md.
- `eval-02-rerun-preservation.md` (adversarial): repo with pre-existing hand-edited CLAUDE.md + nested CLAUDE.md + custom rules; expected signals — regen-diff-contract engaged, nothing hand-authored overwritten/deleted, needs-review items itemized.

**Acceptance:** `bash scripts/run-evals.sh --list` shows the new skill group; files follow existing frontmatter (`category`, `skill`, `signal`).

### F4 — Converge mode: `/mtk-setup --converge`

Inverse of `--refresh`: treat `architecture-principles.md` (+ `conventions.md`) as normative and report where the *code* drifted from agreed principles, as reviewable work items.

- New workflow skill `.claude/skills/setup-converge/SKILL.md` (`user-invocable: false`, STEP-structured, standard MTK File Resolution preamble). Routed from `mtk-setup` on `--converge` (mutually exclusive with `--refresh`/`--check`/`--audit`/`--merge`/`--update-guidelines`).
- Mechanism: copy each stamped doc to a temp path; run `scripts/verify-claims.sh <temp-copy>` (existing engine; temp copy keeps converge read-only); parse `.claude/.mtk-cache/weak-claims-<doc>.json`; translate failures into work items graded by the S1.15 severity gradient — `[EXTRACTED]`/`[ENFORCED]` violation → **blocking** item, `[INFERRED≥0.7]` → **flag**, `[INFERRED<0.7]`/`[AMBIGUOUS]` → **note**. Each item cites the principle line, its evidence anchor, and the violating/changed paths (via `scripts/audit-drift-check.sh --json` pairing).
- Output: `.claude/.mtk-cache/converge-report.md` + printed summary table (`N blocking / N flags / N notes`). Interactive runs then offer via `AskUserQuestion`: append items to `tasks/todo.md` / just keep the report. Preconditions: bootstrapped repo + stamped docs, else stop with guidance (mirrors `--refresh` STEP 0).
- Pressure test `tests/pressure-tests/setup-converge.md` (S2.7 — it affects review/verification): adversarial scenarios pushing converge to rewrite docs or auto-append todos.

**Acceptance:** routing table updated; skill exists and passes validator anatomy; converge writes nothing outside `.claude/.mtk-cache/` without an explicit interactive approval.

### F5 — Adaptive interview from `[AMBIGUOUS]` findings

- `setup-audit`: when generating principles/conventions, also emit `.claude/.mtk-cache/ambiguities.json` — machine-readable list of `[AMBIGUOUS]` claims: `{claim, competing_forms:[{form, count}], evidence, doc, anchor}`. Regenerated per audit.
- `setup-bootstrap` STEP 2.5: after the static questions, if `ambiguities.json` exists and is non-empty, ask up to **3** additional `AskUserQuestion` items generated from the top ambiguities (ranked by hit count), phrased as "the codebase splits N/M — which is the standard?" with "leave ambiguous" as an explicit option. Answers persist under a new `resolved_ambiguities` key in `.claude/setup-answers.json` and upgrade the corresponding doc lines from `[AMBIGUOUS]` to a decided convention citing `Evidence: engineer interview — .claude/setup-answers.json (resolved_ambiguities)`.
- Re-run behavior: previously resolved ambiguities are never re-asked (keyed by claim anchor); contradictions between a resolution and a fresh scan follow the existing Needs-review rule (never silently pick a side).

**Acceptance:** both skills updated; setup-answers.json schema gains the key (version stays 1 — additive); interview cap (static 6 + adaptive 3) stated in skill text.

### F6 — Migration-aware bootstrap (ingest existing AI configs)

New `setup-bootstrap` STEP 2.7 "Ingest existing AI-assistant configs": detect and read `.cursorrules`, `.cursor/rules/*.mdc` (non-MTK-marker), `.github/copilot-instructions.md` (non-marker), `.windsurfrules`, `.clinerules`, `GEMINI.md` (non-marker), pre-existing root `AGENTS.md` (non-marker), and pre-existing root `CLAUDE.md` body.

- Extract rule/convention candidates as interview-grade input: each adopted rule carries `Evidence: migrated from <path>` (real path — resolves under verify-claims).
- Dedup against scan findings; where an ingested rule contradicts a scan finding, emit a Needs-review item (same contract as interview conflicts). Never copy marketing prose or generic boilerplate — same "no aspirational rules" bar as the rest of generation.
- Ingestion is read-only over those files; MTK never modifies or deletes them (File Preservation Policy unchanged).

**Acceptance:** STEP 2.7 present with detection list, evidence-anchor rule, conflict rule; STEP 5 report lists ingested sources or "none found".

### F7 — Verified-commands stamp

- New script `scripts/verify-commands.sh`: reads command entries as `name<TAB>command` lines on stdin (or `--json` file), runs each under `timeout` (default 300s, `--timeout N` override), captures exit code + first stderr line, emits JSON `{results:[{name, command, status: verified|failed|skipped, detail}]}`. Never modifies the repo; runs from repo root. Test `tests/hooks/test-verify-commands.sh` (true/false/timeout fixtures).
- `setup-bootstrap` STEP 3.5a extension ("Command verification"): before writing CLAUDE.md, assemble the build/test/format commands it is about to publish (from the tech-stack skill per D2 — build full, test list-only variant from the stack skill's `## Build & Test Commands` where available, format check-mode) and run them through `verify-commands.sh`. Verified commands get a `<!-- verified: build ✓ test ✓ format ✓ (YYYY-MM-DD) -->` comment in the CLAUDE.md Tech Stack section; failures are annotated `[UNVERIFIED — <reason>]` and surfaced in the STEP 5 report. `--no-verify-commands` skips the step (noted in report). Non-interactive runs never block on a failing command — annotate and continue.

**Acceptance:** script + test pass shellcheck/execution; skill step present; a failing command can never appear in CLAUDE.md without the `[UNVERIFIED]` annotation.

### F8 — Live file references over restated facts

Generation-rule updates (setup-bootstrap "Rules for Generation" + template guidance, and `.claude/references/audit-grounding.md`):

- Facts that live in a canonical machine-readable file (framework/runtime versions, dependency lists, package-manager choice) are **pointed at** (`see \`package.json\``, `see \`Directory.Packages.props\``) rather than restated, except where the instruction-budget already requires the value inline (build/test command lines stay).
- `@`-import form only for files ≤ ~50 lines (D6). Never `@`-import manifests or lockfiles.
- Note added to `setup-refresh` docs: pointer-style facts reduce the dependency-rescan staleness surface (plan-script row 3 checks remaining restated names as before).

**Acceptance:** rule text present in both files; CLAUDE.md template's Project Profile section demonstrates pointer style for version facts.

### F9 — Product-context artifacts: `product.md` + `decisions.md`

- New reference `.claude/references/product-context.md` (in the toolkit) holding both templates + generation rules, read on demand by bootstrap (progressive disclosure — keeps bootstrap lean).
- New `setup-bootstrap` step (STEP 3.8, after generation, before verification): generate `.claude/references/product.md` (purpose, users, key flows, non-goals; ≤40 lines; sources: README/docs scan + one new interview question "one sentence: what does this product do and for whom?" folded into STEP 2.5 as question 7) and seed `.claude/references/decisions.md` (ADR-lite, append-only; seeded from detectable history — framework migrations, major version bumps in git log — plus interview `hard_nevers`/`invisible_conventions` rationale where given).
- Both: never overwritten if present (File Preservation Policy set + regen-diff-contract on re-runs); listed in the CLAUDE.md Standards Reference table; claims carry evidence anchors like every generated doc (verify-claims runs over product.md; decisions entries cite commit SHAs or the interview file).

**Acceptance:** reference exists; bootstrap step present; preservation policy lists both files; CLAUDE.md template table updated.

### F10 — CI staleness gate template

- New `templates/ci/mtk-staleness-check.yml`: GitHub Actions workflow — checkout target repo; parse `.claude/mtk-version.json` for the installed MTK version; checkout `moberghr/mtk-agent-toolkit` at that tag into a tool dir; run `bash <tooldir>/scripts/setup-refresh-plan.sh --check` from the target repo root; fail the job on exit 1 with the plan table in the job summary (D5).
- `setup-bootstrap` STEP 4 addition: offer to install the template to `.github/workflows/mtk-staleness-check.yml` via `AskUserQuestion` (never overwrite an existing file; skip silently under `--non-interactive` with a report note). README documents the workflow.

**Acceptance:** template exists and is valid YAML; bootstrap offer present; README section added.

### F11 — Mixed-stack support (minimal viable, D4)

- `setup-detect.sh` (F2) reports all stacks; `setup-bootstrap` STEP 0 keeps the primary-stack AskUserQuestion but now **records the non-primary stacks**: `setup-audit` STEP 2.6 writes them to `detected-tools.json` as `secondary_stacks: []` (empty when single-stack).
- Bootstrap additionally: runs the secondary stack's `## Scan Recipes` naming/testing categories for `conventions.md` coverage; includes secondary-stack reference files in STEP 3.6 pruning (union of detected tools across stacks); monorepo per-package CLAUDE.md notes the package's own stack when it differs from primary (rule added to `.claude/references/monorepo-bootstrap.md`).
- Documented limitation (in both skills): workflow skills (`implement`/`fix`) still operate on the primary stack only.

**Acceptance:** `secondary_stacks` in the detected-tools schema block; bootstrap/audit text updated; monorepo reference rule added.

## Out of scope

- Multi-stack workflow-skill execution (implement/fix switching stacks per file) — documented limitation only.
- Converge auto-remediation (writing fixes) — converge reports; humans decide.
- Ingestion `import` of MCP configs / commands from other tools (rulesync parity) — rules/instructions only.
- New tech stacks (go/java/rust) — detection reports `go_detected` but bootstrap still stops.
- Rewriting `verify-claims.sh` — converge reuses it as-is on temp copies.

## Test manifest

- `tests/hooks/test-setup-detect.sh` — new (fixtures: dotnet, ts+pnpm+expo, monorepo, mixed).
- `tests/hooks/test-verify-commands.sh` — new (pass/fail/timeout).
- `tests/pressure-tests/setup-converge.md` — new (S2.7).
- `evals/setup-bootstrap/` — new grader + 2 scenarios (F3).
- `bash scripts/validate-toolkit.sh` — must pass (anatomy of new skill, manifest sync, version triple).
- `shellcheck` clean on both new scripts.

## Implementation batches

- **B1 — Detection & command-verification scripts:** `scripts/setup-detect.sh`, `tests/hooks/test-setup-detect.sh`, `scripts/verify-commands.sh`, `tests/hooks/test-verify-commands.sh` (F2, F7 mechanics).
- **B2 — Skills consume setup-detect + mixed stacks:** `setup-bootstrap` STEP 0/4.5 rewrite, `setup-audit` STEP 0 rewrite + STEP 2.6 `secondary_stacks`, `monorepo-bootstrap.md` rule (F2, F11).
- **B3 — mtk-setup routing, guidelines fix, converge skill:** `mtk-setup/SKILL.md` (F1 + `--converge` flag rows/routing), new `setup-converge/SKILL.md`, `tests/pressure-tests/setup-converge.md` (F1, F4).
- **B4 — Adaptive interview + migration ingestion:** `setup-audit` ambiguities.json emit; `setup-bootstrap` STEP 2.5 adaptive block + STEP 2.7 ingestion (F5, F6).
- **B5 — Verified commands into bootstrap:** STEP 3.5a extension, `--no-verify-commands` flag plumbing (mtk-setup passthrough + bootstrap Modes), report lines (F7).
- **B6 — Product context + live references:** `.claude/references/product-context.md`, bootstrap STEP 3.8 + interview Q7 + preservation-set updates, F8 rule edits in bootstrap + `audit-grounding.md` (F8, F9).
- **B7 — CI template + evals:** `templates/ci/mtk-staleness-check.yml`, bootstrap STEP 4 offer, `evals/setup-bootstrap/{grader.md,eval-01-clean-bootstrap.md,eval-02-rerun-preservation.md}`, README CI section (F3, F10).
- **B8 — Release chores:** manifest `files` entries for every new path, version bump **7.19.0 in all three** (`manifest.json`, `plugin.json`, `marketplace.json` — C0.1/S1.4, lesson 2026-04-23), `manifest.updated`, README + AGENTS.md routing, CHANGELOG, `refresh-derived.sh` index rebuild, `validate-toolkit.sh`, `generate-checksums.sh` **last** (S4.11).

## Assumptions & risks

- [VERIFIED:scripts/verify-claims.sh] — parses tagged claims, resolves anchors, writes weak-claims JSON; converge reuses on temp copies.
- [VERIFIED:scripts/audit-drift-check.sh] — `--json` pairs changed paths with claim anchors.
- [VERIFIED:evals/fix/] — eval format: frontmatter category/skill/signal, grader.md per dir; run-evals.sh discovers by dir.
- [VERIFIED:templates/ci/] — existing CI template location.
- [VERIFIED:.claude/references/regen-diff-contract.md] — extension point for D3's preservation routing.
- Risk: setup-bootstrap edits touch many sections across batches B2/B4/B5/B6 — batches are ordered and each subagent gets exact section anchors to avoid collisions (v7.14 dogfooding lesson: big doc refactors by subagents drift). Orchestrator drift-checks after each batch.
- Risk: F7 runtime — build execution can be slow on real repos; mitigated by 300s timeout, list-only tests, `--no-verify-commands`.
