# Plan — v7.19.0 Setup improvements wave

Spec: `docs/specs/2026-07-03-v719-setup-improvements.md` (sidecar `.json` alongside).
Rigor: MAX (8 batches, 28-file manifest, 4 public contracts). Subagent path per `subagent-implementation`; implementer model: Sonnet (engineer-selected "cheaper agents"), orchestrator: Fable.

Batch ordering is dependency-driven: B1 scripts exist before B2 skills reference them; B2's bootstrap/audit rewrites land before B4/B5/B6/B7 touch other sections of the same files (serialized to avoid same-file collisions — no two batches run concurrently when they share a file); B8 last, checksums final.

## B1 — Detection & command-verification scripts

**Files:** `scripts/setup-detect.sh` (new), `tests/hooks/test-setup-detect.sh` (new), `scripts/verify-commands.sh` (new), `tests/hooks/test-verify-commands.sh` (new)

`setup-detect.sh [--json]`: read-only; consolidates the detection logic currently inlined in setup-bootstrap STEP 0 (stack markers incl. maxdepth conventions), package-manager lockfile priority (bun>pnpm>yarn>npm, multi-lockfile warning flag in JSON), RN/Expo markers, STEP 4.5 monorepo signals + package enumeration (workspaces/pnpm-workspace/turbo/nx/rush/lerna globs, csproj≥4, sln≥2, pyproject≥2, conventional dirs, 20-package cap + `packages_skipped` count), and reports **all** detected stacks + `primary_candidate` (single stack → that stack; multiple → empty, skills ask). JSON shape per spec F2. Default (no flag) prints a human table. Exit 0 valid JSON always; exit 2 usage. S3.1/S3.3/S3.4; shellcheck clean. Read `.claude/skills/setup-bootstrap/SKILL.md` STEP 0/4.5 first and port the exact marker logic — do not invent new markers.

`verify-commands.sh`: stdin lines `name<TAB>command` (or `--file <json>`), `--timeout N` (default 300); runs each via `bash -c` under `timeout` from repo root; JSON out `{results:[{name,command,status,detail}]}` where status ∈ verified|failed|skipped (skipped = empty command); `detail` = first stderr/stdout line on failure or `exit <code>` / `timeout`. Portable timeout: prefer `timeout` binary, fall back to perl/bg-kill pattern if absent (macOS without coreutils) — degrade to running without timeout + note in detail, never hard-fail (S3.3 graceful degradation).

Tests: temp-dir fixtures, exit-1-on-failure style (lessons: no subshell counters; no literal backticks in heredocs inside `$()`). setup-detect fixtures: (a) dotnet single (`x.sln`+csproj), (b) ts+pnpm+expo (package.json, pnpm-lock.yaml, app.json, expo dep), (c) pnpm-workspace monorepo (3 packages), (d) mixed ts+dotnet → `stacks` len 2, `primary_candidate` empty. verify-commands fixtures: `true`, `false`, `sleep 3` with `--timeout 1`.

**Checkpoint:** both tests pass; `shellcheck scripts/setup-detect.sh scripts/verify-commands.sh` clean; scripts executable.

## B2 — Skills consume setup-detect + mixed stacks (F2, F11)

**Files:** `.claude/skills/setup-bootstrap/SKILL.md`, `.claude/skills/setup-audit/SKILL.md`, `.claude/references/monorepo-bootstrap.md`

setup-bootstrap: replace STEP 0's detection bash block, the package-manager block, the RN/Expo block, and STEP 4.5's detection bash block with `bash scripts/setup-detect.sh --json` + field references (script path resolved per MTK File Resolution). Keep: the multi-stack `AskUserQuestion` (fed by `stacks`), the go-unsupported stop (`go_detected`), the ambiguous-monorepo `AskUserQuestion` (fed by `monorepo.ambiguous`), the tech-stack-is-a-FILE warnings, the prerequisites check. Add F11: after primary selection, when `stacks` has >1 entry — record the rest for STEP 2.6 (`secondary_stacks`), run the secondary stack's Scan Recipes categories 5 (naming) and 6 (testing) for `conventions.md`, include secondary stacks in STEP 3.6's detected-tool union, and state the workflow-skills-are-primary-only limitation in the STEP 5 report. Net line count of setup-bootstrap must **decrease** (mechanization removes more than F11 adds — target ≥40 lines net reduction for this batch).

setup-audit: STEP 0 detection block → setup-detect call; STEP 2.6 schema block gains `"secondary_stacks": []` with the rules line (lowercase ids, empty when single-stack).

monorepo-bootstrap.md: add per-package rule — when a package's own markers indicate a different stack than primary, the per-package CLAUDE.md names that stack + its build/test commands (from that stack's tech-stack skill) within the 15–30-line budget.

**Boundary:** do not touch STEP 2.5/2.7/3.5a/3.8/STEP 4 CI-offer regions (later batches own those). Do not renumber existing STEPs.
**Checkpoint:** `bash scripts/validate-toolkit.sh` passes; `grep -c 'find . -maxdepth' .claude/skills/setup-bootstrap/SKILL.md` ≤1; bootstrap line count reduced vs HEAD.

## B3 — mtk-setup routing + guidelines fix + converge skill (F1, F4)

**Files:** `.claude/skills/mtk-setup/SKILL.md`, `.claude/skills/setup-converge/SKILL.md` (new), `tests/pressure-tests/setup-converge.md` (new), `.claude/skills/setup-refresh/SKILL.md` (one cross-ref line)

mtk-setup: (a) F1 — rewrite the `--update-guidelines` inline workflow per spec (resolution order, never-write-plugin-cache rule, report line naming the pin file); (b) F4 — add `--converge` to argument-hint, flag table, When To Use, STEP 1 routing (→ setup-converge, mutually exclusive set per spec), Verification checklist; un-bootstrapped guard mirrors `--refresh`.

setup-converge/SKILL.md: STEP-structured per spec F4 + D1 (preconditions; temp-copy verify-claims runs; severity mapping via S1.15 gradient; audit-drift pairing; report format with blocking/flag/note counts; interactive-only todo-append offer via AskUserQuestion; read-only guarantee — writes only under `.claude/.mtk-cache/`). Standard File Resolution preamble; `type: skill`, `user-invocable: false`; frontmatter + at least one `## STEP` heading satisfies S2.2 phase-structure; `## Verification` section required.

Pressure test: scenarios pushing converge to (1) "fix" the doc instead of reporting, (2) auto-append todos non-interactively, (3) claim violations without anchors.

setup-refresh: single line in overview distinguishing refresh (doc follows code) from converge (code judged against doc), pointing at setup-converge.

**Checkpoint:** validate-toolkit passes (new skill anatomy + directory name match); routing table renders all seven modes; `grep -n 'CLAUDE_PLUGIN_ROOT' .claude/skills/mtk-setup/SKILL.md` hits in the update-guidelines section.

## B4 — Adaptive interview + migration ingestion (F5, F6)

**Files:** `.claude/skills/setup-audit/SKILL.md`, `.claude/skills/setup-bootstrap/SKILL.md`

setup-audit: after the confidence-tagging rules, add the `ambiguities.json` emission (STEP 3 addendum): every `[AMBIGUOUS]` line also lands in `.claude/.mtk-cache/ambiguities.json` `{claim, competing_forms:[{form,count}], evidence, doc, anchor}`; regenerated per audit; absent file = no ambiguities.

setup-bootstrap STEP 2.5: adaptive block after the static question set — read ambiguities.json, rank by total hit count, ask ≤3 via AskUserQuestion ("codebase splits 21/31 vs 10/31 — which is the standard?" + explicit "leave ambiguous" option); persist under `resolved_ambiguities` (keyed by anchor) in setup-answers.json; upgrade resolved doc lines to decided conventions with the interview evidence anchor; never re-ask resolved anchors on re-runs; scan-vs-resolution contradictions → Needs review (existing rule referenced, not restated).

setup-bootstrap STEP 2.7 (new): migration ingestion per spec F6 — detection list, marker-exclusion (skip MTK-generated files by their markers), evidence anchor `migrated from <path>`, dedup + contradiction→Needs-review, read-only, boilerplate bar, STEP 5 report line ("Ingested AI configs: <list|none found>").

**Boundary:** STEP 2.5/2.7 and the audit STEP 3 addendum only — no edits to STEP 0/3.5a/3.6/3.8/4/4.5.
**Checkpoint:** validate-toolkit passes; setup-answers.json JSON block in the skill shows `resolved_ambiguities`; report template shows the ingestion line.

## B5 — Verified commands into bootstrap (F7)

**Files:** `.claude/skills/setup-bootstrap/SKILL.md`, `.claude/skills/mtk-setup/SKILL.md`

Bootstrap: Modes section gains `--no-verify-commands`; STEP 3.5a gains "Command verification" subsection per spec D2 (assemble commands from tech-stack skill — build full / test list-variant / format check-mode; pipe to `verify-commands.sh`; stamp comment `<!-- verified: ... (date) -->` in Tech Stack section; `[UNVERIFIED — reason]` annotation; report lines; non-interactive never blocks). mtk-setup: pass `--no-verify-commands` through to bootstrap (flag table + routing row note).

**Boundary:** STEP 3.5a subsection + Modes + mtk-setup flag plumbing only.
**Checkpoint:** validate-toolkit passes; CLAUDE.md template Tech Stack section shows the stamp form.

## B6 — Product context + live references (F8, F9)

**Files:** `.claude/references/product-context.md` (new), `.claude/skills/setup-bootstrap/SKILL.md`, `.claude/references/audit-grounding.md`

product-context.md: both templates (product.md ≤40 lines: purpose/users/key flows/non-goals; decisions.md ADR-lite append-only entry form with SHA-or-interview evidence) + generation rules (sources, no-aspirational bar, verify-claims applies).

Bootstrap: STEP 2.5 question 7 (product purpose, one sentence); new STEP 3.8 (generate product.md, seed decisions.md, both never-overwrite + regen-diff-contract routing, added to File Preservation Policy's known-paths list and STEP 4.8 cache snapshot list); CLAUDE.md template Standards Reference table + report lines. F8: "Rules for Generation" gains the pointer-over-restatement rule + D6 @-import bound; Project Profile template switches version facts to pointer style; audit-grounding.md gains the matching rule for audit docs.

**Boundary:** listed sections only.
**Checkpoint:** validate-toolkit passes; preservation policy names both new files; grep confirms pointer-rule text in both reference files.

## B7 — CI template + evals (F3, F10)

**Files:** `templates/ci/mtk-staleness-check.yml` (new), `.claude/skills/setup-bootstrap/SKILL.md` (STEP 4 offer), `evals/setup-bootstrap/{grader.md,eval-01-clean-bootstrap.md,eval-02-rerun-preservation.md}` (new), `README.md` (CI section)

Workflow YAML per spec D5 (pin toolkit checkout to mtk-version.json version tag; job-summary plan table; fail on exit 1). Match `templates/ci/pr-lint.yml` style. Bootstrap STEP 4: AskUserQuestion offer, never overwrite, non-interactive skip+note. Evals per spec F3 following `evals/fix/` format exactly (frontmatter keys, grader.md sections). README: short "CI staleness gate" subsection under the setup docs.

**Checkpoint:** `python3 -c "import yaml"...` or `ruby -ryaml` unavailable → validate YAML via `python3 -c 'import json,sys;...'`? Use `python3 -c "import yaml"` only if pyyaml present; else structural sanity via grep for required keys (jobs/steps). `bash scripts/run-evals.sh --list` shows setup-bootstrap ×2; validate-toolkit passes.

## B8 — Release chores

**Files:** `.claude/manifest.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `README.md`, `AGENTS.md`, `CHANGELOG.md`, `checksums.sha256`

Manifest: `files` entries (source/target/action/description per S1.2/S1.3) for every new path; version → 7.19.0 in **all three** version files (C0.1; lesson 2026-04-23); `manifest.updated` → 2026-07-03. README: skill-routing rows (`--converge`, `--check` CI template mention) + new-capability bullets (S4.9). AGENTS.md: route to setup-converge (S4.10). CHANGELOG: 7.19.0 entry, one bullet per feature. Then `bash scripts/refresh-derived.sh references triggers`; `bash scripts/validate-toolkit.sh` must print "Toolkit validation passed"; `bash scripts/generate-checksums.sh` as the **final** change (S4.11).

**Checkpoint:** VC1, VC5, VC8, VC9.

## Post-implementation review items

- Phase 3.5 spec-drift check against the sidecar manifest.
- Stage 1 `compliance-reviewer`; Stage 2 `test-reviewer` + `architecture-reviewer` + `silent-failure-hunter` (MAX).
- Verify the v7.14 dogfooding risk didn't recur: no out-of-manifest edits by any batch agent (orchestrator diff check per batch).
