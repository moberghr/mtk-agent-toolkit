---
description: Phase 2.5 approval-gate detail for implement — inline rendering spec, full MTK_AUTO_PROCEED preconditions, gate_scope and seal semantics
globs: []
alwaysApply: false
---
# Phase 2.5 Approval Gate — rendering, AUTO_PROCEED, seal semantics

> Extracted from `.claude/skills/implement/SKILL.md` (S2.26: a SKILL.md is a
> navigation layer, not a payload). The skill keeps the decision — when this
> fires, what it outputs, and what stops the run. This file holds the detail,
> and is read **only** when that phase is actually reached.

---

## Phase 2.5: Approval Gate (STOP HERE)

Mandatory. Before starting Phase 3, ask via the `AskUserQuestion` tool.

First, **render the plan and todo inline in the terminal** so the engineer can review them without opening files. Don't just cite the file paths — print the content:

1. A one-line header: scope classification, batch count, total files in the change manifest, and the computed rigor level with its score breakdown (see Rigor Score above).
2. The **full contents of `tasks/todo.md`** (the batch checklist with checkboxes and post-implementation review items). It is compact and is the primary thing the engineer approves.
3. A **batch breakdown from the plan**: for each batch, its title, files in scope, acceptance criteria, and boundary. This is the structured plan, not the raw markdown dump.
4. A **gate sequence** line — the full pipeline that will run against the approved batches, so the engineer sees what happens *between and after* them, not just the batch list. Derive it purely from facts already computed by this point (batch count from the plan; the Stage 2 reviewer set the Rigor Score table already dictates for this level — no new computation). Format: `Gate sequence: <N> batches → Phase 3.5 drift check → Stage 1 compliance-reviewer → Stage 2 [<reviewer set for this level>] → Phase 6 cleanup → Phase 7 compound`. The Stage 2 set follows the level: `test-reviewer` + `context-miner` (+ `architecture-reviewer` on boundary/slice) at HIGH, both + `silent-failure-hunter` + `context-miner` at MAX, and the conditional per-Stage-2-rules set at LIGHT/STANDARD (name the reviewers that apply).
5. The spec/plan/todo file paths, cited at the end for reference and editing. Print them as **bare repo-relative paths** (e.g. `docs/plans/2026-06-03-foo.md`, not a markdown link or a path buried in prose) so the terminal auto-linkifies them as clickable. Append `:<line>` when pointing at a specific batch (e.g. `tasks/todo.md:42`) so the click jumps straight to that line.

Keep the rendering proportional — the todo and batch breakdown are bounded by batch count, so this stays readable. The complete plan and spec markdown remain available via the `Show full plan & spec in terminal` option below for engineers who want every detail.

**`MTK_AUTO_PROCEED` opt-in.** This is the canonical precondition list; `implement` and `orchestration-gates.md` point here, and `scripts/run-fixtures.sh` evaluates it against the `auto-proceed-*` fixtures. If `MTK_AUTO_PROCEED=1` is set in the environment (typically via `.claude/settings.local.json` `env`), the orchestrator MAY default the recommended option on this gate (`Approve & run until done`) without an `AskUserQuestion` round-trip — but only when ALL of the following hold:

- The spec has zero open decisions (`open_decisions` array empty in the JSON sidecar).
- The spec has zero unresolved `[ASSUMED]` claims (no `[ASSUMED]`-tagged entry in the sidecar `assumptions` array, and none in the spec body). An assumption the model made on the engineer's behalf is an open decision in disguise — it gets a human at the gate. (`[VERIFIED:path]` and `[CITED:url]` claims do not block; only `[ASSUMED]` does.)
- No plan-gap-reviewer `BLOCKING` findings are unresolved.
- No unresolved package-legitimacy checkpoint (`checkpoint:human-verify` from planning for an externally-recommended package) remains open.
- The scope classification is not "breaking change" or "high security_impact".
- The rigor level is LIGHT or STANDARD (HIGH/MAX changes always get a human at the gate).

If any condition fails, AUTO_PROCEED MUST NOT be applied — fall back to `AskUserQuestion`. Auto-proceed never overrides explicit user standards, open plan decisions, or the failure-stop gate. When AUTO_PROCEED is applied, record the gate decision on the workflow artifact: `"$WFA" gate "$MTK_WF_UUID" plan_trust_gate pass --reason "AUTO_PROCEED — all preconditions met"`.

**Open the spec beside the terminal (best effort).** Only when the session context carries the `WORK SESSION:` line, which `session-start` adds when `work` launched the session (it sets `WORK_SESSION`) and the `work` command is installed. Without that line, skip this step entirely: no Bash call, so a session without `work` sees no extra call and no permission prompt. With it, before asking, run this once from the repo, with the spec's markdown path (`results.spec_path`, the `.md`, never its `.json` sidecar) in place of `<spec-md-path>`:

```bash
command -v work >/dev/null 2>&1 && work show "<spec-md-path>" >/dev/null 2>&1 || true
```

In a `work` dashboard session (work 2.13.0 or later) this opens the spec next to the terminal, rendered, and follows it as it is revised. It shows the spec rather than the plan because the batch breakdown above already puts the plan in the terminal, and the spec is the part the engineer would otherwise have to open. Everywhere else it does nothing and says nothing: `work` not installed, an older `work`, a folder that is not a work session, a dashboard that is not running, a spec git ignores (`work show` only shows files git does not ignore), or any other non-zero exit. Do not retry it, report its outcome, or mention it to the engineer; ask the question exactly as below. It is a read-only command, so it is allowed while the gate is open and does not count as a source edit. It adds to the inline rendering above and to the `Show full plan & spec in terminal` option; it replaces neither.

Then invoke `AskUserQuestion` with:

- **Question:** "Plan and todo are written. How would you like to proceed?"
- **Options:**
  - `Approve & run until done` — autonomous mode. Proceed through Phases 3-7; stop only on blocking issues (build failures needing design input, unexpected security findings, or scope expansion beyond the manifest). Set internal flag `autonomous = true` for the rest of the session.
  - `Approve (interactive)` — proceed, but ask focused follow-ups when decisions materially affect the implementation.
  - `Edit first` — pause so the engineer can edit the spec/plan/todo files; wait for their next message. (Open questions should already be resolved in Phase 1's ambiguity gate — use this for fine-tuning, not for surfacing new ambiguity.)
  - `Revise` — rewrite Phase 1/2 (overwriting the same file paths) and return to this gate.
  - `Show full plan & spec in terminal` — print the complete plan and spec markdown (full files, beyond the batch breakdown already shown), then re-ask this gate.

If `AskUserQuestion` is deferred in this session, call `ToolSearch` with `select:AskUserQuestion` first. If the harness does not expose it (e.g. Cursor, Copilot CLI, Gemini CLI), stop and print one line: "Approval gate requires AskUserQuestion (unavailable in this harness). Tell me: Approve & run until done / Approve (interactive) / Edit first / Revise." Wait for the engineer — do not proceed.

Until the engineer answers: read-only Bash only, no Edit/Write on source code, no Phase 3. Proceed to Phase 3 only after `Approve & run until done` or `Approve (interactive)`. Approval is choosing an approve option or an unqualified yes ("ok", "go", "lgtm" count); a reply that voices a doubt or a condition ("probably fine", "ok, but not sure about X") is not approval until that point is resolved. In autonomous mode, never call `AskUserQuestion` again for Phases 3-7 — stop and report instead.

On approval, record the gate decision and the seal (below) in **one** call:
`"$WFA" batch "$MTK_WF_UUID" gate plan_trust_gate pass --reason "<approve mode>" -- seal`
(add `-- set results.gate_scope='["<slug-1>","<slug-2>"]'` to the same call for a multi-spec session — next paragraph.)

**Declare the gate's scope when one session covers more than one spec.** A stacked session — several specs built as a chain of branches in one sitting — answers this gate once and then either re-asks per slice or carries the first answer forward. Carrying it forward is defensible; carrying it forward *silently* is not. Record what the answer covered, at answer time:

`results.gate_scope='["<slug-1>","<slug-2>"]'` — as a `set` op inside the approval `batch` call above.

The standing approval **expires** if a later slice's rigor level exceeds the level that was gated (a MAX slice cannot inherit a HIGH slice's approval) or if its `security_impact` ranks higher than the gated slice's. On expiry, re-open this gate for that slice. A slice genuinely covered by the standing answer records `plan_trust_gate pass --reason "standing approval from <slug-1> (gate_scope)"` — a citation to a real answer, not a second gate that never happened.

The `seal` op in that call **seals the approved scope** — it binds the exact spec + plan bytes the engineer just approved so a later edit cannot silently keep the approval.
With no explicit paths, `seal` binds the artifact's own recorded `results.spec_path` / `plan_path` (set in Phases 1–2) — the exact approved scope, not a re-typed list. **`results.todo_path` is deliberately excluded:** the todo is progress state that mutates as batches complete, so sealing it would flip the seal STALE on the first checkbox tick — a false tamper signal. Scope lives in spec + plan; progress lives in todo. (Explicit **repo-relative** paths may still be passed; the stale-seal hook matches sealed files by repo-relative path.) The seal is created **only** here, on the engineer's approval answer — never earlier by the agent editing state — and is derived from disk by the script, so it cannot be presented for a body other than the one on disk. `verification-before-completion` (Phase 4) re-checks it with `verify-seal` and refuses completion on a STALE seal, and `spec-approval-trigger.sh` re-queues this gate on any post-approval edit to a sealed spec or plan. On `Revise` or `Edit first`, leave the gate `pending`, do not seal, and emit a `field_updated` event. See `.claude/references/orchestration-gates.md` for full gate semantics.

Note: this gate controls when *Claude* asks. Harness tool-permission prompts (file-write/Bash approvals) are a separate layer — autonomous mode does not bypass them.
