# Batch: continuity field fixes from the 9.4.0 24h analysis (2026-10-22)

Scope note: no new public contract and no architectural change. The workflow JSON gains one
additive field (`owner_session`), and `hooks/lib/active_workflow.py` gains an optional
`--session` filter. Release as 9.4.1.

Gate: satisfied by an explicit directive. On 2026-10-22 the engineer answered "agreed, do all
fixes" to the enumerated proposal. That proposal named:
- tying each workflow to the session that owns it;
- changing the nudge wording when compaction is on;
- labelling TASK workflows properly and expiring stale ones;
- the doctor check;
- looking into the security-gate timeouts.

Evidence comes from 37 sessions over 24h. Three sessions got "checkpoint wf-X" nudges for
another session's workflow (863460c0 disk scan, db9b328d upstream issues, 59869b95). There
were 0 compactions with `autoCompactEnabled: false`. `security-gate.sh` timed out 58 times
at 5s, every time on a command of 2–15k characters (heredoc file writes).

## Findings

1. **Workflows are matched by repo, not by session.** This is behavioral.
   - `workflow-artifact.sh` stamps `owner_session` from `CLAUDE_CODE_SESSION_ID`. It does so on
     `init` and on every mutating subcommand. It never does so on `resume`, `read`, `list` or
     `verify-seal`, so an offer never claims a workflow.
   - `active_workflow.select` takes an optional session. When one is given, only workflows
     whose `owner_session` matches are eligible.
   - `context-guard.sh`, `subagent-context.sh`, the compact re-inject in `session-start` and
     `compact-archive.sh` pass their payload `session_id`.
   - Added during review (same finding): `workflow-continuation.sh`, the Stop hook's
     user-visible "WORKFLOW IN PROGRESS … hand off" line, now selects only the session's own
     workflow.
   - "Expire stale ones" is covered by this binding. A stale active workflow is visible only to
     the session that owned it, so it can no longer nudge, re-inject into or archive for an
     unrelated session.
   - Tests: test-active-workflow, test-context-guard, test-subagent-context,
     test-session-start-compact-workflows, compact-archive, workflow-artifact.
2. **The context-guard nudge ignores compaction.** This is behavioral. When auto-compaction is
   effectively on (settings precedence local > project > user > `~/.claude.json`, plus the
   `DISABLE_AUTO_COMPACT` / `DISABLE_COMPACT` env) and a window is configured, the workflow
   nudge says to checkpoint and keep going. Auto-compaction carries the work, and the
   checkpoint is re-injected afterwards. The generic nudge drops the `/mtk handoff`
   suggestion. When compaction is off, the current wording stays. Test: test-context-guard.
3. **TASK workflows show the wrong label.** This is behavioral and small. The nudge shows
   "phase-0, 0 batch(es) done" for TASK workflows, which have no phases or batches. Instead it
   names the type. Test: test-context-guard.
4. **mtk-doctor is blind to disabled auto-compaction.** This is behavioral. A new
   `auto-compaction` line:
   - WARN when it is effectively disabled, naming the source;
   - WARN when no window is configured in env, local, project or user settings;
   - PASS otherwise.
   The project-settings baseline WARN no longer lists `autoCompactWindow`. `--fix` still
   merges it. Test: test-mtk-doctor-settings-checks.
5. **`security-gate.sh` is super-linear on long commands.** This is behavioral (perf). Find
   the hot spot and make it linear, without weakening any check (S3.18). The superset and
   false-positive suites must stay green. Add a timing regression test on a 15k-character
   heredoc command.

## Post-batch

Release 9.4.1 with:
- the three manifests;
- CHANGELOG;
- manifest entries for new tests;
- the S3.6/S3.11 rule text;
- `env-knobs` if needed;
- checksums.

Then run the full hook suite and validate-toolkit, followed by pre-commit review and test
review. Push and open the PR (the engineer asked for the PR).
