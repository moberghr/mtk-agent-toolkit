---
name: bootstrap-supporting-files
description: Once-consulted setup-bootstrap supporting-file procedures (git hook, CI gate, skills/agents, review list, tasks dir, ignore files, analyzer, companion plugin, tooling, version stamp, cross-agent) plus STEP 3.6 stack-reference pruning and the typescript package-manager note. Read on-demand by setup-bootstrap at STEP 4, STEP 3.6, and STEP 0.
globs: [".claude/skills/setup-bootstrap/**"]
alwaysApply: false
---

# Setup Bootstrap — Supporting Files & Once-Consulted Procedures

Read this companion from `setup-bootstrap` STEP 4 (supporting files), STEP 3.6 (stack-reference pruning), and STEP 0 (typescript package-manager note). The never-overwrite and ask-don't-assume decisions are surfaced as binding reminders in SKILL.md; the full procedures live here.

### Git Pre-Commit Hook

Install the deterministic linter as a git pre-commit hook so critical findings (secrets, raw SQL, etc.) are reported on every commit.

The hook is a small, **stable shim** (`hooks/git-hooks/pre-commit` in the plugin) that bootstrap **copies** into the target repo. It pins no plugin version: on every commit it resolves the current MTK install — `$MTK_PLUGIN_ROOT` if set, otherwise the newest installed version under `~/.claude/plugins/cache/*/mtk/*/` — and runs that version's `pre-commit-linters.sh`. Never install it as a symlink into the plugin cache: a link to `…/mtk/<version>/…` freezes the linter at install time and dangles after a cache cleanup, and git then skips the hook without a word.

1. **If `.git/hooks/pre-commit` does not exist** — copy the shim:
   ```bash
   HOOK_TARGET=".git/hooks/pre-commit"
   HOOK_SOURCE="${MTK_ROOT:-$(pwd)}/hooks/git-hooks/pre-commit"  # absolute
   if [ ! -f "$HOOK_SOURCE" ]; then
     echo "⚠️ Hook source not found at $HOOK_SOURCE — skipping git hook install."
   else
     mkdir -p .git/hooks && cp "$HOOK_SOURCE" "$HOOK_TARGET" && chmod +x "$HOOK_TARGET"
   fi
   ```
2. **If it exists and is ours** — a copy of the shim (`grep -q mtk-precommit-shim "$HOOK_TARGET"`), or a legacy symlink whose `readlink` target ends in `/mtk/<version>/hooks/git-hooks/pre-commit` (dangling or not) — replace it with a fresh copy of the shim (`rm -f "$HOOK_TARGET"` first, then step 1's `cp`). Test with `[ -e "$HOOK_TARGET" ] || [ -L "$HOOK_TARGET" ]`: `-e` alone is false for a dangling link.
3. **If `.git/hooks/pre-commit` exists but is something else** — do NOT overwrite. Print a warning that interpolates the **resolved absolute `$HOOK_SOURCE`** from step 1:
   ```
   ⚠️ Existing git pre-commit hook found at .git/hooks/pre-commit.
   MTK's deterministic linter was NOT installed as a git hook.
   To chain it manually, copy the shim next to your hook and call it from there:
     cp "/absolute/path/to/plugin/hooks/git-hooks/pre-commit" .git/hooks/mtk-pre-commit
     .git/hooks/mtk-pre-commit || exit 1   # add this line to your existing hook
   ```
   **Never print that path repo-relatively.** `hooks/git-hooks/pre-commit` and `hooks/pre-commit-linters.sh` exist only in the plugin checkout, never in the bootstrapped repo, so a relative `hooks/git-hooks/pre-commit` sends the engineer hunting for a file that isn't there. The same rule binds anything written into the generated `AGENTS.md`: reference the linter by its resolved absolute path or by the resolver snippet — never as a bare repo-relative `hooks/…` path.

The hook runs the resolved plugin's `pre-commit-linters.sh --cached` (< 1 second) against **this repo's** staged changes — it loads pattern packs from the plugin but diffs the repo being committed to. It is **non-blocking by default**: findings are printed and the commit proceeds. `MTK_PRECOMMIT_BLOCK=1` makes critical findings (and a linter that fails to run) block the commit. If no linter can be found it prints a one-line notice and exits 0 (never a silent pass, never a hard block for a tooling gap). Engineers bypass with `git commit --no-verify`. The full AI review (`/mtk review before commit`) remains a separate, manual step.

### CI PR Templates (optional)

Two PR templates are available for teams that want lint/review on GitHub PRs: `templates/ci/pr-lint.yml` (deterministic linter only, no secrets) and `templates/ci/pr-review.yml` (adds AI review; needs `ANTHROPIC_API_KEY`). Both check out the MTK toolkit alongside the PR and run its linter/rubric against the target checkout — nothing is vendored in. Mention them in the STEP 5 report as optional copy-installs; do not install them automatically.

### Skills and Agents
Ensure the following files exist:
- `.claude/skills/implement/SKILL.md` — main implementation loop
- `.claude/skills/fix/SKILL.md` — quick fix loop
- `.claude/skills/pre-commit-review/SKILL.md` — pre-commit security review
- `.claude/skills/spec-driven-development/SKILL.md`
- `.claude/skills/incremental-implementation/SKILL.md`
- `.claude/skills/planning-and-task-breakdown/SKILL.md`
- `.claude/skills/code-review-and-quality/SKILL.md`
- `.claude/skills/tech-stack-{stack}/SKILL.md` — for the active stack
- `.claude/agents/compliance-reviewer.md`
- `.claude/agents/test-reviewer.md`
- `.claude/agents/architecture-reviewer.md`
- `AGENTS.md`

If any are missing, tell the engineer to re-install the MTK plugin from the marketplace: `/plugin marketplace add moberghr/moberg-plugins` then `/plugin install mtk@moberg-plugins`.

### Pre-Commit Review List

Generate `.claude/references/pre-commit-review-list.md` based on audit findings.

If the file already exists, leave it alone.

**Selection:**

1. Read the active tech-stack skill's `## Pre-Commit Review Items` section — a list of conditional items tagged by trigger tool, e.g. `[EF Core] …`, `[React] …`.
2. Keep each item whose trigger tool was detected in the STEP 2 scan. Drop the rest.
3. Append the three stack-agnostic always-include items:
   - No PII in logs
   - Tests for new public methods
   - No hardcoded secrets
4. **Cap at 10 items.** If the kept set exceeds 10, keep the ones most likely to be violated.

### Tasks Directory
Create the `tasks/` directory if it doesn't exist:
```bash
mkdir -p tasks
```

Create `tasks/lessons.md` if it doesn't exist (header only).

Add `tasks/todo.md` and `CLAUDE.local.md` (personal, opt-in constitution companion — instructions capture mode (`/mtk capture instructions`) writes personal learnings here; never auto-created) to `.gitignore` if not already there. Do NOT gitignore `tasks/lessons.md`.

### Learnings Store Seed

Ten skills retrieve lessons through `scripts/learnings.sh query`, which reads the structured store at `.mtk/learnings.jsonl` — **not** `tasks/lessons.md`. A repo whose lessons live only in markdown therefore answers every lesson query with nothing, in every session, forever, and the skill proceeds believing no lesson applied. Seed the store whenever `tasks/lessons.md` has content:

```bash
LS="$([ -n "${MTK_HELPER_ROOT:-}" ] && echo "$MTK_HELPER_ROOT/scripts/learnings.sh" || ([ -f scripts/learnings.sh ] && echo scripts/learnings.sh || echo "${MTK_ROOT:-.}/scripts/learnings.sh"))"
if [ -f "$LS" ] && [ -s tasks/lessons.md ] && [ ! -s .mtk/learnings.jsonl ]; then
  bash "$LS" migrate
fi
```

`migrate` is idempotent (already-migrated guard plus title-hash dedup), so a re-run of bootstrap adds nothing. Skip silently when `tasks/lessons.md` is header-only — a fresh repo has nothing to migrate. Report the entry count in the STEP 5 report so the engineer can see lessons are actually reachable.

Verify with `bash "$LS" query --phase any --max 3`. The script names its empty state on stderr — no store / empty store / N scanned, 0 matched — so "nothing came back" is diagnosable rather than silent.

### .mtkignore (S1.14)

Create `.mtkignore` at the repo root if missing — same syntax as `.gitignore`, single source of truth for MTK scans (audit, repomap). Idempotent: never overwrite existing. Starter content: `graphify-out/`, `docs/translations/`, `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`. Committed so the team shares one set of exclusions.

### .claudeignore (stack-aware)

Create `.claudeignore` at the repo root if missing — same `.gitignore` syntax, read natively by Claude Code to keep dependency and build directories out of search/read results (a per-repo context saver, distinct from `.mtkignore`, which only MTK's own scans consume). Idempotent: never overwrite existing. Committed so the team shares one set of exclusions.

The floor (all stacks) mirrors the built-in scan defaults in `hooks/lib/mtkignore.sh` — keep the two in sync. Append the stack-specific caches/outputs for the detected `.claude/tech-stack`:

```bash
if [ ! -f .claudeignore ]; then
  {
    # Floor — dependency/build dirs, all stacks. Keep in sync with the built-in
    # defaults in hooks/lib/mtkignore.sh.
    printf '%s\n' .git/ node_modules/ dist/ bin/ obj/ .venv/ venv/ __pycache__/
    # Stack-specific caches/outputs the floor does not cover.
    stack=""; [ -f .claude/tech-stack ] && stack="$(tr -d '[:space:]' < .claude/tech-stack)"
    case "$stack" in
      dotnet)     printf '%s\n' TestResults/ '*.user' ;;
      python)     printf '%s\n' .pytest_cache/ .mypy_cache/ .ruff_cache/ '*.egg-info/' ;;
      typescript) printf '%s\n' .next/ build/ coverage/ .turbo/ ;;
    esac
  } > .claudeignore
fi
```

Report one line in STEP 5 (`generated` or `preserved (existing)`). Do NOT add `.claudeignore` to the `.gitignore` — it must be committed.

### .gitignore: `.mtk/` (always)

Unconditionally ensure `.mtk/` is in the repo's `.gitignore` (create the file if missing; skip when an equivalent line already exists, so it is idempotent). `.mtk/` holds workflow artifacts, evidence logs, metrics and compaction archives, not only analyzer output, so this does not depend on the analyzer step below.

```bash
if ! grep -qxE '/?\.mtk/?' .gitignore 2>/dev/null; then
  # A last line without a newline would otherwise absorb the new entry.
  if [ -s .gitignore ] && [ -n "$(tail -c 1 .gitignore)" ]; then printf '\n' >> .gitignore; fi
  printf '.mtk/\n' >> .gitignore
fi
```

### Analyzer Configuration (opt-in)

After distributing references, ask the engineer whether to configure recommended analyzers for the detected stack. This sets up Roslyn analyzers (.NET), ruff/mypy (Python), or biome/tsc-strict (TypeScript) so that build output feeds into the review pipeline with `source: "analyzer"` and `confidence: 100`.

1. Read `.claude/references/{stack}/analyzer-config.md` for the recommended packages and config
2. Ask: "Would you like to set up recommended analyzers for {stack}? This adds [packages] to your build and surfaces semantic findings in the review pipeline. (y/n)"
3. If yes: generate the appropriate config (`Directory.Build.props` additions for .NET, `pyproject.toml [tool.ruff]` for Python, `biome.json` for TypeScript)
4. If no: skip — the regex linter and AI review still work without analyzers

### Companion Plugin: dotnet-claude-kit (.NET only)

If the detected stack is `dotnet`, check whether the `codewithmukesh/dotnet-claude-kit` plugin is installed:

```bash
# Check if dotnet-claude-kit is available
find ~/.claude/plugins -maxdepth 4 -name "plugin.json" -path "*dotnet-claude-kit*" 2>/dev/null | head -1
```

If NOT found, recommend installation (recommend-only — never auto-install):

> **Recommended companion:** `codewithmukesh/dotnet-claude-kit` adds 15 Roslyn-powered MCP tools (anti-pattern, circular-dependency, dead-code detection, project/dependency graph, type hierarchy). With it installed, `DetectAntiPatterns` findings feed the review as `source: "analyzer"` confidence 100, the graph tools enable scoped builds on large solutions, and `FindDeadCode`/`DetectCircularDependencies` catch issues no AI review reliably finds. Install via the Claude Code plugin marketplace. MTK works without it — the regex linter, build-output parser, and AI review still function.

If found, note it in the bootstrap output: "dotnet-claude-kit detected — Roslyn MCP tools available for the review pipeline."

### Recommended Tooling (recommend-only, all stacks)

Print a consolidated list of recommended MCP servers, plugins, and editor integrations. **Never auto-install** — these are user-preference, not per-repo artifacts.

The docs live in the plugin only at `$CLAUDE_PLUGIN_ROOT/docs/recommended-tooling/{shared,<stack>}.md`. `setup-bootstrap` reads them and prints inline; do **not** copy into the target repo. Output two headed blocks:

```
━━━ Recommended Tooling — Stack-agnostic ━━━
[contents of docs/recommended-tooling/shared.md]

━━━ Recommended Tooling — {stack} ━━━
[contents of docs/recommended-tooling/{stack}.md]
```

Close with: `Install manually when you're ready — MTK works without any of these.`

**Do not:** auto-install, ask per-tool questions, copy these files into the repo, or suppress on re-run (printing is cheap and surfaces new recommendations after MTK updates).

**Skip when:** plugin docs are missing (warn once, continue).

### Version Stamp

Write **one** provenance file: `.claude/mtk-version.json`. It records the installed MTK version (for session-start drift detection) and the coding-guidelines pin (sha + sha256) that STEP 1 fetched with. Do **NOT** write a slim `.claude/manifest.json` into target repos — the toolkit's full manifest lives only at `$CLAUDE_PLUGIN_ROOT/.claude/manifest.json`. Scripts (`generate-tool-configs.sh`, `mtk-doctor.sh`) resolve it from the plugin root.

A `coding-guidelines` block already in `.claude/mtk-version.json` is the repo's own pin (written by `/mtk-setup --update-guidelines`, and the one `scripts/update-guidelines.sh` reads first): carry it forward unchanged. Otherwise copy the plugin manifest's block. `scripts/stamp-version.sh` is the one writer of the stamp and does both; `setup-refresh` runs the same script when a refresh finishes, so the stamp always names the version whose setup files the repo has:

```bash
bash "${MTK_ROOT:-.}/scripts/stamp-version.sh" --manifest "${MTK_ROOT:-.}/.claude/manifest.json"
```

Omit the `coding-guidelines` block when no external guidelines were pinned (placeholder stacks). Committed (not gitignored).

### Cross-Agent Compatibility

`AGENTS.md` is authored in STEP 3 from `.claude/references/root-agents-md-template.md` — it is the canonical constitution, not a generated summary, and Codex, Cursor, Copilot, Windsurf and OpenCode all read it directly. Nothing in this step regenerates it.

1. **`scripts/generate-agents-md.sh` is legacy.** It remains for repos whose `AGENTS.md` carries its own auto-generated marker (`Auto-generated by MTK` in the first 10 lines — a references summary produced before the inversion), and it still regenerates that file normally. It declines only when `AGENTS.md` is the **canonical** constitution: it exists, is *not* generator-marked, and `CLAUDE.md` is absent or a shim holding a line matching `^@AGENTS\.md`. Then a bare run prints a one-line note and exits 0 without writing, so running it against an authored constitution is harmless, and `--force` does not override that — it exits 1 rather than replace authored rules with a summary. Both refusals apply only to a write targeting `AGENTS.md` itself; an explicit output path is always honoured. Do not pass it in bootstrap.
2. On a legacy repo it keeps its old behavior: custom sections (prefixed `## Custom:`) are preserved across regeneration, and a marked `AGENTS.md` with no `## Custom:` sections is regenerated from current references.
3. **Size budget — same instruction-budget discipline as the rest of the constitution** (compliance degrades past ~150 instructions). **Target 60–80 lines, 120 hard cap**; point to `.claude/rules/` and references rather than restating them.
4. **Git-ignore check** — surface in the STEP 5 report if the deliverable won't be committed: `git check-ignore -q AGENTS.md && echo "⚠️ AGENTS.md is git-ignored — authored in STEP 3 but will NOT be committed."`
5. **Cross-agent mirrors (Cursor/Copilot/Windsurf/Gemini/Cline) — ask, don't assume** (real teams have deliberately chosen Claude-only configs before):
   - Interactive: ask once via `AskUserQuestion` — "Generate cross-agent configs?" options: "AGENTS.md only (Recommended)" / "All tools (AGENTS.md + Cursor/Copilot/Windsurf/Gemini/Cline)" / "None (Claude Code only)".
   - `--non-interactive`: default to **AGENTS.md only**; skip mirrors and note in the STEP 5 report: "cross-agent mirrors skipped — re-run interactively or run `scripts/generate-tool-configs.sh --all`".
   - On "All tools": run `bash scripts/generate-tool-configs.sh --all` (if the script exists) to generate:
     - `.cursor/rules/mtk-*.mdc` — glob-scoped Cursor rules (applyTo globs from manifest); full content, because `.mdc` glob scoping expresses something `AGENTS.md` cannot
     - `.github/copilot-instructions.md` — **pointer mode**: title, marker, a line naming `AGENTS.md` as the canonical instructions, and the `## Critical Rules` body of the resolved constitution
     - `.windsurfrules` — pointer mode, same shape
     - `GEMINI.md` — Gemini CLI guidelines, full content (Gemini's `@import` behavior is unverified)
     - `.clinerules` — pointer mode, same shape
   - Regardless of the answer: a tool with an existing config (marker or not) is regenerated/preserved per the existing marker rules — never orphan an already-adopted tool.

### Stack Reference Pruning (STEP 3.6)

`setup-audit` writes `.claude/detected-tools.json` (see audit STEP 2.6). Reference files under `.claude/references/{stack}/` declare a `tools:` array in their YAML frontmatter listing which tools they cover. **Skip files whose `tools:` array does not intersect the detected tools** — this is what stops e.g. Drizzle/Prisma/TanStack-Query data-layer guidance from shipping into a Prismic-only repo.

**Procedure:**

1. If `.claude/detected-tools.json` is missing → ship every stack reference (current bloat-prone behavior). Print a one-line warning so the engineer knows pruning was skipped.
2. Otherwise, build the union set: `detected = framework ∪ data_layer ∪ test_framework ∪ additional ∪ {stack}`.
3. **F11:** when `secondary_stacks` is non-empty, the candidate set spans `.claude/references/{stack}/` for the primary stack **and every secondary stack** — same `detected` filter applies to all.
4. For each candidate stack reference (not already excluded by `status: placeholder`):
   - Read its frontmatter `tools:` array.
   - **No `tools:` declared** → ship (treat as alwaysApply for the stack).
   - **`tools:` ∩ `detected` non-empty** → ship.
   - **`tools:` ∩ `detected` empty** → SKIP. Do NOT copy into the target repo.
5. Print one summary line per stack: `references: shipped <N>, pruned <M> (no detected tool match)`. List the pruned filenames so the engineer can override if a tool was missed in detection.

**Override:** Engineers who want a pruned file anyway can either (a) add the relevant tool to `detected-tools.json` and re-run setup, or (b) `cp` the file from `$CLAUDE_PLUGIN_ROOT/.claude/references/{stack}/<file>.md` into their repo manually. Bootstrap never deletes manually-placed reference files.

**Detection cache:** `setup-bootstrap` re-runs `setup-audit` (or skips if a recent `detected-tools.json` exists, < 7 days old by default — same TTL convention as the architecture-principles cache).

### Package manager + React Native/Expo (typescript only)

When the active stack is `typescript`, write `package_manager` (from the STEP 0 `setup-detect.sh --json` output) to `.claude/tech-stack-pm` so workflow skills can substitute `<pm>` in commands:
```bash
echo "$PM" > .claude/tech-stack-pm
```
If `multiple_lockfiles` is true, warn the engineer — that's almost always a mistake — and note that `package_manager` was picked automatically by priority (bun > pnpm > yarn > npm); do not prompt.

`react_native.detected` / `react_native.expo` feed `setup-audit`'s `detected-tools.json` (audit STEP 2.6) and reference pruning (STEP 3.6): when `detected` is true, add `react-native` (and `expo` when `react_native.expo` is true) to detected tools. Stack stays `typescript`.
