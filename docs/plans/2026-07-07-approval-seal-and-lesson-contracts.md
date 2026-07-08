# Plan: Approval Seal + Executable Lesson Contracts

Spec: docs/specs/2026-07-07-approval-seal-and-lesson-contracts.md
Sidecar: docs/specs/2026-07-07-approval-seal-and-lesson-contracts.json

**Scope:** new-feature (backward-compatible) · **security_impact:** requires-audit-trail
**Rigor:** MAX (score 16 — 5 batches, 18 files, security_impact=requires-audit-trail, 4 public contracts)
**Path:** subagent implementation (one fresh implementer per batch, orchestrator-side drift checks)
**Precondition:** branch off `main` (currently on `docs/readme-landing-refresh`) — do NOT build here.

---

## Batch B1 — Seal engine + creation point
**Files:** `scripts/workflow-artifact.sh`, `.claude/skills/implement/SKILL.md`, `.claude/skills/spec-driven-development/SKILL.md`
**Governing constraints:** S3.1, S3.3 (SHA-256 via shasum/coreutils, no new dep), C0.5
**Do:**
- Add `cmd_seal <uuid> <path...>`: read each file, hash in a stable (sorted) path order, store `results.approval_seal = { hash, files[], sealed_at }`, print hash.
- Add `cmd_verify-seal <uuid>`: recompute over recorded files; exit 0 match / non-zero mismatch; print `sealed=<h1> current=<h2>` + changed paths on mismatch.
- Wire dispatch (`seal)`/`verify-seal)`).
- `implement` Phase 2.5: after `gate ... plan_trust_gate pass`, call `seal "$MTK_WF_UUID" <spec> <plan> tasks/todo.md`. Document that seal is created ONLY on the human approval answer (no self-approval).
- `spec-driven-development`: one paragraph documenting the seal.
**Acceptance:** SC1 — `seal` then `verify-seal` returns 0.
**Boundary:** no enforcement logic yet; no hook/verify-completion changes.

## Batch B2 — Seal enforcement + pressure test
**Files:** `hooks/spec-approval-trigger.sh`, `.claude/skills/verification-before-completion/SKILL.md`, `tests/pressure-tests/approval-seal.md`
**Governing constraints:** S3.1, S3.13–S3.15 (advisory stays tier-2, respects MTK_HOOKS_TIER2), S2.7 (pressure test), C0.5
**Do:**
- `spec-approval-trigger.sh`: broaden path match to `docs/specs/*.md`, `docs/plans/*.md`, `tasks/todo.md`; when an active seal covers the edited file, run `verify-seal`; on mismatch re-queue `planning-and-task-breakdown` with a reason naming the stale seal + both hashes. Stay exit 0.
- `verification-before-completion`: add a step running `verify-seal` before accepting completion; stale seal blocks "done" until re-approved+re-sealed.
- Pressure test `approval-seal.md`: SC2 (edit → mismatch), SC3 (advisory re-queue), SC4 (completion refused while stale) + a rationalization table (e.g. "I only fixed a typo in the approved spec").
**Acceptance:** SC2, SC3, SC4 scenarios documented and manually walkable.
**Boundary:** advisory half stays exit 0; blocking half lives in the verification skill, not a new PreToolUse gate.

## Batch B3 — Lesson schema + engine
**Files:** `.claude/references/learnings-schema.md`, `scripts/learnings.sh`
**Governing constraints:** S3.1, S3.16 (regen via mtk_guarded_write), backward-compat
**Do:**
- Schema: add optional `output_contract`, `prefinal_verification_checklist[{check_id,description,verification_method,blocking}]`, `confidence(low|medium|high)`, `source_evidence_refs[]`.
- `learnings.sh add`: accept `--output-contract`, `--prefinal-checklist`, `--confidence`, `--source-evidence-refs`; store them; `regen-markdown` renders a `Contract` subsection only when present.
**Acceptance:** SC6 — existing prose lessons render unchanged; a contract lesson renders a Contract subsection.
**Boundary:** no runner; no verify-completion wiring; fields are optional.

## Batch B4 — Lesson surfacing + lint + pressure test
**Files:** `.claude/skills/golden-path-capture/SKILL.md`, `.claude/skills/promote-lesson/SKILL.md`, `scripts/mtk-doctor.sh`, `tests/pressure-tests/lesson-contract.md`
**Governing constraints:** S2.7 (pressure test), C0.3 (skill anatomy preserved)
**Do:**
- `golden-path-capture` + `promote-lesson`: document when to populate the contract (promotion is the natural point); keep OPTIONAL.
- `mtk-doctor`: lesson-contract lint — malformed checklist entries / out-of-enum confidence → WARN (never FAIL).
- Pressure test `lesson-contract.md`: SC5 (well-formed PASS, malformed WARN) + rationalization table (e.g. "prose lesson, skip the contract" is legitimate — must NOT warn).
**Acceptance:** SC5.
**Boundary:** lint is WARN-only; the feature is optional.

## Batch B5 — Release chores
**Files:** `.claude/manifest.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `CHANGELOG.md`, `scripts/validate-toolkit.sh`, derived indexes, `checksums.sha256`
**Governing constraints:** C0.1, C0.2, C0.8, S3.9–S3.10, S4.5–S4.7, S4.11
**Do:**
- manifest.json: add entries for #6 + #12; bump version → 7.25.0.
- plugin.json + marketplace.json: version → 7.25.0; manifest `updated` date.
- CHANGELOG.md: 7.25.0 entry (approval seal + lesson contracts).
- validate-toolkit.sh: register any new structural constraint (S3.10) if the pressure tests need coverage.
- Rebuild derived indexes if touched (build-rule-index / triggers / references) — likely no-op.
- Regenerate `checksums.sha256` LAST (S4.11).
**Acceptance:** SC7 — `validate-toolkit.sh` prints "Toolkit validation passed".
**Boundary:** last commit; checksums regenerated as the final change.

---

## Gate sequence
5 batches → Phase 3.5 drift check → Stage 1 compliance-reviewer → Stage 2 [test-reviewer + architecture-reviewer + silent-failure-hunter] → Phase 6 cleanup → Phase 7 compound.

## Commit plan (S4.4)
- Commit 1: B1+B2 (Feature 1 — approval seal)
- Commit 2: B3+B4 (Feature 2 — lesson contracts)
- Commit 3: B5 (release: version + manifest + changelog + checksums)
