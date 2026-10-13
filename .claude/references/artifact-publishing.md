---
description: Canonical procedure for additively publishing workflow outputs (spec/plan/handoff/health) as a single in-place-updated Claude Artifact
globs: ["**/*"]
alwaysApply: false
---

# Artifact Publishing

`spec-driven-development` creates, and `planning-and-task-breakdown`, `handoff` and `repo-health` update, one Claude Artifact per workflow run. Each publishes **after** its output is on disk. Disk stays the source of truth: the drift, seal, lint and recovery pipeline reads local files only. Publishing never replaces, gates or blocks the disk write. A failed publish is reported in one line, and the workflow carries on. Forked review subagents never publish; only the orchestrator writes workflow artifacts.

## Gate

Publish only when **both** hold; otherwise do nothing and report nothing:

1. The `Artifact` tool is available in this harness.
2. `MTK_ARTIFACT_PUBLISH` is not `0` (default on). Regulated repos set it to `0` in `.claude/settings.local.json` env; respect it without asking to override.

Publishing sends content to claude.ai (private by default, shareable). Publish only the named on-disk workflow outputs — never secrets, `settings.local.json` or a transcript.

## Call

1. Workflow uuid: `$MTK_WF_UUID`, else the single `active` workflow from `bash scripts/workflow-artifact.sh list`. With neither, publish the doc you just wrote standalone, report the URL, and stop.
2. Record your output path (`results.spec_path`, `plan_path`, `handoff_path` or `health_report_path`) with `bash scripts/workflow-artifact.sh set "$MTK_WF_UUID" results.<field>=<path>`.
3. Assemble: `bash scripts/workflow-artifact-md.sh "$MTK_WF_UUID"` writes the derived, gitignored `.mtk/workflows/<uuid>.artifact.md` from whichever recorded docs exist. Never hand-edit it.
4. Publish that file with the `Artifact` tool. If `results.artifact_url` (from `workflow-artifact.sh read`) is set, pass it as `url` so the same artifact updates in place, keeping the title stable. Otherwise publish fresh with an `icon` and a title from `intent.goal`. Then run `workflow-artifact.sh set "$MTK_WF_UUID" results.artifact_url=<url>` and give the engineer the URL in one line.

## Verification

- [ ] Disk output written before any publish; gate honored
- [ ] One URL per workflow run (later publishes pass the recorded `url`)
- [ ] Only named on-disk workflow outputs published
