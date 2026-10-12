---
description: Canonical procedure for additively publishing workflow outputs (spec/plan/handoff/health) as a single in-place-updated Claude Artifact
globs: ["**/*"]
alwaysApply: false
---

# Artifact Publishing

Workflow skills persist their human-facing outputs to disk. **Disk is the
source of truth** — the machine pipeline (drift detection, approval seal, EARS
lint, plan-gap review, session recovery, baseline archive) reads local files
and cannot read a hosted artifact. This procedure **additionally** publishes
those outputs as one browsable [Claude Artifact](https://claude.ai) per
workflow run, so the engineer gets a single, always-current URL to review
outside the terminal.

Publishing is **additive** (never a replacement for disk) and **capability-
gated** (only where the harness exposes it). A skill that follows this
procedure and finds the gate closed completes exactly as if this section did
not exist — disk output unchanged, no error, no stall.

## When a skill publishes

`spec-driven-development`, `planning-and-task-breakdown`, `handoff`, and
`repo-health` invoke this procedure **after** their output is written to disk.
`spec-driven-development` creates the artifact; the others update it in place.

Do **not** publish from inside a forked review subagent (e.g.
`code-review-and-quality`). Only the orchestrator writes workflow artifacts
(see `workflow-artifacts` skill). Orchestrator-side publishing of review
findings is a future addition, not part of this procedure.

## Gate (check both, in order)

Publish only if **both** hold; otherwise stop silently:

1. The `Artifact` tool is available in the current harness. (Claude Code /
   claude.ai expose it; cursor / codex do not.) If it is not available, do not
   attempt to publish and do not report an error.
2. `MTK_ARTIFACT_PUBLISH` is not `0`. Default is on (publish). Regulated repos
   that must not egress internal specs set `MTK_ARTIFACT_PUBLISH=0` in
   `.claude/settings.local.json` env. Check with
   `` !`echo "${MTK_ARTIFACT_PUBLISH:-1}"` `` or read the env directly.

> **Data egress.** Publishing transmits the workflow's on-disk content to
> claude.ai, where the artifact is private by default but hosted externally and
> shareable from its page. Never assemble or publish anything not already
> written to disk as a named workflow output — no secrets, no
> `settings.local.json`, no transcript.

## Procedure

1. **Resolve the workflow uuid.**
   - Use `$MTK_WF_UUID` if the current workflow set it.
   - Else `bash scripts/workflow-artifact.sh list` — if exactly one workflow is
     `active`, use it.
   - Else there is no workflow to key the artifact to: publish standalone from
     the single on-disk doc you just wrote, report the URL in chat, and skip
     steps 4–5 (no URL to persist).

2. **Record your output path on the workflow artifact** (so the assembler can
   find it). Each skill records the field it owns — most already do this:
   ```bash
   scripts/workflow-artifact.sh set "$MTK_WF_UUID" results.spec_path=docs/specs/<file>.md
   scripts/workflow-artifact.sh set "$MTK_WF_UUID" results.plan_path=docs/plans/<file>.md
   scripts/workflow-artifact.sh set "$MTK_WF_UUID" results.handoff_path=docs/handoffs/<file>.md
   scripts/workflow-artifact.sh set "$MTK_WF_UUID" results.health_report_path=.claude/repo-health-latest.md
   ```

3. **Assemble the rollup.**
   ```bash
   bash scripts/workflow-artifact-md.sh "$MTK_WF_UUID"
   ```
   Writes `.mtk/workflows/<uuid>.artifact.md`, concatenating — with section
   headers — whichever recorded source docs currently exist. Missing paths are
   skipped, so the rollup always reflects the current state.

4. **Publish or update in place** with the `Artifact` tool, pointing at the
   assembled rollup:
   - Read `results.artifact_url` from the workflow artifact
     (`scripts/workflow-artifact.sh read "$MTK_WF_UUID"`).
   - **If empty** → publish `.mtk/workflows/<uuid>.artifact.md` fresh. Use a
     stable `favicon` (e.g. 📄) and a `title`/`description` derived from
     `intent.goal`.
   - **If already set** → publish the same file **and pass the recorded URL as
     `url`** so the existing artifact is updated in place rather than a new one
     minted. Keep the favicon and title stable across updates.

5. **Persist the URL and report it.**
   ```bash
   scripts/workflow-artifact.sh set "$MTK_WF_UUID" results.artifact_url=<url>
   ```
   Then tell the engineer, in one line, the URL and that it updates as the
   workflow progresses.

## Rules

- Disk write happens first and unconditionally. Publishing never gates or
  replaces it.
- One artifact per workflow run, keyed to `workflow_uuid`. Re-publishing the
  same file (or passing the recorded `url`) keeps one stable link.
- The rollup file (`.mtk/workflows/<uuid>.artifact.md`) is a derived artifact
  under gitignored `.mtk/`. Never hand-edit it; re-run the assembler.
- Raw markdown is the v1 format. Do not invest in styled HTML here.
- Absent tool or `MTK_ARTIFACT_PUBLISH=0` → silent no-op, disk unaffected.

## Verification

- [ ] Disk output was written before any publish attempt
- [ ] Gate honored: no publish when the `Artifact` tool is absent or
      `MTK_ARTIFACT_PUBLISH=0`
- [ ] `results.artifact_url` recorded on the workflow artifact after a publish
- [ ] A second publish in the same workflow reused the same URL (update in
      place, not a new artifact)
- [ ] Nothing beyond the named on-disk workflow outputs was published
