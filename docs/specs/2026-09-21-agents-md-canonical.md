# Spec — AGENTS.md becomes the canonical constitution (WS1 of the multi-harness migration)

**Date:** 2026-09-21 · **Slug:** `agents-md-canonical` · **Plan (supplied, adopted):** `docs/plans/2026-09-21-multi-harness-migration.md` §WS1 · **Scope:** breaking-change (skill renames + bootstrap output shape) · **Security impact:** none

## Summary

Claude Code v2.1.277 reads `AGENTS.md` natively, and every other harness the team uses already
reads it. Today MTK's constitution lives in `CLAUDE.md` (toolkit repo and every bootstrapped
repo) and `AGENTS.md` is a secondary, budget-capped summary. This spec inverts that: `AGENTS.md`
becomes the canonical, hand/LLM-authored constitution; `CLAUDE.md` becomes a shim that imports
it (`@AGENTS.md`) plus a short *Claude Code only* section; every MTK script that mines the
constitution (digest, context pack, rule-enforcement map, repo-health, doctor, refresh plan,
generators) resolves `AGENTS.md` first and keeps working on legacy `CLAUDE.md`-only repos; the
two `claude-md-*` skills become `instructions-*`; and the Copilot/Windsurf/Cline mirrors shrink
to marker + pointer + Critical Rules. Beneficiary: an engineer on Codex, Cursor, OpenCode or
Copilot gets the same rules Claude Code gets, from one file, with no per-tool copy to drift.

## Constitution Check

| Id | How the design satisfies it |
|---|---|
| C0.2 | Every added/renamed file is a manifest edit in the same batch (B4/B5/B7); `validate-toolkit.sh` is the checkpoint of every batch. |
| C0.3 | Renamed skills keep the workflow anatomy; directory name == `name:`; router route-table rows updated. |
| C0.4 | Renamed skills and the new reference carry frontmatter (reference: `description`/`globs`/`alwaysApply`). |
| C0.6 | No secrets; no user-specific paths. |
| C0.7 | **Exception, stated:** this run edits the toolkit's own `CLAUDE.md` (dev checkout, not an `update` over a target repo). The rule's target-repo protection is unchanged — `AGENTS.md` and `CLAUDE.md` both stay in `manifest.protected`. |
| C0.8 | `bash scripts/validate-toolkit.sh` gates every batch and the completion claim. |
| S1.5 | Protected list unchanged; bootstrap's never-overwrite policy extends to the shim. |
| S1.17 | No path-strip logic added. |
| S2.2/S2.3 | Renamed skills keep required sections; `name:` matches directory. |
| S3.1/S3.3/S3.17 | Script edits keep `set -euo pipefail`, coreutils-only, no early-exit pipe consumers. |
| S4.10 | `AGENTS.md` routes every skill it did before (the routing table stays; detail moves to a reference). |
| C0.1/S4.6 | Not touched — no version bump in this run (the 8.0.0 bump belongs to the train's last release). |

## Architecture and design

**Resolution rule (one function, reused).** `constitution_file()` — `AGENTS.md` when it exists and
either `CLAUDE.md` is absent or `CLAUDE.md` contains a line matching `^@AGENTS\.md` (a shim);
otherwise `CLAUDE.md`. Legacy repos (constitution in `CLAUDE.md`, no `AGENTS.md` or a
generator-marked one) resolve exactly as today. Implemented in bash in each standalone script
(`constitution-digest.sh`, `generate-agents-md.sh`, `generate-tool-configs.sh`,
`rule-enforcement-map.sh`, `repo-health-score.sh`, `mtk-doctor.sh`, `setup-refresh-plan.sh`) and
in python in `build-context-pack.sh` — the scripts are deliberately standalone (they ship to
target repos individually), matching the existing duplicated-helper convention noted in
`generate-tool-configs.sh:14-22`.

**Toolkit repo shape.** `AGENTS.md` = today's `CLAUDE.md` body (Skill Routing table, Build & Test,
Project Profile, Critical Rules, Standards Reference) + a compact `## Agent Routing` (entry-point
table, two-stage review in prose, tech-stack loading, routing rules, self-escalation). The
Mermaid tree, workflow-composition table, review-output schema, eval pipeline, path-scoped
loading and model-invoked list move verbatim to `.claude/references/agent-routing-guide.md`,
pointed at from `AGENTS.md`. Budget: `AGENTS.md` ≤ 200 lines (new validator check); `CLAUDE.md`
≤ 20 lines: heading, `@AGENTS.md`, one plain-text pointer line (for a harness that reads the file
literally), `## Claude Code only` (`.claude/rules/` auto-load note, `instructionFiles` mode note,
plugin-manager update note).

**Target-repo shape (bootstrap).** STEP 3 authors `AGENTS.md` from the renamed template
`root-agents-md-template.md` (same skeleton, same 60–80/120 budget, same `<!-- mtk-setup` footer)
and writes the `CLAUDE.md` shim from a second template block in the same reference. Merge mode
gains an **inversion migration** rule: an existing constitution-shaped `CLAUDE.md` (no `@AGENTS.md`
line) with no hand-curated `AGENTS.md` is *proposed* for inversion through the regen-diff contract
(move body → `AGENTS.md`, replace `CLAUDE.md` with the shim) — never silently. A hand-curated
`AGENTS.md` that already exists is preserved untouched and the shim is written only if `CLAUDE.md`
is absent; otherwise the report names the pair for the engineer.

**Generators.** `generate-agents-md.sh` keeps its role (references summarizer, marker-guarded);
when `constitution_file()` is `AGENTS.md` it prints a one-line note and exits 0 without writing
(`--force` still overwrites). Its "(from CLAUDE.md)" heading names the actual source.
`generate-tool-configs.sh`: `copilot`, `windsurf`, `cline` emit **pointer mode** — title, marker,
`Canonical instructions: read \`AGENTS.md\`` line, `## Critical Rules` verbatim from
`constitution_file()`; `gemini` and `cursor-rules` unchanged (WS0 #4 — Gemini `@import` — is not
verified; `.mdc` glob scoping adds value `AGENTS.md` cannot express).

**Skill renames.** `git mv` both skill directories and both pressure tests; `name:`, description,
`trigger:` and bodies target `AGENTS.md` first, then shims (`CLAUDE.md`, `GEMINI.md`), then nested
per-package files; `.claude.local.md` stays the personal companion. Router rows keep the
`claude.md` keywords as synonyms and add `agents.md` / `instructions` phrases; row order in the
table is unchanged (`run-fixtures.sh` enforces precedence). The Routing Decision Graph (dot
digraph — nodes `cma`/`cmcap`, diamonds `cmd`/`cmc`) is renamed in the same batch so graph and table
keep agreeing. Because no batch after B4 re-touches `AGENTS.md`, B4 writes the **post-rename** skill
ids into the routing tables.

**Named patterns to mirror.** Marker guard: `scripts/generate-tool-configs.sh:58-68`. Standalone
duplicated helper: `scripts/generate-agents-md.sh:127-135` / `generate-tool-configs.sh:110`.
Reference frontmatter: `.claude/references/mtk-file-resolution.md:1-5`. Test shape:
`tests/hooks/test-constitution-digest.sh` (mktemp repo per case, `fail`/`ok`).

**No new dependencies** (coreutils/grep/sed/awk/python3 only, S3.3). **No data model** — files on disk are the only state.

## Rejected alternatives

- *`generate-agents-md.sh` as the constitution generator* (plan wording). It is a deterministic
  summarizer that cannot carry interview-derived rules and refuses to overwrite unmarked files;
  the constitution is authored by STEP 3 from a template today. Kept the template as the
  generator, script as legacy. `[VERIFIED:scripts/generate-agents-md.sh:14-70]`
- *No `CLAUDE.md` at all in target repos.* Fails on Bedrock/Vertex/telemetry-off and on any
  engineer with a `CLAUDE.local.md` (default mode then ignores `AGENTS.md`). Shim keeps every mode
  working. `[CITED:https://code.claude.com/docs/en/memory#agents-md]`
- *Rename via wrapper skills that alias the old names.* Two more skills in the description budget
  for a routing benefit the router synonyms already give.
- *Gemini pointer mode now.* Unverified whether `GEMINI.md` `@./AGENTS.md` imports; left full.

## Security and compliance impact

`none`. Markdown, bash and one python-in-bash change; no auth, secrets, PII, payments or IAM
surface. The shim adds no import that is not already the documented Claude Code mechanism.

## Change manifest

| Path | Action | Purpose | Mechanical |
|---|---|---|---|
| `scripts/constitution-digest.sh` | modify | `constitution_file()` resolution, source named in heading | no |
| `tests/hooks/test-constitution-digest.sh` | modify | cases: AGENTS.md-only, shim+AGENTS.md, legacy CLAUDE.md-only | no |
| `scripts/build-context-pack.sh` | modify | Critical Rules + TOC from `constitution_file()` | no |
| `scripts/rule-enforcement-map.sh` | modify | scan `AGENTS.md` alongside `CLAUDE.md` | no |
| `scripts/repo-health-score.sh` | modify | asset 1 = instructions file present (`AGENTS.md` or `CLAUDE.md`) | no |
| `scripts/mtk-doctor.sh` | modify | always-on estimate includes `AGENTS.md`; WARN when both exist and `CLAUDE.md` lacks `@AGENTS.md` | no |
| `scripts/setup-refresh-plan.sh` | modify | row 5: `mtk-setup`-stamped `AGENTS.md` → footer version-drift check, not regenerate-diff; row 6 verifies `AGENTS.md` too | no |
| `scripts/mtk-savings.sh` | modify | always-on floor sums `AGENTS.md` + `CLAUDE.md` (shim) | no |
| `scripts/generate-agents-md.sh` | modify | shim detection → note + exit 0; heading names source | no |
| `scripts/generate-tool-configs.sh` | modify | `constitution_file()`; pointer mode for copilot/windsurf/cline | no |
| `tests/hooks/test-generate-agents-md.sh` | modify | case (f): shim present → nothing written, exit 0 | no |
| `tests/hooks/test-generate-tool-configs.sh` | create | pointer mode, gemini unchanged, guard intact | no |
| `AGENTS.md` | modify | canonical constitution + compact routing | no |
| `CLAUDE.md` | modify | `@AGENTS.md` shim + Claude Code only section | no |
| `.claude/references/agent-routing-guide.md` | create | detailed routing content moved out of `AGENTS.md` | no |
| `scripts/validate-toolkit.sh` | modify | `CLAUDE.md` must contain `@AGENTS.md`; `AGENTS.md` ≤ 200 lines | no |
| `.claude/skills/instructions-audit/SKILL.md` | create | `git mv` from `claude-md-audit` + retarget to `AGENTS.md`-first | no |
| `.claude/skills/instructions-capture/SKILL.md` | create | `git mv` from `claude-md-capture` + retarget | no |
| `tests/pressure-tests/instructions-audit-pressure.md` | create | `git mv` + name references | yes |
| `tests/pressure-tests/instructions-capture-pressure.md` | create | `git mv` + name references | yes |
| `scripts/growth-gate.sh` | modify | comment names the renamed skill | yes |
| `.claude/skills/mtk/SKILL.md` | modify | route-table rows, disambiguation rows → new skill paths, synonyms kept | no |
| `docs/how-it-works.data.json` | modify | two entries renamed (id, name, key_files, invocation text) | yes |
| `hooks/capture-learnings.sh` | modify | promotion nudge names `AGENTS.md` | yes |
| `.claude/skills/setup-bootstrap/SKILL.md` | modify | STEP 3 authors `AGENTS.md` + shim; inversion migration rule; budgets/invariants/verify lists | no |
| `.claude/references/root-agents-md-template.md` | create | `git mv` from `root-claude-md-template.md`; `AGENTS.md` skeleton + shim template | no |
| `.claude/references/bootstrap-supporting-files.md` | modify | Cross-Agent section: authored `AGENTS.md`, legacy generator, pointer-mode mirrors | no |
| `.claude/references/bootstrap-report.md` | modify | report lines for `AGENTS.md`/shim; `instructions-capture` | yes |
| `.claude/manifest.json` | modify | renamed keys, new reference, descriptions | yes |
| `CHANGELOG.md` | modify | Unreleased entry for WS1 | yes |
| `.claude/skills/setup-refresh/SKILL.md` | modify | *(added at review re-approval)* STEP 3 routes a footer-stale mtk-stamped `AGENTS.md` through the regen-diff proposal | no |
| `tests/hooks/test-setup-refresh-plan.sh`, `test-rule-enforcement-map.sh`, `test-build-context-pack.sh`, `test-mtk-doctor-*.sh` | modify | *(added at review re-approval)* AGENTS.md-only / shim / legacy cases | no |

Derived (regenerated, not manifest entries): `docs/how-it-works.html` (`python3 docs/build-how-it-works.py`), `.claude/references.index` (`bash scripts/build-references-index.sh`, gitignored).

Deleted by `git mv` (no separate entry): `.claude/skills/claude-md-audit/SKILL.md`, `.claude/skills/claude-md-capture/SKILL.md`, `tests/pressure-tests/claude-md-*-pressure.md`, `.claude/references/root-claude-md-template.md`.

## Public contracts (all `internal-tooling`)

| Kind | Signature | Change |
|---|---|---|
| cli-flag | `generate-tool-configs.sh --format copilot\|windsurf\|cline` output shape | modified (pointer mode) |
| method | `constitution-digest.sh` source resolution (`AGENTS.md` first) | modified |
| method | `generate-agents-md.sh` behaviour when `CLAUDE.md` is a shim | modified |
| method | `setup-bootstrap` STEP 3 output: `AGENTS.md` constitution + `CLAUDE.md` shim | modified |
| method | skill names `instructions-audit` / `instructions-capture` (were `claude-md-*`) | modified |
| method | `validate-toolkit.sh` new checks (shim import, `AGENTS.md` cap) | modified |
| method | `repo-health-score.sh` asset 1 label/logic | modified |
| method | reference path `.claude/references/root-agents-md-template.md` | modified |

## Test manifest

| Test | Covers |
|---|---|
| `tests/hooks/test-constitution-digest.sh` | SC2, SC3 |
| `tests/hooks/test-generate-agents-md.sh` | SC4 |
| `tests/hooks/test-generate-tool-configs.sh` | SC5 |
| `scripts/run-fixtures.sh` | SC6 |
| `scripts/validate-toolkit.sh` | SC1, SC7 |

SC8–SC14 are script-output / smoke-boot criteria verified by running the named command in the
final verification pass (todo → *After all batches*); they have no `test_manifest` row by design.

Waiver: skill-body edits (router, bootstrap, renamed skills) have no executable unit test by
design — this repo's test approach is `validate-toolkit.sh` + manual pressure tests
(`CLAUDE.md` Build & Test). The renamed pressure tests are the behavioural coverage; SC13/SC14
are the live-harness smoke.

## Success criteria

| Id | Criterion | Verification | Channel | Observable |
|---|---|---|---|---|
| SC1 | Toolkit validates with the new checks live | `bash scripts/validate-toolkit.sh` | script-output | last line is `Toolkit validation passed`, and a fixture `CLAUDE.md` without `@AGENTS.md` makes it fail |
| SC2 | Digest reads the constitution from `AGENTS.md` in this repo | `bash scripts/constitution-digest.sh` | cli-stdout | contains `## Critical Rules (AGENTS.md)` and `Totals: 8 Critical Rules` |
| SC3 | Digest resolution covered | `bash tests/hooks/test-constitution-digest.sh` | test-run | exit 0; output contains `AGENTS.md-first` PASS lines for the three new cases |
| SC4 | Generator honours the shim | `bash tests/hooks/test-generate-agents-md.sh` | test-run | exit 0; case (f) PASS: no `AGENTS.generated.md`, exit 0, note printed |
| SC5 | Pointer-mode mirrors | `bash tests/hooks/test-generate-tool-configs.sh` | test-run | exit 0; copilot/windsurf/cline ≤ 40 lines each with marker + `AGENTS.md` pointer + `C0.1`; `GEMINI.md` contains `## Security Requirements`; hand-curated refusal PASS |
| SC6 | Router still parses and precedence holds after rename | `bash scripts/run-fixtures.sh` | test-run | exit 0 |
| SC7 | No stale references to the old skill names (paths **or** bare mentions) | `grep -rnE 'claude-md-(audit\|capture)' --exclude-dir=.git --exclude-dir=docs --exclude=CHANGELOG.md --exclude=checksums.sha256 .` | cli-stdout | zero lines |
| SC8 | Repo-health accepts `AGENTS.md` as the instructions file | `bash scripts/repo-health-score.sh` | cli-stdout | asset 1 row reads `pass` in this repo |
| SC9 | Doctor is clean and counts `AGENTS.md` | `bash scripts/mtk-doctor.sh` | cli-stdout | no `FAIL` row; always-on line mentions `AGENTS.md` |
| SC10 | Refresh plan does not flag the hand-curated `AGENTS.md` | `bash scripts/setup-refresh-plan.sh --json` | cli-stdout | the `AGENTS.md` row status is not `stale` |
| SC11 | Docs page regenerates with the new ids | `python3 docs/build-how-it-works.py && grep -c 'instructions-audit' docs/how-it-works.html` | script-output | exit 0 and count ≥ 1 |
| SC12 | New reference indexes | `bash scripts/build-references-index.sh` | script-output | exit 0 and `grep -c agent-routing-guide .claude/references.index` ≥ 1 |
| SC13 | Claude Code loads the constitution through the shim | `claude -p "List the ids of the Critical Rules in this repo's instructions, nothing else"` | smoke-boot | output contains `C0.8` |
| SC14 | Codex loads the constitution from `AGENTS.md` | `codex exec -s read-only "List the ids of the Critical Rules in this repo's instructions, nothing else" </dev/null` | smoke-boot | output contains `C0.8` |

## Requirements

### Ubiquitous
- The system shall resolve the constitution file as `AGENTS.md` when `AGENTS.md` exists and `CLAUDE.md` is absent or contains a line matching `^@AGENTS\.md`, and as `CLAUDE.md` otherwise.
- The system shall keep `AGENTS.md` and `CLAUDE.md` in `manifest.protected`.

### Event-driven
- When `constitution-digest.sh` runs in a repo whose `CLAUDE.md` is a shim, the system shall emit the Critical Rules from `AGENTS.md` under a heading naming `AGENTS.md`.
- When `generate-agents-md.sh` runs in a repo whose `CLAUDE.md` is a shim and `--force` is absent, the system shall print a one-line note and exit 0 without writing any file.
- When `generate-tool-configs.sh` runs with `--format copilot`, `windsurf` or `cline`, the system shall write a file of at most 40 lines containing the auto-generated marker, a line naming `AGENTS.md` as the canonical instructions, and the `## Critical Rules` body of the resolved constitution.
- When `setup-bootstrap` STEP 3 runs in a repo with neither `AGENTS.md` nor `CLAUDE.md`, the system shall write `AGENTS.md` from `root-agents-md-template.md` and a `CLAUDE.md` shim containing `@AGENTS.md`.
- When `setup-bootstrap` STEP 3 runs in a repo whose `CLAUDE.md` holds a `## Critical Rules` section and has no `@AGENTS.md` line, the system shall propose the inversion as a regen-diff-contract proposal and shall not rewrite either file without approval.
- When `/mtk` receives `audit agents.md`, `audit claude.md`, `instructions audit` or `memory rot`, the system shall route to `.claude/skills/instructions-audit/SKILL.md`.
- When `/mtk` receives `capture instructions`, `update claude.md`, `update agents.md` or `save what we learned`, the system shall route to `.claude/skills/instructions-capture/SKILL.md`.
- When `validate-toolkit.sh` runs and `CLAUDE.md` exists without a line matching `^@AGENTS\.md`, the system shall fail with a message naming the shim requirement.
- When `validate-toolkit.sh` runs and `AGENTS.md` exceeds 200 lines, the system shall fail with a message naming the line count.

### State-driven
- While `CLAUDE.md` is a shim, `build-context-pack.sh` shall take the Critical Rules body and heading TOC from `AGENTS.md`.
- While `AGENTS.md` carries an `<!-- mtk-setup` footer, `setup-refresh-plan.sh` shall classify it by footer version drift and shall not invoke `generate-agents-md.sh` against it.

### Unwanted behaviours
- If `AGENTS.md` exists without the auto-generated marker, then `setup-refresh-plan.sh` shall not report it as `stale` on the regenerate-diff basis.
- If both `AGENTS.md` and `CLAUDE.md` exist and `CLAUDE.md` lacks `@AGENTS.md`, then `mtk-doctor.sh` shall report a WARN row naming the default `claude-md-or-agents-md` mode.
- If a repo has only a legacy `CLAUDE.md` constitution, then every modified script shall produce the same output it produces today.

## Implementation batches

See `## Plan` in the sidecar (`plan.batches`) and `tasks/todo.md`. Seven batches, wave schedule
`W0: B1 B2 B3 · W1: B4 · W2: B5 · W3: B6 B7`, plus review batch R2 (scope re-approved 2026-09-21 after Phase 4 iteration 1).

## Risks and assumptions

**Assumptions**
- `[VERIFIED:scripts/generate-agents-md.sh:14-70]` The generator summarizes references and refuses unmarked targets; it is not, and cannot become, the interview-driven constitution author — STEP 3 + template is.
- `[CITED:https://code.claude.com/docs/en/memory#agents-md]` Default mode ignores `AGENTS.md` when any `CLAUDE.md`/`CLAUDE.local.md` is in cwd or above; `@AGENTS.md` import is read in every mode; `.claude/rules/` load alongside; Bedrock/Vertex need the import.
- `[VERIFIED:docs/harness-support-matrix.md]` Codex reads project `AGENTS.md` (docs) and `~/.codex/AGENTS.md` (observed); OpenCode reads `AGENTS.md` (docs); neither reads `.claude/rules/`.
- `[VERIFIED:scripts/run-fixtures.sh:194]` Fixture precedence runs against the live route table, so row order must not change.
- `[VERIFIED:.gitignore]` `docs/plans/` is tracked here (the plan file is untracked-new, not ignored); `.mtk/` is gitignored.

**Risks**
- `dirty-worktree`: `CHANGELOG.md` (in-manifest, modified by this session's WS0 entry), `docs/harness-support-matrix.md` and `docs/plans/2026-09-21-multi-harness-migration.md` (untracked, out of manifest). Mitigation: commit the WS0 docs as a `docs:` commit on the new branch before Phase 3 (gate question 2), so the Phase 2.9 collision set is empty.
- Skills that instruct "Read `CLAUDE.md`" (context-engineering, spec, prior-work-check, ~40 sites) will, on a non-Claude harness, read the shim. Mitigation: the shim's plain-text pointer line; the wording sweep is WS4 (`harness-primitives.md`), out of scope here.
- The toolkit's `AGENTS.md` grows from 167 to ~150–190 lines; compliance degrades past ~150 instructions. Mitigation: routing detail moves to the reference; validator cap 200; Critical Rules stay at 8.
- `run-fixtures.sh` may pin route-table text; renaming targets could break a fixture. Mitigation: SC6 in B6's checkpoint.
- Monorepo per-package `CLAUDE.md` files (STEP 4.5, `monorepo-bootstrap.md`) keep saying "root `CLAUDE.md`" — correct for Claude Code via the shim, misleading prose elsewhere; wording sweep is WS4/WS7 (plan-gap ADVISORY, accepted).
- Rollback: one branch, no version bump, no data — `git revert` of the merge restores both files and the old skill names; target repos are untouched until they re-run `/mtk-setup`.

## Not-Proved ledger (declared now, filled at verification)

- Cursor/Gemini/Copilot reading of the new `AGENTS.md`: not exercised (harnesses not installed here).
- Bootstrap STEP 3 on a real target repo: prose change only in this run; exercised at the next dogfood bootstrap, not by a test here.
- `GEMINI.md` import behaviour: untested; Gemini output deliberately unchanged.

## Prior Work Check

**Query 1 — search_prior_work.** `grep -rn -iE 'instructions-audit|instructions-capture|agent-routing-guide|@AGENTS\.md'` over the tree (excluding this run's docs): no matches — nothing to reuse. `generate-agents-md.sh` and `generate-tool-configs.sh` already own the marker-guard and Critical-Rules extraction this spec extends (reuse, not re-implement).

**Query 2 — get_constraints.** `block`: S3.17 (no early-exit pipe consumers — the shim grep uses `grep -q … <(head …)` or a `case` on a captured variable). `flag`: lesson *"A lesson recorded only in tasks/lessons.md doesn't stop the mistake … needs to live in the enforced rule text"* — the shim requirement is enforced by `validate-toolkit.sh`, not by prose alone. `note`: L-2026-08-13-001 (mutating gh/git never piped) applies to the branch/commit step.

**Query 3 — get_risk_profile.** `change_manifest` paths: `scripts/**`, `tests/**`, `.claude/**`, root markdown — `shared` (utilities used by every skill) and `isolated`; no `regulated`, no `boundary`. `security_impact: none` matches. Phase 4 reviewers per rigor level (MAX): compliance-reviewer, test-reviewer, architecture-reviewer, silent-failure-hunter.

**Verdict:** PASS (no BLOCK; one FLAG acknowledged by SC1's negative fixture).

**Plan-gap review (2026-09-21):** 3 BLOCKING (B4 post-rename ids in AGENTS.md; B6 digraph rename; SC7 bare-mention pattern) — all folded in above. 3 ADVISORY: `mtk-savings.sh` added to B2; monorepo per-package wording accepted as out of scope; SC8–SC14 waiver stated.

## Open questions

None — D1–D7 were resolved by the engineer on 2026-09-21; the two mechanism choices above are recorded as rejected alternatives and surfaced at the gate.
