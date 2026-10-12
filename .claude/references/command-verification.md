---
name: command-verification
description: Command verification (F7) for setup-bootstrap — assemble build/test/format commands, run verify-commands.sh, apply verified/failed/skipped/unavailable outcomes to the generated Tech Stack section. Read on-demand by setup-bootstrap STEP 3.5a.
globs: [".claude/skills/setup-bootstrap/**"]
alwaysApply: false
---

# Command Verification (F7)

Read this companion from `setup-bootstrap` STEP 3.5a ("Command verification").
Unless `--no-verify-commands` was passed (see `## Modes`), verify the exact
commands you are about to publish in the Tech Stack section **before** writing
CLAUDE.md.

## 1. Assemble the commands

From the tech stack skill's `## Build & Test Commands` section:

- **build** — the full build command as-is (e.g. `dotnet build`, `npm run build`).
- **test** — the stack's list/collect-only variant when the tech stack skill
  documents one (e.g. `dotnet test --list-tests`, `pytest --collect-only -q`,
  vitest/jest `--listTests`). If the stack skill documents no list-only
  variant, do not run the full test suite — mark `test` as `skipped` directly
  (no command sent to the verifier).
- **format** — the check-mode variant of the format command (e.g.
  `dotnet format --verify-no-changes`, `ruff format --check`, biome/prettier
  `--check`), not the mutating form used by `hooks/format-on-edit.sh`.

## 2. Run the verifier

Pipe the assembled entries as `name<TAB>command` lines (path resolved per
`## MTK File Resolution` — `scripts/` is always project-relative):

```bash
printf 'build\t%s\ntest\t%s\nformat\t%s\n' "$BUILD_CMD" "$TEST_CMD" "$FORMAT_CMD" | \
  bash scripts/verify-commands.sh --timeout 300
```

Omit a `name<TAB>command` line entirely for any entry already marked `skipped`
in step 1 (e.g. no list-only test variant) rather than sending it to the
verifier.

## 2.5 Tree-mutation guard

Some verified commands mutate the tree as a side effect (e.g. `dotnet build`
regenerating `package-lock.json` on SPA-integrated projects). Capture `git
status --porcelain` before running step 2; after it finishes, diff against a
fresh `git status --porcelain` and `git checkout -- <path>` any **tracked**
file newly modified by the verification run (never one already dirty before
this step). List restored paths in the STEP 5 report line: `command
verification restored N build-side-effect file(s)`. Newly created
**untracked** files under build output dirs are left alone (gitignored
normally).

## 3. Apply outcomes

When writing the Tech Stack section:

- **`verified`** — include the command line normally. Add exactly ONE summary
  comment line directly under the Tech Stack heading:
  `<!-- verified: build ✓ test ✓ format ✓ (YYYY-MM-DD) -->`, listing only the
  names that came back `verified` (e.g.
  `<!-- verified: build ✓ format ✓ (2026-07-03) -->` if `test` was skipped or
  failed).
- **`failed`** — still write the command line (never drop it), but append
  `[UNVERIFIED — <first line of detail from verify-commands.sh output>]` to
  it, and add a STEP 5 report line for that command. **A failed command must
  NEVER appear in CLAUDE.md without this annotation.**
- **`skipped`** — write the command line with no annotation; note the skip in
  the STEP 5 report.
- **verifier unavailable** — if `scripts/verify-commands.sh` is missing or
  returns non-JSON (old install, exit 127), annotate EVERY command
  `[UNVERIFIED — verify-commands.sh unavailable]` and report
  `Command verification: skipped — verify-commands.sh not found`. The
  never-unannotated-failure invariant from the `failed` branch above must hold
  even when the verifier itself is absent.

## 4. Non-blocking

Non-interactive runs never block on a failing command — annotate per step 3
and continue; do not prompt, retry, or abort the bootstrap.

## 5. With `--no-verify-commands`

Skip this entire subsection — no commands are executed, no
`<!-- verified: ... -->` stamp is written, and the STEP 5 report notes
`Command verification: skipped via --no-verify-commands`.
