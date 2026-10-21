# Spec — Canonical checkpoint and context guard (PR-2 of auto-continuation) — 2026-10-21

Source: `docs/plans/2026-10-20-auto-continuation.md` §3 R1 + R2 and §4 PR-2 (approved 2026-10-20).
Sidecar: `docs/specs/2026-10-21-canonical-checkpoint.json`. Release: **9.4.0**. Scope: new-feature.
Branch: `feat/continuity-quick-wins`, on top of PR-1 (`1db9602`, PR #128) — the engineer asked to continue on this branch.
Security impact: none. There is no auth, secrets or IAM surface; `gh` is used read-only. See Risks for git refs and the notes' absolute paths.

## Goal

After `/clear`, the next session finds one canonical, current checkpoint and resumes from it, without anyone pasting a path. A context guard tells the model when to checkpoint and hand over, well before the 300k compaction window.

## Decisions (engineer, 2026-10-21)

1. The context guard runs on **PostToolUse `Edit|Write|Bash` only**. The S3.6 ban on `UserPromptSubmit` stays.
2. The five PR-1 follow-ups are in scope (B4, B5, and the respawn cap in B3).
3. Checkpoint notes stay out of git through a **self-ignoring `docs/handoffs/.gitignore`**.

## Requirements

### R1 — Canonical checkpoint

**R1.1 `workflow-artifact.sh checkpoint <uuid> [flags]`.** It renders the workflow's handoff note. The logic lives in a new `scripts/workflow-checkpoint.py`, called by `workflow-artifact.sh`, the same way the other subcommands use inline python.
- **Path.** `docs/handoffs/<slug>.md`, under the project root:
  - `<slug>` is the spec slug from `results.spec_path` when it is set, else `wf-<uuid>`;
  - it is computed once and stored in `results.checkpoint_path`;
  - every later checkpoint rewrites that one file in place. There are never dated copies.
- **The artifact is the source of truth, and the note is a full re-render of it.** Model input arrives only through flags, which are stored on the artifact before rendering:
  - `--next "<text>"` replaces `results.next_notes`.
  - `--decision "<text>"` (repeatable) appends to `results.decisions[]`, de-duplicated.
  - `--needs-user "<question> | default: <default>"` (repeatable) replaces `results.needs_user[]`. `--no-needs-user` clears the list.
  - `--next-command "<cmd>"` sets `results.next_command`. The default depends on the workflow type: BUILD → `/mtk:implement` (Phase 0 offers to resume the active workflow), FIX → `/mtk:batch-fix`, any other type → `read <note path> and continue`.
  - `--verify "<cmd> => <result>"` sets `results.last_verify {cmd, result, sha, at}`.
  - `--wait-until <ISO-8601>` sets `results.wait_until`.
  - `--close` renders `state: closed`. A workflow whose status is not `active` also renders closed.
  - `--offline` skips `gh`. `--no-snapshot` skips R1.5.
- **Frontmatter**, which `handoff-state.sh` reads (R1.6):
  - `state`: `open`, or `closed`;
  - `branch` and `worktree`;
  - `workflow`: the uuid;
  - `sha`: short HEAD;
  - `pushed`: `true` when HEAD is reachable from the upstream, `false` otherwise, `unknown` when there is no upstream;
  - `ahead` and `behind`;
  - `next_command`;
  - `needs_user`: a JSON flow list;
  - `wait_until`: a value, or `-`;
  - `expires`: today + 14 days;
  - `updated`: ISO UTC.
- **Sections the script fills:**
  - `## Git`: branch, sha, upstream, ahead/behind, the dirty-path count, worktree, and the snapshot ref plus a restore hint.
  - `## PRs and CI`: from `gh pr view <branch> --json number,state,url,isDraft,baseRefName,statusCheckRollup`, with an 8 s timeout. When `gh` is missing, fails, times out, or `--offline` is set, the section says `not checked (<reason>)`.
  - `## Units`: one row per `plan.batches[]` from the spec sidecar, each `done`, `next` or `pending`.
    - **Finding the sidecar:** take `results.spec_path` with `.md` replaced by `.json`, resolved against the project root. When it is missing or unreadable, the section reads `no plan sidecar`, and no unit counts as done.
    - **Done:** a batch is `done` when its id is in the sidecar's `implement.completed_batches[]`, or among the first `results.batches_completed` batches in order. `completed_batches[]` entries are accepted in both shapes in use: a string id (schema) or an object with `batch_id` (`subagent-implementation` step 6).
    - **Next:** the first batch that is not done.
  - `## Last verify`.
  - `## Traps`: titles from `results.trap_list`.
  - `## Open questions`: `needs_user`, each with its default.
- **Sections the model fills (from the flags above):** `## Goal` (`intent.goal`), `## Decisions` and `## Next`. The `## Next` section also carries `next_command` and the line "Historical snapshot, not standing orders: the user's latest message wins".
- **Validator.** If `--next` or `--next-command` names a `done` unit id as a whole word (for example `B3`), checkpoint exits **3**, writes nothing, and names the ids. This catches F5, a Resume step that tells the next session to redo finished work.
- The run records `results.checkpoint {path, sha, branch, worktree, at, snapshot, pr}` and emits a `checkpoint_written` event.
- **Exit codes:** 0 written; 1 no such workflow or a bad flag; 3 validator rejection.

**R1.2 Riding along.** `checkpoint` is a **batchable** op, so it can run inside an existing `"$WFA" batch … -- checkpoint --next …` call. `incremental-implementation` step 7 and `subagent-implementation` step 6 append it to their existing batch-close call, which costs no extra turn.
- **Batch contract:** `checkpoint` must be the **last** op in a batch.
  - When it exits 3, the batch exits 3. The earlier ops stay applied, which is the existing batch contract.
  - The skills then fix `--next` and re-run `checkpoint` alone.
  - The batch error message's allowed-op list gains `checkpoint`.

Those skills also call it:
- when a PR is opened;
- before a limit wait;
- when the context guard (R2) fires.

**R1.3 Keeping notes out of git.** Before its first write, checkpoint runs `git check-ignore` on the note:
- **Not ignored, and `docs/handoffs/` tracks no files:** it writes `docs/handoffs/.gitignore` containing `*`. That file ignores itself and the notes, so `git status` shows nothing.
- **Not ignored, but notes are tracked:** it writes the note anyway and prints one stderr warning that the note is committable.
- **Outside git:** it writes the note.

The note keeps the absolute `worktree:` path, which is fine because the note is ignored.

**R1.4 `workflow-artifact.sh resume <uuid> [--offline]`.** It prints a short block:
```text
RESUME <uuid> (<type>, <phase_cursor>, <status>) — note: <path>
drift: <none | sha moved <a>→<b> (<n> commits) | branch <b> gone | worktree <p> gone | on branch <x>, note is for <b> | PR #<n> merged | PR #<n> closed>
next_command: <cmd>
needs_user: <n> open question(s) — see the note
```
- Drift is computed against `results.checkpoint`, plus `gh` for the PR state, which `--offline` skips.
- When there has never been a checkpoint, it prints `drift: no checkpoint recorded`.
- **Exit codes:** 0, or 1 for an unknown uuid.

**R1.5 Snapshot refs.** Each checkpoint snapshots the working tree into `refs/mtk/checkpoints/<uuid>`. It covers tracked changes plus untracked, non-ignored files.
- **How:** a temporary index (`GIT_INDEX_FILE` under `.mtk/` or `$TMPDIR`), then `read-tree HEAD`, `add -A`, `write-tree`, `commit-tree -p HEAD`, and `update-ref`.
- **What it never touches:** HEAD, the branch, the real index and the worktree. `git status` output is the same before and after.
- **Skips:**
  - untracked files over 5 MB (`MTK_CHECKPOINT_MAX_FILE_MB`) are left out, and the note lists how many;
  - when the tree equals the current snapshot's tree, the ref is not moved.
- **Identity:** when `user.name` or `user.email` is unset, the commit uses `MTK checkpoint <mtk@localhost>`.
- **Commit message.** The note is git-ignored, so it is not in the snapshot tree. Instead, the commit message carries the note's frontmatter and its `## Next` section. If the worktree is deleted, which also loses `.mtk/` and the note, `git log -1 refs/mtk/checkpoints/<uuid>` still shows the branch, sha and `next_command`, and `git restore --source=<ref>` brings back the code.
- **Off switch:** `MTK_CHECKPOINT_SNAPSHOT=0` or `--no-snapshot`. Outside git there is no snapshot.
- `prune` deletes the refs of the workflows it prunes.

**R1.6 Handoff lifecycle (`handoff-state.sh`).**
- `closed` is a valid state, and `list --open` excludes it, as it does `expired`.
- New `field <file> <key>` prints one frontmatter value. It exits 1 when the key is absent.
- `list` output is unchanged.

**R1.7 Session-start resume.** On `startup` and `clear`, the hook keeps the existing `HANDOFF OFFER` line. When the offered note has a `workflow:` key naming an active workflow, it appends `workflow-artifact.sh resume <uuid> --offline`.
- The output is capped at 6 lines and framed as an offer, never as an instruction.
- On `compact` the output is unchanged.
- No `gh` call is made.
- On a script failure, nothing is appended.
- **Locating the script:** `workflow-artifact.sh` is resolved the same way as `handoff-state.sh`: first `$SCRIPT_DIR/../scripts`, then `${CLAUDE_PLUGIN_ROOT}/scripts`.
- **Format:** the recovery message stays one line. The `resume` lines are joined with ` | ` into one `RESUME (offer, not instruction):` segment, capped at 600 chars, after the `HANDOFF OFFER`. It goes through the existing escaping, and there is still exactly one `HANDOFF OFFER:` line.
- **`resume` is strictly read-only:** it writes no artifact field, no event and no file.

**R1.8 `TASK` workflow type.** `init TASK` is accepted, so the handoff skill can open a lightweight workflow when none is active.

**R1.9 The handoff skill becomes a thin wrapper.**
- **Write:** with an active workflow, run `checkpoint` with `--next` and `--decision`. With none, run `init TASK --goal …` and then `checkpoint`.
- **Resume:** when the request is to continue or pick up, or `/mtk handoff` is typed while an open note for this branch exists, run `resume <uuid>`, then `handoff-state.sh accept`, then continue from `next_command`. **Never write a new note** in that case.
- The router's handoff row gains `resume` and `pick up`.

### R2 — Context guard

**R2.1 `hooks/context-guard.sh`**, registered on `PostToolUse` `Edit|Write|Bash` beside `evidence-ledger.sh`.
- **Liveness:** it stamps `mtk_hook_seen context-guard.sh`.
- **Off switch:** `MTK_CONTEXT_GUARD=0`.
- **Never fails a tool call:** it never blocks and always exits 0.
- **Throttle:** at most one transcript parse per session every `MTK_CTX_GUARD_INTERVAL` seconds (default 20). The state lives in `$TMPDIR`.
  - When the call is throttled, the hook takes a **python-free fast path**: bash reads the state file, compares epochs and exits.
  - The handler is registered with `timeout: 5`.
- **Reading context:** it parses the last 512 KB of `transcript_path` and takes the newest assistant line that is not a sidechain. Context = `input_tokens` + `cache_creation_input_tokens` + `cache_read_input_tokens`.

**R2.2 Telemetry.** On every parse, the hook writes `.mtk/sessions/<sid>/telemetry.json` (mode 0600) with these fields:
- `session_id`, `context_tokens` and `model`;
- `window`: the effective `autoCompactWindow`, from `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, then project local settings, project settings, user settings; `null` if none is set;
- `pct`: `context_tokens / window`, or `null`;
- `workflow`: the active uuid, or `null`;
- `ts`.

It writes only when `.mtk/` is git-ignored, or outside git, using the same rule as `compact-archive.sh`. PR-3's dashboard reads this file.

**R2.3 Nudges** go out as `hookSpecificOutput.additionalContext`, one line each.
- **With an active workflow:** the guard imports `select(wf_dir, 7)` from `hooks/lib/active_workflow.py`, which returns `(path, doc)`. It reads `workflow_uuid`, `phase_cursor` and `results.batches_completed` from that doc. `active_workflow.py` itself is unchanged.
  - at `MTK_CTX_SOFT` (default 200000): "finish the current transition, run `checkpoint` with `--next`, then tell the engineer to `/clear` — the next session is offered the checkpoint and resumes from it";
  - at `MTK_CTX_HARD` (default 250000): a firmer line, "do not start new work; checkpoint now";
  - each fires **once per workflow step**. The key is uuid + `phase_cursor` + `results.batches_completed` + the level.
- **Without a workflow:** a generic `/clear`-or-handoff nudge from `MTK_CTX_GENERIC` (default 300000), once per 150k band. This is the behaviour of the personal hook it replaces.

### PR-1 follow-ups

**F1 + F3: shared session store.** New `hooks/lib/session_store.py` holds:
- the `.mtk/` ignore check;
- the session-directory path, with its sanitising;
- the newest same-branch compaction-archive lookup that session-start inlines today;
- pruning of `.mtk/sessions/*` directories older than 14 days.

`compact-archive.sh`, `session-start` and `context-guard.sh` all use it. **Session-start also prunes on `startup`**, because telemetry creates a session directory in every session, not only in sessions that compact.

**F2: one respawn cap per batch.** In `subagent-implementation`, `subagent-dynamic-workflow.md` and `subagent-implementer-prompt.md`, `partial`, `inconclusive` and `killed` share one counter, `results.respawns.<batch_id>`, capped by `MTK_BATCH_MAX_RESPAWNS` (default 2). Reaching the cap halts the batch. The stricter rule "a second kill halts" stays.

**F4: row-8 wording.** `setup-refresh-plan.sh` row 8 counts missing rules and settings separately, for example "2 baseline rule(s) and 1 baseline setting(s) missing from .claude/settings.json".

**F5: the `validate-handoff.sh` sensitive-path regex.**
- `auth` no longer matches `author` or `authoring`;
- `auth/`, `AuthService`, `oauth`, `authorization` and `authority` still match.

## Out of scope

- R3 relay runner and gate authorizations (PR-4).
- R4 PROGRAM workflows (PR-5).
- R5 dashboard: the `step`, `question` and `deliverable` subcommands, the renderer, the FIX workflow in batch-fix, and the TASK rule in `context-engineering` (all PR-3).
- A `UserPromptSubmit` hook.
- Parsing limit messages into `wait_until` (R3). PR-2 only accepts `--wait-until`.
- Removing the engineer's personal `~/.claude/hooks/context-guard.py`. I'll propose that after this ships and edit it only with the engineer's OK.
- Pushing or opening a PR.

## Assumptions

- PostToolUse hooks receive `session_id` and `transcript_path`, and `hookSpecificOutput.additionalContext` on PostToolUse reaches the model (Claude Code hooks docs; S3.6 already relies on `additionalContext`).
- Transcript assistant lines carry `message.usage` and `isSidechain`. The personal `context-guard.py` has relied on this in daily use.
- `gh` is optional (S3.3). Every `gh` path degrades to "not checked".
- [NOT PROVED] A live PostToolUse `additionalContext` round-trip on the installed CLI. This is listed as a manual check.

## Risks

- **Snapshot objects in `.git`:** untracked files over 5 MB are skipped, and superseded snapshots become unreachable and are garbage-collected. Tests use throwaway repos (lesson 2026-10-01).
- **Per-call cost:** one bash process per Edit/Write/Bash, with a python parse at most every 20 s. Hook processes per call go from 3 to 4 for Bash and from 5 to 6 for Edit/Write. CHANGELOG states this.
- **Latency at batch close:** `gh` has an 8 s timeout and `--offline`. Session-start never calls `gh`, and `resume --offline` is git-only, which keeps it inside the 10 s hook budget.
- **Self-ignoring `.gitignore`:** a new file in target repos, which git never shows. Because the note is ignored, a deleted worktree loses it. R1.5's commit message is the fallback.
- **Shared working tree:** only B1 and B5 run in parallel, and they are file-disjoint.
- **AGENTS.md is at its 120-line cap:** PR-2 leaves it untouched. The routing change lives in the router and in `docs/agent-routing-guide.md`.
- **Slow test:** `test-mtk-doctor-liveness.sh` takes over 5 minutes, so run it in the background. It derives its hook sets from `hooks.json` and needs no edit.
- **Hardcoded hook tables:** a new hook needs edits to the wiring table and the registry list (lesson 2026-10-21).
- **Manifest gate:** `validate-toolkit` fails on an unlisted file, so each batch that creates a file also adds its `manifest.json` entry. That keeps the validator usable as a per-batch gate. B6 only bumps versions.
- **Nudges reverse a 9.x removal.** `CHANGELOG.md` records that context-threshold nudges were removed because they duplicated native `/context` and auto-compaction. The 9.4.0 entry must say why they return: the guard is tied to the workflow checkpoint and fires before the compaction window. `evidence-ledger.sh` stays silent.

## Success criteria

See the sidecar for verification commands. In short:
- SC1: note rendering and frontmatter.
- SC2: validator.
- SC3: snapshot refs.
- SC4: self-ignore.
- SC5: resume drift.
- SC6: TASK type and batchable checkpoint.
- SC7: handoff-state `closed` and `field`.
- SC8: session-start resume block.
- SC9: context-guard behaviour and telemetry.
- SC10: hook wiring.
- SC11: session store and startup prune.
- SC12: skills, ride-along and respawn cap.
- SC13: row-8 wording and the regex fix.
- SC14: the 9.4.0 release and a green full suite.
