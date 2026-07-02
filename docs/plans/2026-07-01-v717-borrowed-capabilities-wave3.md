# Plan — v7.17.0 Borrowed capabilities, wave 3

Spec: `docs/specs/2026-07-01-v717-borrowed-capabilities-wave3.md`
Sidecar: `docs/specs/2026-07-01-v717-borrowed-capabilities-wave3.json`

## Rigor

- Batches: 7 → +7
- Change manifest: 20 files → +7 (rounded up)
- security_impact: none → +0
- Public contracts added: 8 → +4 (capped)
- Score: 18 → **MAX**
- Hard triggers also independently force HIGH: batches ≥ 3, change_manifest ≥ 6.

Path: **subagent** (Phase 3), Stage 2 reviewers: both `test-reviewer` + `architecture-reviewer` + `silent-failure-hunter` (MAX). `MTK_AUTO_PROCEED` not eligible (rigor MAX).

## Batches

### B1 — F1: Critical Rules in cross-tool config generators
**Files:** `scripts/generate-agents-md.sh`, `scripts/generate-tool-configs.sh`
**Acceptance:** both scripts extract `^## Critical Rules` (prefix match) from `CLAUDE.md` if present, place it first, clearly marked, in generated output; absence is silent (no error).
**Boundary:** no change to which reference files are concatenated otherwise.

### B2 — F2: evidence-capture.md + verification-before-completion cross-reference
**Files:** `.claude/references/evidence-capture.md` (new), `.claude/skills/verification-before-completion/SKILL.md`
**Acceptance:** new reference documents the `browser` channel capture procedure (screenshot/console/network via Playwright MCP, persisted under `docs/specs/<slug>.evidence/<criterion-id>/`) and the no-Playwright degraded-textual fallback; `verification-before-completion.md` links to it and requires the evidence path be cited when channel is `browser`.
**Boundary:** documentation only — no new hook/script.

### B3 — F3: golden-path-capture skill
**Files:** `.claude/skills/golden-path-capture/SKILL.md` (new), `.claude/skills/correction-capture/SKILL.md`
**Acceptance:** new skill follows workflow-skill anatomy (Overview/When To Use/Workflow/Verification), reuses `learnings.sh`/`.claude/lessons/personal.md` destination and schema, trigger is self-driven struggle-then-success (2+ failed attempts, then success), distinct from correction-capture's engineer-correction trigger; correction-capture cross-references it so the two are not confused.
**Boundary:** no new storage format — reuses existing lesson schema fields (`wrong_turns`, `time_cost`).

### B4 — F4: optional release signing
**Files:** `scripts/generate-checksums.sh`, `scripts/mtk-doctor.sh`
**Acceptance:** `--sign` flag signs `checksums.sha256` with `openssl pkeyutl` when `MTK_RELEASE_SIGNING_KEY` is set, producing `checksums.sha256.sig`; `mtk-doctor.sh` verifies with `MTK_RELEASE_PUBLIC_KEY` when both are present, else reports informational PASS, never a hard FAIL.
**Boundary:** opt-in only; unsigned releases remain valid; no new hard dependency (openssl already assumed present).

### B5 — F5: gate-sequence preview
**Files:** `.claude/skills/implement/SKILL.md`
**Acceptance:** Phase 2.5 rendering instructions gain a short "Gate sequence" line derived from the already-computed rigor level (batches → drift check → Stage 1 → Stage 2 reviewer set → cleanup → compound).
**Boundary:** documentation/formatting addition to Phase 2.5 only; no new gate, no new data source.

### B6 — F6: query-code-index.sh
**Files:** `scripts/query-code-index.sh` (new), `tests/hooks/test-query-code-index.sh` (new), `.claude/skills/prior-work-check/SKILL.md`, `.claude/skills/code-simplification/SKILL.md`
**Acceptance:** `find <keyword>` greps CODE_INDEX.md rows case-insensitively with section context; `callers <symbol>` uses `git grep` for textual references; both documented as textual search, not semantic call-graph resolution; test covers both modes against a fixture; `prior-work-check`/`code-simplification` reference the script instead of ad hoc grep.
**Boundary:** no new dependency beyond `git grep`; no attempt at semantic resolution.

### B7 — Release
**Files:** `.claude/manifest.json`, `.claude-plugin/plugin.json`, `CHANGELOG.md`, `README.md`, `.claude/references.index`, `.claude/triggers.index` (if golden-path-capture declares `trigger:`), `checksums.sha256`
**Acceptance:** version bumped 7.16.0 → 7.17.0 in both manifest files with matching `updated` date; CHANGELOG + README "What's New" describe all 6 items (2 as "verified already covered, gap closed" + 4 as new); indices regenerated; checksums regenerated last.
**Boundary:** version/docs/index files only — no source behavior change in this batch.

## Post-Implementation Review Items

- [ ] Confirm F1's Critical-Rules extraction doesn't break existing `generate-agents-md.sh`/`generate-tool-configs.sh` idempotency/marker checks.
- [ ] Confirm F4's signing is fully optional end-to-end (fresh clone, no env vars set, `mtk-doctor.sh` still PASS/WARN not FAIL).
- [ ] Confirm F3 doesn't duplicate `correction-capture`'s trigger surface (no double-capture of the same event).
