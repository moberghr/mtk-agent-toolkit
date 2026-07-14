---
name: workflow-artifacts
description: Use to create, update, and read durable workflow state under .mtk/workflows/ so orchestration survives compaction, crash, and session handoff.
type: skill
license: MIT
compatibility:
  - claude-code
  - cursor
  - codex
trigger: workflow-start|phase-transition|gate-decision|resume-after-crash
skip_when: single-turn-task|exploration
user-invocable: false
---

# Workflow Artifacts

## Overview

Orchestration state that lives only in chat is lost on compaction or restart. This skill stores it on disk under `.mtk/workflows/{uuid}.json` plus an append-only event log, using a small bash helper. Other workflow skills (implement, fix, planning-and-task-breakdown, spec-drift-detection) call this skill at phase boundaries and gate decisions.

## When To Use

- At the start of every BUILD, DEBUG, REVIEW, PLAN, or FIX workflow.
- At every phase transition inside `/mtk implement`.
- Whenever a named orchestration gate is evaluated (see `.claude/references/orchestration-gates.md`).
- When resuming after compaction, restart, or handoff — list active workflows before starting fresh work.

### When NOT To Use

- Throwaway exploration where no commit will happen.
- Single-turn read-only questions ("what does file X do?").
- Inside subagents — only the orchestrator (main implement loop) writes artifacts. Subagents return structured output; the orchestrator decides what to persist.

## Workflow

1. **Resolve helper path.** The script ships at `scripts/workflow-artifact.sh` in this repo and at the same path in target installs. If `$CLAUDE_PLUGIN_ROOT` is set and the repo install lacks the script, prefix the plugin root. **State is project-anchored:** the script writes `.mtk/workflows/` under `$CLAUDE_PROJECT_DIR` (falling back to the git top-level, then cwd), so when MTK skills live outside the target project (plugin/marketplace install), export `CLAUDE_PROJECT_DIR=<project root>` or run from the project root — otherwise state lands in the wrong tree.
2. **Init at workflow start.** Capture the returned uuid into a session variable `MTK_WF_UUID`:
   ```bash
   MTK_WF_UUID=$(scripts/workflow-artifact.sh init BUILD --goal "<one-line user goal>")
   ```
3. **Persist anchors as soon as they exist.** When the spec, plan, and todo files are written, record their paths:
   ```bash
   scripts/workflow-artifact.sh set "$MTK_WF_UUID" \
     results.spec_path=docs/specs/2026-05-07-foo.md \
     results.plan_path=docs/plans/2026-05-07-foo.md \
     results.todo_path=tasks/todo.md
   ```
4. **Emit phase events.** At the start and end of every phase:
   ```bash
   scripts/workflow-artifact.sh event "$MTK_WF_UUID" phase_started   --data '{"phase":"phase-3"}'
   scripts/workflow-artifact.sh event "$MTK_WF_UUID" phase_completed --data '{"phase":"phase-3"}'
   ```
5. **Record gate decisions.** Every named gate (`plan_trust_gate`, `phase_exit_gate`, `failure_stop_gate`, `memory_sync_gate`, `skill_precedence_gate`) must be persisted via:
   ```bash
   scripts/workflow-artifact.sh gate "$MTK_WF_UUID" phase_exit_gate pass --reason "all batch tests green"
   ```
   `fail` on any gate is a hard stop — see `failure_stop_gate` semantics.
6. **Resume protocol.** On entry to a workflow with no explicit uuid:
   - Run `scripts/workflow-artifact.sh list`.
   - If a single active workflow matches the requested type, offer resume.
   - If multiple, ask via `AskUserQuestion` which uuid to resume.
   - If none, init a new one.
7. **Close the workflow.** At end of phase 7:
   ```bash
   scripts/workflow-artifact.sh set "$MTK_WF_UUID" status=completed
   scripts/workflow-artifact.sh event "$MTK_WF_UUID" workflow_completed --data '{"summary":"<short>"}'
   ```
   On unrecoverable failure, close with the failure pair instead:
   ```bash
   scripts/workflow-artifact.sh set "$MTK_WF_UUID" status=failed
   scripts/workflow-artifact.sh event "$MTK_WF_UUID" workflow_failed --data '{"reason":"<short>"}'
   ```

## Viewing Progress (Dashboard)

For a visual, read-only view of all workflows — status, phase, gate decisions, results, and event timeline — render the HTML dashboard:

```bash
scripts/workflow-dashboard.sh            # render once -> .mtk/workflows/dashboard/index.html, open it
scripts/workflow-dashboard.sh --watch    # regenerate + serve over http://127.0.0.1:8787/ (auto-refresh)
scripts/workflow-dashboard.sh --watch 10 --port 9000   # custom interval/port
```

The dashboard reads the same `{uuid}.json` + `{uuid}.events.jsonl` files this skill writes — it never mutates them, so it is safe to run during an active workflow. `--watch` regenerates on an interval and serves a static page (meta-refresh, no WebSocket) so a tech lead can watch a multi-batch run live. To share with non-CLI stakeholders, expose the served port with any tunnel tool (ngrok, cloudflared, ...) — the script intentionally stays a self-contained static renderer and does not embed a tunnel. Requires `python3` (the same dependency the helper already uses).

## Rules

- All writes go through `workflow-artifact.sh`. Never `Edit` or `Write` `{uuid}.json` directly — the event log would desync.
- Subagents do not write workflow artifacts. The orchestrator persists subagent results via `event agent_returned`.
- `.mtk/` is gitignored by default. Treat artifacts as local diagnostic state, not committed history.
- A `failure_stop_gate: fail` event terminates the workflow. Do not emit further events after `workflow_failed`.

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` for the shared table. Workflow-artifact-specific traps:

- *"This is a small task, the artifact is overkill."* — Init takes one line; the value is realized only when something fails. Skipping it is the same as not having it when you need it.
- *"I'll just track state in the conversation."* — Compaction silently destroys conversation state. The artifact exists exactly because chat is unreliable.
- *"I'll write the JSON directly, faster than calling the script."* — The event log is the durable trace; direct writes silently break it.

## Red Flags

- Phase advances without a `phase_exit_gate: pass` event in the log.
- `status: active` workflows older than 24 hours with no recent events.
- Direct edits to `{uuid}.json` (the event log will not contain a corresponding `field_updated` event).
- Multiple workflows of the same type both `active` (probably a missed close).

## Verification

- [ ] `scripts/workflow-artifact.sh list` shows the current workflow with the expected type and phase
- [ ] The event log ends with the most recent gate or phase event (no orphan state)
- [ ] On a fresh session, `list` plus reading the artifact reproduces the workflow's current state without chat history
- [ ] No direct `Edit`/`Write` calls were made against `.mtk/workflows/*.json`
