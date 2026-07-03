---
name: mtk-setup
description: One-stop setup entry point that bootstraps a repo or re-runs architecture audit
type: skill
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
argument-hint: [--audit|--audit-only] [--merge] [--preview] [--non-interactive] [--no-verify-commands] [--update-guidelines] [--refresh [--dry-run]] [--check] [--converge]
user-invocable: true
---

# MTK Setup — Unified Entry Point for Bootstrap and Audit

You are the single setup entry point for MTK. You dispatch to the right workflow skill based on the engineer's argument and the current state of the repo.

## Overview

MTK distinguishes between two setup tasks:

- **Bootstrap (first-time setup):** Detect tech stack, pull coding guidelines, audit the codebase once, generate `CLAUDE.md`, `.claude/tech-stack`, and `.claude/references/architecture-principles.md`. This is the one-time preparation.
- **Re-audit:** Re-run the architectural audit only. Regenerates `.claude/references/architecture-principles.md` (and `conventions.md`) to reflect current reality. Use after significant architectural change.
- **Merge:** Unify architecture audits from multiple repos (e.g., a team hub repo that aggregates `payfac`, `collection-system`, etc.) into a single team-wide document.
- **Refresh:** Drift-scoped refresh of ALL generated rules and findings (architecture-principles, conventions, detected-tools, reference pruning, AGENTS.md/tool configs, indexes) — not just the audit doc. `--check` is the CI gate that reports staleness without writing anything.
- **Converge:** Inverse of refresh — code is judged against the agreed `architecture-principles.md`/`conventions.md`, and violations are reported as graded work items (blocking/flag/note), never auto-fixed.

## When To Use

- First time onboarding a repo → run `/mtk-setup` with no flags.
- Architecture has drifted and you want `architecture-principles.md` refreshed → `/mtk-setup --audit`.
- You have audit files from multiple repos in `.claude/references/audits/` and want one unified doc → `/mtk-setup --merge`.
- Generated docs (architecture-principles, conventions, detected-tools, AGENTS.md, indexes) have drifted, or you just merged significant changes → `/mtk-setup --refresh` (add `--dry-run` to preview first).
- CI or a quick staleness question ("are the generated docs still accurate?") → `/mtk-setup --check`.
- You want to know where the *code* has drifted from the agreed `architecture-principles.md`/`conventions.md`, graded as reviewable work items → `/mtk-setup --converge`.

## Workflow

### STEP 0: Parse Arguments

Parse the argument string into a mode and flags:

| Flag | Meaning |
|---|---|
| `--audit` or `--audit-only` | Run audit workflow only (skip stack detection, CLAUDE.md generation) |
| `--merge` | Multi-repo unification mode (implies audit) |
| `--preview` | Show proposed changes, ask before writing (bootstrap only) |
| `--non-interactive` | Skip interview questions (bootstrap only) |
| `--no-verify-commands` | Skip STEP 3.5a's build/test/format command execution during CLAUDE.md generation (bootstrap only) |
| `--update-guidelines` | Bump the pinned `moberghr/coding-guidelines` SHA in `.claude/manifest.json` to current HEAD and refresh recorded sha256 hashes. Does **not** re-run bootstrap; engineer must invoke `/mtk-setup` afterward if they want the new guidelines applied. Cannot be combined with other flags. |
| `--refresh` | Drift-scoped refresh of ALL generated rules and findings (not just the audit doc). Delegates to `setup-refresh`. |
| `--dry-run` | Only with `--refresh`: print the invalidation plan, write nothing. |
| `--check` | CI staleness gate — run `scripts/setup-refresh-plan.sh --check`, print its output, propagate its exit code. Writes nothing. |
| `--converge` | Inverse of `--refresh`: judge the code against `architecture-principles.md`/`conventions.md` and report drift as graded work items (blocking/flag/note). Delegates to `setup-converge`. Read-only outside `.claude/.mtk-cache/`. |

Default mode (no flags): **bootstrap**.

Flag combination rules:
- `--update-guidelines` is mutually exclusive with every other flag. Reject with a clear message if combined.
- `--merge` implies audit and is mutually exclusive with `--non-interactive`.
- `--refresh` and `--check` are each mutually exclusive with `--audit`, `--merge`, `--update-guidelines`, and each other. Reject with a clear message if combined.
- `--converge` is mutually exclusive with `--audit`, `--merge`, `--update-guidelines`, `--refresh`, and `--check`. Reject with a clear message if combined.
- `--dry-run` requires `--refresh`. Reject with a clear message if passed without it.
- `--no-verify-commands` is valid only in bootstrap mode. Reject with a clear message if combined with `--audit`, `--merge`, `--refresh`, `--check`, `--converge`, or `--update-guidelines`.
- `--refresh --non-interactive` is allowed: the refresh runs headless, and every engineer-edited file defers to `NEEDS REVIEW` per the regen-diff-contract §6 — proposals are never force-applied without the interactive gate.

### STEP 1: Decide the Target Skill

| Argument pattern | Invoke |
|---|---|
| `--update-guidelines` present | Inline workflow (see below). Does not invoke a target skill. |
| `--check` present | Inline workflow (see below). Does not invoke a target skill. |
| `--refresh` present | `.claude/skills/setup-refresh/SKILL.md` (pass `--dry-run` through) |
| `--converge` present | `.claude/skills/setup-converge/SKILL.md` (no flags) |
| `--merge` present | `.claude/skills/setup-audit/SKILL.md` (pass `--merge`) |
| `--audit` or `--audit-only` present | `.claude/skills/setup-audit/SKILL.md` (no flags) |
| None of the above | `.claude/skills/setup-bootstrap/SKILL.md` (pass `--preview` / `--non-interactive` / `--no-verify-commands` through) |

**Inline workflow for `--update-guidelines`:**

1. Resolve current HEAD SHA and validate it before using it for anything:
   ```bash
   CURRENT_SHA=$(git ls-remote https://github.com/moberghr/coding-guidelines HEAD | awk '{print $1}')
   if [[ ! "$CURRENT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
     echo "ERROR: git ls-remote did not return a valid 40-char SHA (got: '$CURRENT_SHA') — network issue or unreachable repo; stopping." >&2
     exit 1
   fi
   ```
2. Read pinned SHA from the resolved pin file: `PM="${CLAUDE_PLUGIN_ROOT:-.}/.claude/manifest.json"; [ -f "$PM" ] || PM=".claude/mtk-version.json"`. Read `coding-guidelines.sha` from `$PM` (both files carry this key at the same path). If identical to `$CURRENT_SHA`, report "Already at HEAD ($SHA). Nothing to do." and exit.
3. For each file listed in `coding-guidelines.files` (read from `$PM`), fetch at the new SHA and compute sha256 — compute **all** files' hashes before writing anything (no partial pin updates):
   ```bash
   curl -fsSL "https://raw.githubusercontent.com/moberghr/coding-guidelines/$CURRENT_SHA/$FILE_PATH" | sha256sum | awk '{print $1}'
   ```
   Check `curl`'s exit status for every file (e.g. via `${PIPESTATUS[0]}`, since it's piped into `sha256sum`) — `-f` makes curl itself fail on HTTP error responses instead of emitting an error page as if it were file content. If any fetch fails, STOP immediately: report which file(s) failed and leave `$PM` untouched — do not write a pin update for only some of the files. Only proceed to step 5's write once every file's hash has been computed successfully.
4. Print a diff summary: old SHA → new SHA, plus any sha256 changes per file.
5. **Write rule — never write into the plugin cache.** Determine the write target from `$PM`, not just from `CLAUDE_PLUGIN_ROOT` being set (the fallback below can also resolve to a plugin path):
   - If `$PM` is plugin-prefixed — under `$CLAUDE_PLUGIN_ROOT` or under `~/.claude/plugins` (a marketplace install reading the plugin's own manifest) — do **not** write there. Instead write the updated pin to the repo-local `.claude/mtk-version.json`, under its `coding-guidelines` block (`repo`, `sha`, `files.<path>`) — create the block if absent, leaving every other top-level key (`version`, `installed`, `source`) untouched.
   - Otherwise — `$PM` is the local `.claude/manifest.json` (the toolkit repo itself, no plugin prefix), or `$PM` already fell back to `.claude/mtk-version.json` (no manifest reachable at all) — update that same file in place: `coding-guidelines.sha` and each `coding-guidelines.files.<path>` value.
6. Tell the engineer: "Guidelines pin updated in `<file>`. Run `/mtk-setup --audit` or `/mtk-setup` to apply the new guidelines to this repo." The report line MUST name the file that now carries the updated pin (`.claude/manifest.json` or `.claude/mtk-version.json`). Do **not** auto-invoke bootstrap — the engineer decides when to apply.

**Inline workflow for `--check`:**

1. Run `bash scripts/setup-refresh-plan.sh --check` (resolve the script path per the MTK File Resolution section).
2. Print its output verbatim — the per-artifact plan table plus the summary line.
3. Propagate its exit code as the outcome: `0` → report "✅ Generated docs are fresh."; `1` → report "⚠️ Staleness detected — run `/mtk-setup --refresh` to reconcile."; `2` → report the usage/setup error.
4. Write **nothing**. `--check` is a read-only gate, suitable for CI.

**Ambiguity check:** if the repo has no `.claude/tech-stack` file and the engineer passed `--audit`, warn:

> "No tech stack detected — this looks like a first-time setup. Audit alone won't generate CLAUDE.md. Run `/mtk-setup` with no flags to do a full bootstrap. Proceed with audit only? [y/N]"

Use `AskUserQuestion` for this prompt.

For `--refresh` on a repo with no `.claude/tech-stack`, do **not** offer to proceed — `setup-refresh` hard-stops on an un-bootstrapped repo (its STEP 0 preconditions). Tell the engineer directly: "This repo has not been bootstrapped — run `/mtk-setup` with no flags first; `--refresh` is for re-runs."

For `--converge` on a repo with no `.claude/tech-stack` (or no stamped `architecture-principles.md`/`conventions.md`), do **not** offer to proceed — `setup-converge` hard-stops on an un-bootstrapped/unaudited repo (its STEP 0 preconditions). Tell the engineer directly: "This repo has not been bootstrapped — run `/mtk-setup` with no flags first; `--converge` is for judging code against an already-agreed principles doc."

### STEP 2: Read and Follow the Target Skill

Read the target SKILL.md (paths resolved per the MTK File Resolution section below). Follow every step of that skill inline — do NOT summarize or skip steps. The target skill owns its own verification section; run those checks before reporting back.

### STEP 3: Report

When the target skill completes, print a one-line summary:

```
✅ MTK Setup: [mode] complete in [duration]. See [output file(s)].
```

Where `[mode]` is one of: `bootstrap`, `audit`, `merge`, `refresh`, `check`, `converge`.

## MTK File Resolution

MTK skills and shared references live either in the project (local install) or the plugin cache (marketplace install). Resolve once:

1. If `$CLAUDE_PLUGIN_ROOT` is set, prefix `.claude/skills/` and `.claude/references/` reads with it.
2. Otherwise, if `.claude/skills/context-engineering/SKILL.md` exists locally → project-relative paths work as-is.
3. Otherwise, fall back to `find ~/.claude/plugins -maxdepth 8 -name "SKILL.md" -path "*/mtk/*/context-engineering/*" -type f 2>/dev/null | head -1 | sed 's|/.claude/skills/context-engineering/SKILL.md||'`. If empty, MTK skills are unavailable — warn the engineer and proceed with `CLAUDE.md` only.

Always project-relative (never prefixed): `CLAUDE.md`, `.claude/tech-stack`, `.claude/rules/`, `tasks/`, `docs/`, `.claude/references/architecture-principles.md`, `.claude/references/pre-commit-review-list.md`.

## Verification

- [ ] Correct target skill selected based on flags
- [ ] Target skill's verification section was executed
- [ ] All files the target skill was supposed to create exist
- [ ] Bootstrap mode: `CLAUDE.md`, `.claude/tech-stack`, and `.claude/references/architecture-principles.md` exist
- [ ] Audit mode: `.claude/references/architecture-principles.md` updated
- [ ] Merge mode: unified `.claude/references/architecture-principles.md` written; source audits in `.claude/references/audits/` untouched
- [ ] Refresh mode: `setup-refresh`'s own Verification section executed; refresh report printed with Updated / Created / Preserved / Needs review counts
- [ ] Check mode: plan table printed, exit code propagated, no files written
- [ ] Converge mode: read-only outside `.claude/.mtk-cache/`; report printed with blocking/flag/note counts
