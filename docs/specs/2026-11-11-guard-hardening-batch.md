# Guard hardening batch — 2026-11-11

Scope: corrective fixes to existing hooks. No new public contract; no architectural change.
Branch: `fix/guard-hardening`. Source: hook-layer audit of 9.4.2 run on 2026-11-11.

Gate: satisfied by the engineer's explicit directive on the enumerated audit list
("i agree, you oversee this and use opus 5.5 to build all", 2026-11-11). Per that directive the
groups are built by Opus implementer subagents under orchestrator review, instead of inline.

## Findings

Group A — edit guards (`hooks/scope-guard.sh`, `hooks/config-guard.sh`, `hooks/hooks.json`)

1. **scope-guard ignores `..`** — behavioral, boundary (guard). With a manifest of `src/a.cs`, an
   edit to `.mtk/../src/b.cs` or `docs/specs/../../src/b.cs` is allowed. Normalise the path before
   the exemption and manifest match.
2. **scope-guard denies everything on an empty manifest** — behavioral. The emptiness check is
   unreachable because defaults are appended first.
4. **MultiEdit / NotebookEdit skip the edit guards** — behavioral, boundary. The `Edit|Write`
   matchers and the tool `case` in config-guard / scope-guard do not cover them.
9. **config-guard gaps** — behavioral. A deleted strictness line and ESLint severity `0` /
   `[0, {...}]` are not flagged.

Group B — command gate (`hooks/security-gate.sh`, `hooks/lib/gate-backstop.sh`)

5. **security-gate bypasses** — behavioral, boundary. Allowed today: eval / source of a
   curl-or-wget substitution, a variable-indirected recursive delete, a recursive delete whose path
   contains a `..` component, deleting a protected remote ref by push (colon-ref and `--delete`),
   and `TRUNCATE` without `TABLE`.
6. **specific-path recursive deletes are blocked** — behavioral. `./node_modules`, `.next`,
   `/tmp/build-abc` are denied as "broad". After review round 2: a delete the 9.4.2 gate denied is
   allowed only when every operand is a literal path inside the working directory or below `/tmp`,
   with no `..`, no `.git` component, no expansion, glob or brace; a delete 9.4.2 allowed stays
   allowed unless it is a listed bypass (relative operand after a `cd` elsewhere, tokenizer
   mis-splits). `tests/hooks/test-security-gate-rm-table.sh` pins the decisions against frozen
   9.4.2 ones. A narrow exception to S3.18, pending the engineer's decision on the rule text.
7. **gate can time out and fail open** — behavioral. About 2.6 ms per command-substitution segment
   and 7.5 ms per `sh -c` segment against a 5 s timeout. Deny above a command length / segment /
   `sh -c` cap, and deny when judging passes a 3 s self-deadline.

Group C — shared state (`hooks/lib/hook-io.sh`, `hooks/cost-tracker.sh`, `hooks/pre-commit-linters.sh`)

3. **session lock is unsafe** — behavioral. Acquire returns 0 after 100 tries without the lock,
   release removes the lock unconditionally, stale-steal is a TOCTOU and takes live locks older
   than 2 s. Add an owner token, release only on match, make a failed acquire visible to callers.
8. **pre-commit linter misses git-quoted non-ASCII paths** — behavioral. A staged `Über.cs`
   containing a key passes.
10. **analytics double-count** — behavioral. `record_analytics` adds the cumulative session ops on
    every Stop. Keep a per-session high-water mark, update under the lock.

Every finding gets a failing-first regression test under `tests/hooks/`.
