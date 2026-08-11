# Spec: Artifact-root resolution + path-spelling robustness

- **Date:** 2026-08-11
- **Slug:** `2026-08-11-artifact-root-and-path-spelling`
- **Status:** approved
- **Origin:** followups from `docs/specs/2026-08-11-mixed-stack-feedback-batch.md`
  (F2, escalated out of that batch by the Scope Guard) and open item X1 in
  `tasks/todo.md`.

## Problem

Two defects with one shape: **MTK compares paths as strings, so a path that is
spelled differently but names the same thing silently fails to match, and the
guard that depended on the match exits 0 instead of failing loudly.**

### P1 — path spelling (X1)

Four hooks derive a repo-relative path with `REL_PATH="${FILE_PATH#"$REPO_ROOT"/}"`:
`scope-guard.sh`, `read-guard.sh`, `spec-approval-trigger.sh`, `rule-trigger.sh`.

`REPO_ROOT` comes from `git rev-parse --show-toplevel` (physical, canonical
case). `FILE_PATH` arrives in the hook payload spelled however the session was
launched. On a case-insensitive filesystem the same repo serves as both
`/Users/x/Dev/repo` and `/Users/x/dev/repo`, and `pwd -P` resolves symlinks but
does **not** canonicalise case. When the spellings differ the strip no-ops,
`REL_PATH` stays absolute, every `case "$REL_PATH" in docs/specs/*)` match
misses, and the hook exits 0.

**Reproducer:** `tests/hooks/test-spec-approval-trigger.sh` fails from
`/Users/<user>/dev/claude-helpers` and passes from `/Users/<user>/Dev/claude-helpers`.
Verified against a clean-HEAD worktree — only the CWD spelling changes the result.

**Impact:** `scope-guard` (spec-scope enforcement) and `read-guard` are security
relevant. In this condition they are silently off. This is the standing
explanation for the pre-existing benchmark reds.

### P2 — artifact root (F2)

`docs/specs/` is resolved repo-root-relative everywhere. A polyglot repo whose
subtree owns its own `docs/specs/` (25 specs, plus a `CLAUDE.md` declaring the
subtree authoritative) gets its artifacts written to the wrong root, or its
existing specs ignored.

## Design

### Authoritative artifact root

A directory is an **authoritative artifact root** when it is strictly below the
repo root and contains **both** `CLAUDE.md` **and** a `docs/specs/` directory.
Two independent signals are required so that neither a stray `docs/specs/` nor a
stray `CLAUDE.md` alone can hijack resolution.

Resolution order (first hit wins), mirroring `resolve-tech-stack.sh` so the two
resolvers are learnable as one idea:

1. `$MTK_ARTIFACT_ROOT` — explicit session override.
2. Nearest ancestor at/below the target carrying `<dir>/.claude/artifact-root`
   (an explicit opt-in marker; contents ignored).
3. Nearest ancestor strictly below the repo root with both `CLAUDE.md` and
   `docs/specs/`.
4. The repo root — the long-standing default.

**Backward compatible by construction:** a repo with no qualifying subtree
resolves to the repo root at step 4, exactly as today.

### Path spelling

Add `mtk_repo_relative_path <file> <root>` to `hooks/lib/hook-io.sh`, next to
Wave 1's `mtk_path_is_within`. Fast string strip first (the common case, no
forks); otherwise walk up from the file comparing by device+inode (`-ef`),
accumulating the tail. The answer never depends on spelling. Returns 1 when the
file is genuinely outside the root — callers keep their existing "not mine" path.

## Change Manifest

See `2026-08-11-artifact-root-and-path-spelling.json`.

## Out of scope

- Moving `tasks/`, `.mtk/`, or `.claude/` to a per-subtree root. Only the
  artifact root (`docs/specs`, `docs/plans`) is in scope.
- Multi-root fan-out (one command operating on several subtrees at once).
- `scripts/run-benchmarks.sh` builds its own throwaway fixture repo and asserts
  against it; it is not a real consumer and is not rewired.

## Success Criteria

1. `mtk_repo_relative_path` returns the same repo-relative path for a file
   addressed through any spelling of the root (case variant, symlink).
2. `tests/hooks/test-spec-approval-trigger.sh` passes from BOTH the capital and
   lowercase spellings of the checkout path.
3. `resolve-artifact-root.sh` returns the repo root for a repo with no
   qualifying subtree (backward compatibility).
4. It returns the subtree for a subtree carrying both `CLAUDE.md` and
   `docs/specs/`, and for one carrying `.claude/artifact-root`.
5. `$MTK_ARTIFACT_ROOT` overrides all of the above.
6. Full hook suite green from both path spellings; `validate-toolkit.sh` passes.

## Security Impact

**Elevated — this restores two guards.** `scope-guard.sh` and `read-guard.sh`
currently no-op under a path-spelling mismatch. After P1 they match correctly,
which means they will begin blocking edits they previously let through. That is
the intended behavior, and it is a behavior change for anyone who has been
working in the mismatched condition.
