# Spec — Publish workflow outputs as a Claude Artifact

**Date:** 2026-07-13 · **Slug:** workflow-artifact-publishing · **Scope:** new-feature

## Summary

MTK workflow skills persist their human-facing outputs (spec, plan, handoff, health report) to disk under `docs/**` and `.claude/**`. Disk is and remains the source of truth — the machine pipeline (drift detection, approval seal, EARS lint, plan-gap review, session recovery, baseline archive) all read local files. This feature **additionally** publishes those outputs as a single, in-place-updated **Claude Artifact** so the engineer gets one browsable, always-current URL for a workflow run, rendered for review outside the terminal.

Publishing is **additive and capability-gated**: it happens only when the harness exposes the `Artifact` tool (Claude Code / claude.ai) and is not disabled by opt-out. On harnesses without the tool (cursor, codex), skills behave exactly as today — disk only, no error.

## Success criteria

- **SC1** — When the `Artifact` tool is available and `spec-driven-development` persists a spec, a Claude Artifact is published containing the spec, and its URL is recorded on the active workflow artifact under `results.artifact_url`.
- **SC2** — When a later skill in the same workflow (`planning-and-task-breakdown`, `handoff`, `repo-health`) publishes, it **updates the same URL in place** (passing the recorded `url`) rather than minting a new one — verified by the URL being unchanged across two publish calls in one workflow.
- **SC3** — The published artifact is a single browsable document whose sections reflect exactly the workflow outputs that exist on disk at publish time (Spec / Plan / Handoff / Health), assembled deterministically by `scripts/workflow-artifact-md.sh`.
- **SC4** — When the `Artifact` tool is absent OR `MTK_ARTIFACT_PUBLISH=0`, every touched skill completes with identical disk output and no publish attempt (no error, no stall).
- **SC5** — `bash scripts/validate-toolkit.sh` prints "Toolkit validation passed" with the new reference and script registered in `manifest.json`.

## Architecture and design

### Model

One artifact **per workflow run**, keyed to the existing `workflow_uuid`. The Artifact tool's update-in-place property (same file → same URL; `url` param targets an existing artifact across sessions) is what makes a single browsable link possible. Each publishing skill re-assembles a rollup markdown file and (re)publishes it.

### New shared reference — single source of the procedure

`.claude/references/artifact-publishing.md` carries the canonical procedure so each skill stays a thin navigation layer (S2.26). Procedure:

1. **Capability + opt-out gate.** Proceed only if the `Artifact` tool is available in the harness AND `MTK_ARTIFACT_PUBLISH` is not `0` (default on). Otherwise return silently — disk output is unaffected.
2. **Resolve workflow uuid.** Use `$MTK_WF_UUID` if set; else `scripts/workflow-artifact.sh list` and pick the single active workflow; else publish standalone (no URL persistence, report URL in chat only).
3. **Assemble rollup.** Run `bash scripts/workflow-artifact-md.sh <uuid>` → writes `.mtk/workflows/<uuid>.artifact.md` by concatenating, with section headers, whichever recorded source docs currently exist (`results.spec_path`, `results.plan_path`, `results.todo_path`, `results.handoff_path`, `results.health_report_path`).
4. **Publish / update.** Call the `Artifact` tool on `.mtk/workflows/<uuid>.artifact.md`. If `results.artifact_url` is already recorded, pass it as `url` to update in place; otherwise publish fresh.
5. **Persist URL.** `scripts/workflow-artifact.sh set <uuid> results.artifact_url=<url>` and report the URL to the engineer in one line.

### New helper — deterministic assembler

`scripts/workflow-artifact-md.sh <uuid>` (bash + python3, S3-compliant, `set -euo pipefail`, executable). Reads the workflow JSON, concatenates existing recorded source docs into `.mtk/workflows/<uuid>.artifact.md` with `#`/`##` section headers and a title from `intent.goal`. Missing source paths are skipped, not errors. Idempotent.

### Data egress (see Security)

Publishing sends internal spec/plan content to claude.ai. Default remains auto (per engineer decision), but `MTK_ARTIFACT_PUBLISH=0` disables it repo-wide for regulated contexts.

### Out of scope for v1

- **`code-review-and-quality`** — runs in a forked subagent (`context: fork`) and produces inline findings, not a persisted report file. Publishing belongs to the orchestrator, not the fork (`workflow-artifacts` rule). Deferred; documented as follow-up.
- **Styled HTML rendering** — v1 publishes raw markdown per engineer decision.
- **Version bump + checksum regeneration** — happen in a separate release commit (S4.11), not this feature branch.

## Security and compliance impact

`security_impact: none` for code trust boundaries — this touches no auth, secrets, PII, or IAM code paths. **However**, it introduces **data egress**: workflow outputs are transmitted to an external host (claude.ai) where an artifact, though private by default, is hosted and could later be shared. Mitigations:

- `MTK_ARTIFACT_PUBLISH=0` opt-out, documented in the reference and CLAUDE.md skill-routing env table.
- The reference states plainly that publishing externalizes content; it must not publish anything not already written to disk.
- Never publishes secrets or `.claude/settings.local.json` content — only the named on-disk workflow docs.

## Change manifest

| Path | Action | Purpose |
|---|---|---|
| `.claude/references/artifact-publishing.md` | create | Canonical publish procedure (capability gate, assemble, update-in-place, persist URL, egress note) |
| `scripts/workflow-artifact-md.sh` | create | Deterministic rollup assembler → `.mtk/workflows/<uuid>.artifact.md` |
| `.claude/skills/spec-driven-development/SKILL.md` | modify | Add publish step after disk-persist (step 9); creates the artifact |
| `.claude/skills/planning-and-task-breakdown/SKILL.md` | modify | Add publish step after plan-persist (step 7/8); updates in place |
| `.claude/skills/handoff/SKILL.md` | modify | Add publish step after artifact write (step 3); records `handoff_path`, updates in place |
| `.claude/skills/repo-health/SKILL.md` | modify | Add publish step after report write (step 5); records `health_report_path`, updates in place |
| `.claude/references/workflow-artifact-schema.md` | modify | Document `results.artifact_url` and source-path fields |
| `.claude/manifest.json` | modify | Register new reference + script (C0.2) |
| `CLAUDE.md` | modify | Add `MTK_ARTIFACT_PUBLISH` to the env table in Skill Routing |

## Test manifest

This is a markdown/bash toolkit — verification is structural + behavioral, not unit tests.

| Verification | Covers |
|---|---|
| `bash scripts/validate-toolkit.sh` → passed | SC5 |
| `bash scripts/workflow-artifact-md.sh <uuid>` on a fixture workflow produces a rollup with only existing sections | SC3 |
| Manual: run spec skill with Artifact available → artifact URL recorded on workflow | SC1 |
| Manual: run plan skill next → same URL, more sections | SC2 |
| Manual: `MTK_ARTIFACT_PUBLISH=0` and cursor-harness sim → disk-only, no publish, no error | SC4 |
| `tests/pressure-tests/artifact-publishing.md` — adversarial (skip-egress-note, publish-from-fork, mint-new-url-instead-of-update) | SC2, SC4, security |

## Implementation batches

- **B1 — Assembler + reference.** `scripts/workflow-artifact-md.sh`, `.claude/references/artifact-publishing.md`, schema doc update. Checkpoint: script runs on a fixture uuid; validate-toolkit passes.
- **B2 — Skill wiring.** Add the publish step to the 4 skills (each links the reference; no duplicated procedure). Checkpoint: each skill's `## Verification` references the publish step; validate-toolkit passes.
- **B3 — Manifest + CLAUDE.md + pressure test.** Register files, document env, add pressure test. Checkpoint: validate-toolkit passes; pressure test present.

## Risks and assumptions

- `[ASSUMED]` The `Artifact` tool's `url` param reliably targets an existing artifact across sessions (needed for cross-compaction update-in-place). If not, degradation is a new URL per session — still functional, less tidy.
- `[VERIFIED:scripts/workflow-artifact.sh]` `set results.artifact_url=<url>` works via dotted-path setter.
- `[VERIFIED:.claude/skills/repo-health/SKILL.md]` repo-health writes `.claude/repo-health-latest.md` in the main loop.
- `[ASSUMED]` Standalone skill runs (no active workflow uuid) are acceptable to publish without URL persistence (report URL in chat only).
- Risk: engineers on regulated repos may not notice egress — mitigated by the CLAUDE.md env entry and reference note, but not enforced.

## Open questions

- None blocking. `code-review-and-quality` orchestrator-side publishing is a deliberate v2 follow-up, not an open question for v1.

## Requirements

### Ubiquitous
- The system shall keep every workflow output written to disk regardless of artifact-publishing outcome.

### Event-driven
- When a publishing skill persists its output and the `Artifact` tool is available and `MTK_ARTIFACT_PUBLISH` is not `0`, the system shall publish or update the workflow artifact and record its URL under `results.artifact_url`.
- When `results.artifact_url` is already recorded for the active workflow, the system shall update that artifact in place rather than create a new one.

### State-driven
- While no active workflow uuid can be resolved, the system shall publish standalone and report the URL in chat without attempting to persist it.

### Optional
- Where `MTK_ARTIFACT_PUBLISH=0` is set, the system may skip all publishing while leaving disk output unchanged.

### Unwanted behaviours
- If the `Artifact` tool is absent, then the system shall complete the skill with disk output only and shall not raise an error or stall.
- If a source document recorded on the workflow does not exist on disk at assembly time, then the system shall omit that section rather than fail.

## Constitution Check

- **C0.2** — new reference and script both added to `manifest.json` `files`; every manifest path exists.
- **C0.5** — new script uses `set -euo pipefail` and is `chmod +x`.
- **C0.6** — no secrets published; only named on-disk workflow docs are assembled.
- **C0.8** — `validate-toolkit.sh` must pass before completion.
- **S2.26** — publish procedure lives in the reference; skills only link to it (navigation, not payload).
- **S3.3** — assembler uses only coreutils + python3 (accepted baseline).
- **S3.16** — assembler writes a fresh rollup each run (full overwrite of a derived, gitignored file); not a shrink-guarded protected artifact.
