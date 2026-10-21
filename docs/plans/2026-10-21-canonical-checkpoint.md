# Plan — Canonical checkpoint and context guard (PR-2, 9.4.0) — 2026-10-21

Spec: `docs/specs/2026-10-21-canonical-checkpoint.md` (+ `.json` sidecar). Program: `docs/plans/2026-10-20-auto-continuation.md` §4 PR-2.
Branch: `feat/continuity-quick-wins` (continues PR #128). Workflow: `wf-20261021T063302Z-19cccb`.

**Rigor: HIGH.** The score is 10:
- 6 batches, which is a hard trigger;
- 37 manifest entries, about 20 of them non-mechanical;
- 10 internal-tooling contracts;
- `security_impact=none`.

Following the 2026-10 ceremony-sizing feedback, the run uses Sonnet reviewers and at most 2 review rounds.
- **Phase 3 path:** subagent, with Sonnet implementers by default. B1 and B4 are flagged novel and use Opus. B6 runs inline, because it is mechanical release work.

## Shared files (deliberate, ordered by edges)

- `.claude/manifest.json`: B1 → B2 → B4 → B6.
- `hooks/session-start`: B2 → B4.
- `.claude/references/env-knobs.md`: B3 → B4.

## Waves

| Wave | Batches | Why |
|---|---|---|
| 1 | **B1** ∥ **B5** | file-disjoint; B5 reads nothing B1 writes |
| 2 | **B2** | needs B1's `resume` and the checkpoint frontmatter |
| 3 | **B3** | documents B1/B2's final CLI; shares `env-knobs.md` with B4 |
| 4 | **B4** | shares `hooks/session-start` with B2 and `env-knobs.md` with B3 |
| 5 | **B6** | release, checksums last |

## Batches

### B1 — Checkpoint core (Opus)
- **Files:**
  - `scripts/workflow-artifact.sh`
  - `scripts/workflow-checkpoint.py` (new)
  - `tests/hooks/test-workflow-artifact-checkpoint.sh` (new)
  - `.claude/manifest.json` (entries for the two new files)
- **Do:**
  - `checkpoint` and `resume` subcommands, delegating to the python file.
  - `checkpoint` becomes batchable.
  - `init TASK`.
  - `prune` deletes `refs/mtk/checkpoints/<uuid>`.
  - The usage header documents all of the above.
  - `checkpoint` must be the last op in a batch. A rejection (exit 3) propagates, with the earlier ops left applied.
  - Python covers the R1.1 render, the validator (exit 3), R1.3 self-ignore, R1.4 drift and the R1.5 snapshot.
- **Tests:** SC1–SC6, including a rejection inside a batch, in `mktemp -d` git repos only, with a stub `gh` script on PATH for the PR states. The real repo is never touched.
- **Acceptance:** SC1–SC6.
- **Verify:** `bash tests/hooks/test-workflow-artifact-checkpoint.sh && bash tests/hooks/test-workflow-artifact-prune.sh && bash tests/hooks/test-workflow-artifact-trap.sh && bash tests/hooks/test-workflow-artifact-criteria-seal.sh && bash scripts/validate-toolkit.sh`.
- **Boundary:**
  - existing subcommands keep their output and exit codes;
  - a snapshot never moves HEAD or the branch, and never touches the real index or the worktree.

### B2 — Handoff lifecycle and session-start resume (Sonnet)
- **Files:**
  - `scripts/handoff-state.sh`
  - `hooks/session-start`
  - `tests/hooks/test-handoff-state.sh`
  - `tests/hooks/test-session-start-resume.sh` (new)
  - `.claude/manifest.json` (entry for the new test)
- **Do:**
  - `closed` state.
  - `field <file> <key>`.
  - Session-start appends `resume <uuid> --offline`, at most 6 lines, after a `HANDOFF OFFER` whose note has `workflow:` naming an active workflow, on `startup` and `clear` only.
- **Acceptance:** SC7, SC8.
- **Verify:** `test-handoff-state.sh`, `test-session-start-resume.sh`, `test-session-start-compact-framing.sh`, `test-session-start-compact-workflows.sh` and `validate-toolkit`.
- **Note:** `resume` is read-only. Its output is joined with ` | ` into one `RESUME (offer, not instruction):` segment of at most 600 chars, and the script is resolved the same way as `handoff-state.sh`.
- **Boundary:** the `list` format is unchanged, `compact` output is unchanged, and offers stay offers.

### B3 — Skills, references, respawn cap (Sonnet)
- **Files:**
  - `handoff/SKILL.md`
  - `mtk/SKILL.md`
  - `incremental-implementation/SKILL.md`
  - `subagent-implementation/SKILL.md`
  - `references/subagent-dynamic-workflow.md`
  - `references/subagent-implementer-prompt.md`
  - `workflow-artifacts/SKILL.md`
  - `references/workflow-artifact-schema.md`
  - `references/env-knobs.md` (checkpoint and respawn knobs)
  - `tests/pressure-tests/subagent-implementation-pressure.md`
- **Do:**
  - R1.9 handoff wrapper and the resume route.
  - R1.2 ride-along at batch close, PR open, a limit wait, and a guard nudge.
  - F2 shared respawn cap (`MTK_BATCH_MAX_RESPAWNS`, default 2), stated in the skill, the dynamic-workflow reference and the implementer prompt.
  - The batch contract: checkpoint goes last; on exit 3, fix `--next` and re-run it alone.
  - Schema reference fields.
- **Acceptance:** SC12.
- **Verify:** `bash scripts/validate-toolkit.sh && bash scripts/run-fixtures.sh`, plus the SC12 greps in the sidecar.
- **Boundary:** no new When To Use bullets on skills already over the cap, and descriptions stay ≤200 chars.

### B4 — Context guard and shared session store (Opus)
- **Files:**
  - `hooks/context-guard.sh` (new)
  - `hooks/lib/session_store.py` (new)
  - `hooks/hooks.json`
  - `hooks/compact-archive.sh`
  - `hooks/session-start`
  - `tests/hooks/test-context-guard.sh` (new)
  - `test-compact-archive.sh`
  - `test-hooks-wiring.sh`
  - `test-hook-registry.sh`
  - `references/env-knobs.md` (guard knobs)
  - `test-session-start-resume.sh` (startup-prune assertion)
  - `.claude/manifest.json` (entries for the new files)
- **Do:**
  - R2.1–R2.3.
  - F1/F3: session-start's compaction-offer lookup and the prune move into `session_store.py`, and session-start also prunes on `startup`.
  - The guard imports `select()` from `active_workflow.py`, which stays unchanged.
  - When throttled, the guard takes the python-free fast path. It is registered with `timeout: 5`.
- **Acceptance:** SC9, SC10, SC11.
- **Verify:** `test-context-guard.sh`, `test-compact-archive.sh`, `test-hooks-wiring.sh`, `test-hook-registry.sh`, `test-session-start-resume.sh` and `test-session-start-compact-framing.sh`. Also `validate-toolkit`. Run `test-mtk-doctor-liveness.sh` in the background; it derives its hook sets from `hooks.json`, so it needs no edit.
- **Boundary:**
  - no `UserPromptSubmit` or read-path hook;
  - it never blocks and always exits 0;
  - telemetry is written only where `.mtk/` is ignored.

### B5 — PR-1 follow-ups: row-8 wording and the handoff regex (Sonnet)
- **Files:**
  - `scripts/setup-refresh-plan.sh` + `test-setup-refresh-plan.sh`
  - `scripts/validate-handoff.sh` + `test-validate-handoff-derived.sh`
- **Do:**
  - F4: row 8 counts rules and settings separately.
  - F5: `auth([^o]|$|ori[sz]|ority)`, or an equivalent ERE that keeps `auth/`, `AuthService`, `oauth`, `authorization` and `authority`, and drops `author` and `authoring`.
- **Acceptance:** SC13.
- **Boundary:** row status semantics are unchanged, and nothing else previously flagged is dropped.

### B6 — Release 9.4.0 (inline)
- **Files:**
  - the three manifests (version bump only; each creating batch has already added its new paths)
  - `CHANGELOG.md`, with the hook-process table (Bash 3→4, Edit/Write 5→6) and why context nudges return after their 9.x removal
  - `README.md`
  - `.claude/rules/hooks-and-scripts.md` (S3.6 registered set plus `session_store.py` in the lib list, S3.11 RESUME segment)
  - `docs/agent-routing-guide.md`
  - `checksums.sha256`, regenerated last
  - `tasks/lessons.md`, written after review in Phase 7
- **Acceptance:** SC14.
- **Verify:** validate-toolkit, run-fixtures, `generate-checksums.sh --verify`, and the full hook suite.
- **Boundary:** AGENTS.md is untouched.

## After Phase 3

- Run the full suite: `for t in tests/hooks/test-*.sh`, with the liveness test in the background, plus validate-toolkit and fixtures.
- Write the behavioural diff.
- Phase 3.5 drift check against the sidecar.
- Phase 4 review lanes:
  - Stage 1: compliance and silent-failure. The new hooks have fail-open paths, so the silent-failure lane applies.
  - Stage 2: test-reviewer, architecture-reviewer (a new hook and lib) and context-miner.
  - Then finding-verifier.
  - All lanes run on Sonnet, with at most 2 rounds.
- Phase 7: lessons, and a proposal to remove the personal `~/.claude/hooks/context-guard.py` and its `UserPromptSubmit` entry. I'll make that edit only with the engineer's OK.

## Manual checks for the PR

- One live session with the plugin loaded from this branch. Push context past 200k inside a workflow, or temporarily set `MTK_CTX_SOFT` low, and confirm the nudge reaches the model.
- `/clear`, then confirm `HANDOFF OFFER` plus the `RESUME` block. Type "go" and confirm the model continues from `next_command`.
