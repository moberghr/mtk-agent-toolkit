---
name: subagent-implementer-prompt
description: Implementer prompt template (TASK/DELIVERABLE/SCOPE/VERIFY contract) plus the canonical batch-result JSON schema; read on-demand by subagent-implementation before building each batch's context bundle.
globs: [".claude/skills/subagent-implementation/**"]
alwaysApply: false
---

# Implementer Prompt Template + Canonical Batch-Result Schema

The implementer subagent has no MTK context other than what you give it. The prompt must be self-sufficient. **This template is shared by both execution paths** — in the manual path you pass it as the `Agent` prompt; in the dynamic-workflow path it is the `agent()` prompt string in the generated script.

The template is organized under four explicit contract headers — **TASK** (what
to do), **DELIVERABLE** (what to return), **SCOPE** (the hard boundary), and
**VERIFY** (the gate that must pass before returning). The headers are part of
the contract, not decoration: an implementer that returns without satisfying
VERIFY is `inconclusive`, not done.

```
You are implementing one batch of a planned feature.

Repo root: <absolute path>
Read first (in this order):
  - CLAUDE.md
  - .claude/skills/tech-stack-<stack>/SKILL.md (build/test commands, ORM/framework patterns, reference files)
  - The coding guidelines listed in that tech stack's "## Reference Files" section

TASK — implement this batch:
<paste batch object: id, files, acceptance, verification, boundary, depends>

Spec context for this batch:
<paste relevant spec sections>

Prior batches already completed (you can rely on these existing; do NOT re-edit them):
<paste prior actual_files + behavioral_diff summaries>

SCOPE — your hard boundary:
- Whole-feature change_manifest (do NOT touch files outside this list without returning a "deviation"
  entry; do NOT add new public contracts not listed):
  <paste change_manifest>
- Out of scope (must not be touched):
  <paste out_of_scope>

Rules:
1. Read before editing. Match local patterns.
2. Stay within batch.files. If you discover an unavoidable extra file, edit it but record it
   as a `deviation` in your final JSON.
3. Add or update tests in this same batch — never defer to a later batch.
4. Do NOT spawn further subagents.
5. Do NOT ask the engineer questions — you are an inner subagent, not the orchestrator.
6. Tool discipline (each tool carries its own boundary):
   - Edit/Write: only files in batch.files (or a recorded `deviation`). Do not touch
     out_of_scope files even to "quickly fix" something — that is the out-of-scope-edit failure mode.
   - Bash: run only the build, test, and format commands from the tech stack skill, plus
     read-only git (`git diff`, `git status`). No network fetches, no package installs, no
     destructive commands.
7. Never delete. No `rm`, `git rm`, or overwrite-to-empty — deletion is out of scope for an
   implementer. If a file genuinely must be removed, record it as a `deviation` and let the
   orchestrator decide; never delete a file you did not create in this batch.

VERIFY — before returning:
- Run the build command and the relevant test command from the tech stack skill.
- If build or tests fail, set `status: "blocked"`, return the error in `build.evidence` /
  `tests.evidence` with `ok: false` and a one-line analysis. Do not loop endlessly.
- Returning without running the verify commands, or with a partial/ack-only reply, is
  `status: "inconclusive"` — it is NOT a pass and will be respawned.

DELIVERABLE — return EXACTLY one fenced JSON block matching this schema, then stop:

```json
{
  "batch_id": "<id>",
  "status": "completed|blocked|inconclusive",
  "actual_files": ["..."],
  "build":  { "ok": true|false, "evidence": "..." },
  "tests":  { "ok": true|false, "evidence": "..." },
  "behavioral_diff": "...",
  "deviations": [ { "kind": "...", "detail": "...", "justification": "..." } ],
  "usage": { "tokens": 0, "error_code": null }
}
```

(`usage` is optional — include it only if the dispatch mechanism exposes token
spend / an error code; it is a cost signal, never a pass/fail input.)
```

## Canonical batch-result schema

```json
{
  "batch_id": "B2",
  "status": "completed",
  "actual_files": ["src/Foo.cs", "tests/FooTests.cs"],
  "build": { "ok": true, "evidence": "command + tail" },
  "tests": { "ok": true, "evidence": "test summary" },
  "behavioral_diff": "what an external caller now observes that they didn't before",
  "deviations": [
    { "kind": "extra-file|skipped-file|extra-contract|other",
      "detail": "...", "justification": "..." }
  ],
  "usage": { "tokens": 0, "error_code": null }
}
```

`usage` is an **optional** result envelope (borrowed from per-subagent JSON
reporting): `tokens` is the batch's output-token spend if the dispatch
mechanism exposes it (the dynamic-workflow runtime does via `budget`), and
`error_code` is a short machine-readable code (`null` on success). It is a
loop-safety / cost signal only — never a pass/fail input. Omit the whole
block when no usage data is available; do not fabricate it.

`status` is one of `completed` (delivered + verified), `blocked` (could not
proceed; build/tests red and the reason stated), or `inconclusive`
(returned without runnable evidence — see the inconclusive rule below).
**A missing fenced block, a JSON parse failure, or an acknowledgment-only
reply ("done!", no JSON) is recorded as `inconclusive` — never as a pass.**
