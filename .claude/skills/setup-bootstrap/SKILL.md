---
name: setup-bootstrap
description: One-time repo setup that detects tech stack, audits the codebase, pulls coding guidelines, and generates a project-specific CLAUDE.md
type: skill
user-invocable: false
---

# MTK Setup Bootstrap — Prepare Repository for AI-Assisted Development

## MTK File Resolution

MTK skills and shared references live either in the project (local install) or the plugin cache (marketplace install). Resolve once:

1. If `$CLAUDE_PLUGIN_ROOT` is set, prefix `.claude/skills/` and `.claude/references/` reads with it.
2. Otherwise, if `.claude/skills/context-engineering/SKILL.md` exists locally → project-relative paths work as-is.
3. Otherwise, fall back to `find ~/.claude/plugins -maxdepth 8 -name "SKILL.md" -path "*/mtk/*/context-engineering/*" -type f 2>/dev/null | head -1 | sed 's|/.claude/skills/context-engineering/SKILL.md||'`. If empty, MTK skills are unavailable — warn the engineer and proceed with `CLAUDE.md` only.

Always project-relative (never prefixed): `CLAUDE.md`, `.claude/tech-stack`, `.claude/rules/`, `tasks/`, `docs/`, `.claude/references/architecture-principles.md`, `.claude/references/pre-commit-review-list.md`.

---

You are setting up a repository for the `/mtk` workflows.
Your job is to detect the tech stack, audit the codebase, and generate a tailored `CLAUDE.md` that the implementation and review agents will use as their source of truth.

This bootstrap also prepares the repo for the shared skill layer and OpenCode routing.

## Modes

Parse arguments before starting:

- **`--preview`** — run detection, scan, and interview, then **show the proposed CLAUDE.md + rules files diff** and ask for confirmation via `AskUserQuestion` before writing anything. Use this when the engineer wants to review before commit. Without `--preview`, the bootstrap writes files directly (merge mode is still the default for existing CLAUDE.md).
- **`--non-interactive`** — skip the post-scan interview (STEP 2.5). Use when scripting the bootstrap or when the engineer has no time for questions. Defaults to interactive.

Both flags can combine: `--preview --non-interactive` runs silently but still asks to confirm writes.

## Research-backed constraints (read this first)

The content you generate is subject to an **instruction budget** — Claude's compliance with CLAUDE.md rules degrades uniformly past ~150 total instructions (Anthropic's system prompt already consumes ~50). The ETH Zurich benchmark across 1,188 runs showed LLM-generated CLAUDE.md files performed *worst*. Anthropic's own cookbook CLAUDE.md is ~80 lines. HumanLayer's production file is <60 lines. Boris Cherny (Claude Code creator) uses ~100.

**Therefore:**

1. **Root CLAUDE.md target: 60–80 lines. Hard cap: 120 lines.** If you can't get under 120, something belongs in `.claude/rules/` or a hook, not CLAUDE.md.
2. **Trigger-action, negative phrasing sticks better.** Prefer `WHEN X, DO NOT Y` and `NEVER Z` over `Always follow X`. Use `IMPORTANT:` / `YOU MUST` markers sparingly for the top 1–2 rules.
3. **Mechanize what you can.** If a rule can live in a hook or `settings.json` deny-list, put it there and do NOT duplicate in CLAUDE.md.
4. **No aspirational rules.** Every rule must come from an actual pattern or actual failure mode in this codebase. If you're inventing it, drop it.
5. **No list-of-everything.** Omit rules Claude can figure out from reading the code (e.g., "use async/await" in a JS project).

## File Preservation Policy (non-destructive contract — read before writing anything)

Bootstrap is **additive and merge-only. It NEVER deletes a file it did not generate**, and it never runs `git rm`, `rm`, or a "replace/fresh-generate" sweep over pre-existing files — even if a wrapper, runner, or `--non-interactive` caller asks for "replace mode." There is no replace mode. This contract holds regardless of how the skill was invoked.

- **Only MTK-owned files may be overwritten in place.** An MTK-owned file is one carrying the `<!-- mtk-setup` provenance stamp, OR one of MTK's known generated paths (`CLAUDE.md` root, `.claude/rules/*` in the standard set, `.claude/references/*`, `.claude/tech-stack`, `.claude/settings.json`, `.claude/detected-tools.json`, `.claude/mtk-version.json`, `CODE_INDEX.md`, `pre-commit-review-list.md`). Overwrite means rewrite the body — never `git rm`.
- **Everything else is preserved untouched.** Explicitly, never delete: nested/per-package `CLAUDE.md` (at any path other than root — **even when the repo is NOT classified as a monorepo**), `.claude/CLAUDE.md`, custom `.claude/commands/*`, custom `.claude/rules/*` whose name is outside MTK's standard set, custom `.claude/references/*` the team added, lockfiles (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock`, etc.), source files, and any AI-assistant config the team adopted.
- **Superseding a prior MTK file is the one exception, and it must be loud.** If a re-run legitimately retires an MTK-owned file (e.g., consolidating `coding-style.md` into other rules), remove it explicitly AND list every such removal under "Retired prior MTK files" in the STEP 5 report. Never silently delete. If you are unsure a file is MTK-owned, treat it as hand-authored and preserve it.
- **Stage only your declared output.** When committing, `git add` the specific generated paths — never `git add -A` / `git add .`. That prevents scratch or run-report artifacts from leaking into the commit.
- **Scratch stays out of the tree.** Any run report, review, or eval scratch the operator produces must be written OUTSIDE the repo working tree (or be git-ignored). Bootstrap itself writes no `run-report.md` / `review.md` into the repo.

## STEP 0: Detect Tech Stack

Scan the repo root for tech stack markers:

| Marker files | Tech stack |
|---|---|
| `*.sln`, `*.slnx`, `*.csproj` | `dotnet` |
| `pyproject.toml`, `setup.py`, `requirements.txt`, `Pipfile` | `python` |
| `package.json`, `tsconfig.json` (and no `*.csproj`) | `typescript` (covers React, Next.js, Tauri, Node backends) |
| `go.mod` | `go` (not yet supported — stop and warn) |

Detection commands:
```bash
DOTNET=$(find . -maxdepth 3 -name "*.csproj" -o -name "*.sln" -o -name "*.slnx" 2>/dev/null | head -1)
PYTHON=$(find . -maxdepth 2 -name "pyproject.toml" -o -name "setup.py" -o -name "requirements.txt" -o -name "Pipfile" 2>/dev/null | head -1)
TYPESCRIPT=$(find . -maxdepth 2 -name "package.json" -not -path "*/node_modules/*" 2>/dev/null | head -1)
```

If multiple stacks detected, ask the engineer:
```
question: "Multiple tech stacks detected. Which is the primary stack for this repo?"
header: "Tech stack"
options:
  - label: "dotnet"
    description: ".NET / C# is the primary stack"
  - label: "python"
    description: "Python is the primary stack"
  - label: "typescript"
    description: "TypeScript / JavaScript is the primary stack (React, Next.js, Tauri, Node)"
```

If no supported stack detected, stop and tell the engineer to add a `tech-stack-{name}/` skill or open an issue.

Write the result to `.claude/tech-stack` (plain text, single word):
```bash
echo "dotnet" > .claude/tech-stack
```

> ⚠️ **`.claude/tech-stack` is a FILE, not a directory.** Never include it in a `mkdir -p` list — that will create it as a directory and the `echo > .claude/tech-stack` below will then fail. If you later need to create `.claude/rules/` or other dirs (STEP 4), run that `mkdir -p` separately without `.claude/tech-stack` in the argument list.
>
> ⚠️ **Do not chain `mkdir` + `rm -rf` + `echo >` into one shell command.** Conservative permission modes reject any command that contains `rm -rf`, causing the entire chain to abort. Run each step as its own Bash call so a single denied command doesn't take down the bootstrap.

Then load `.claude/skills/tech-stack-{stack}/SKILL.md` — this is the source of truth for build commands, scan recipes, and reference paths used in the rest of init.

### Tool Prerequisites Check

After detecting the tech stack, run the prerequisites check:

```bash
bash hooks/check-prerequisites.sh
```

This checks for recommended tools (shellcheck, shfmt, jq, plus stack-specific tools like ruff/mypy for Python, dotnet-format for .NET, etc.). Missing tools are reported as warnings in the final report — they never block bootstrap. Include the output in the STEP 5 verification report.

### Package manager auto-detect (typescript only)

When the active stack is `typescript`, also write the detected package manager to `.claude/tech-stack-pm` so workflow skills can substitute `<pm>` in commands. Pick automatically by lockfile priority:

```bash
if [ -f bun.lock ] || [ -f bun.lockb ]; then PM=bun
elif [ -f pnpm-lock.yaml ]; then PM=pnpm
elif [ -f yarn.lock ]; then PM=yarn
else PM=npm  # package-lock.json or no lockfile
fi
echo "$PM" > .claude/tech-stack-pm
```

If multiple lockfiles exist (e.g. both `yarn.lock` and `package-lock.json`), that's almost always a mistake — warn the engineer and pick the highest-priority one. Do not prompt; the priority order is: bun > pnpm > yarn > npm.

### React Native / Expo detection (typescript only)

When the stack is `typescript`, also detect RN/Expo so `setup-audit`'s `detected-tools.json` emits it (audit STEP 2.6) and reference pruning (STEP 3.6) keeps RN-relevant refs. Markers: `react-native`/`expo` in `package.json` deps, `app.json` / `app.config.*`, `metro.config.*`. If any match, add `react-native` (and `expo` when the `expo` dep or `app.config.*` is present) to detected tools. Stack stays `typescript`.

```bash
grep -lE '"(react-native|expo)"[[:space:]]*:' package.json 2>/dev/null
test -f app.json || ls app.config.* metro.config.* >/dev/null 2>&1
```

## STEP 1: Pull External Standards

### Coding Guidelines

Check the active tech stack skill's `## Coding Style Reference` section. If it lists a remote source URL, fetch it:

Read the pinned revision and expected sha256 from the **plugin's** manifest at `${CLAUDE_PLUGIN_ROOT}/.claude/manifest.json` (`coding-guidelines.sha` and `coding-guidelines.files`). The slim `.claude/mtk-version.json` written into the target repo also carries this pin so re-fetches without a plugin context still work. **Never fetch from `main`.** The pin is bumped by `/mtk-setup --update-guidelines` only — this guarantees every bootstrap is reproducible and auditable.

For `dotnet`:
```bash
PLUGIN_MANIFEST="${CLAUDE_PLUGIN_ROOT:-.}/.claude/manifest.json"
SHA=$(python3 -c "import json; print(json.load(open('$PLUGIN_MANIFEST'))['coding-guidelines']['sha'])")
EXPECTED=$(python3 -c "import json; print(json.load(open('$PLUGIN_MANIFEST'))['coding-guidelines']['files']['CodingStyle.md'].split(':',1)[1])")
OUT=.claude/references/dotnet/coding-guidelines.md
curl -sL "https://raw.githubusercontent.com/moberghr/coding-guidelines/${SHA}/CodingStyle.md" -o "$OUT"
ACTUAL=$(sha256sum "$OUT" | awk '{print $1}')
[ "$ACTUAL" = "$EXPECTED" ] || { echo "coding-guidelines sha256 mismatch: got $ACTUAL expected $EXPECTED" >&2; rm -f "$OUT"; exit 1; }
```

For `python` / `typescript`: placeholder coding-guidelines live in `.claude/references/{stack}/coding-guidelines.md` with `status: placeholder` in frontmatter. **Bootstrap skips any reference file whose first frontmatter block contains `status:[[:space:]]*placeholder` — it is not copied into the target repo and not cited in CLAUDE.md/AGENTS.md.** Detect with awk on the first `---`…`---` block. When the team formalizes guidelines and removes the `status: placeholder` line, the next bootstrap ships the file automatically.

If the fetch fails (network restrictions), check if the file already exists. If not, tell the engineer to manually place it. Do **not** silently fall back to an unpinned fetch — that breaks reproducibility.

### Architecture Principles
Check if `.claude/references/architecture-principles.md` exists.

- **If it exists:** leave it alone — init respects prior architecture decisions.
- **If it does NOT exist:** auto-generate it from the Step 2 audit findings using the same template as `/mtk-setup --audit` (descriptive audit of actual patterns, with "⚠️ Inconsistency" flags where the codebase disagrees with itself). No prompt — this is the one-time bootstrap. The inline generation must include the repomap evidence pass (setup-audit STEP 0.5) and the mandatory `## Provenance` section (setup-audit STEP 3.5) — if you cannot run those inline, delegate the generation to `setup-audit` instead of producing an unevidenced document.

To refresh the file later as the architecture evolves, the engineer runs `/mtk-setup --audit` explicitly.

## STEP 2: Audit the Codebase

Use the **`## Scan Recipes`** section from the active tech stack skill (`.claude/skills/tech-stack-{stack}/SKILL.md`). Each tech stack provides its own scanning bash blocks.

Run the recipes in order:
1. Project Structure
2. Patterns In Use
3. Data Layer
4. Infrastructure
5. Naming Conventions
6. Testing Patterns
7. Configuration

Then run these stack-agnostic checks:
```bash
# Git Conventions
git log --oneline -20
git branch -a | head -20
find . -name "pull_request_template*"
```

Record what you find — this is the input for Step 3.

## STEP 2.5: Post-Scan Interview (skip if `--non-interactive`)

Auto-detection captures WHAT is in the codebase. It cannot capture the team's implicit knowledge — the things that make CLAUDE.md actually useful. Ask **3–5 focused questions** via `AskUserQuestion`. These answers feed directly into the Critical Rules and `project-specific.md`.

**Rules for the interview:**
- Keep it short. 5 questions max. If the engineer pushes back or seems unsure, accept "skip" as a valid answer.
- Do NOT ask anything you can answer from the scan (e.g., "what's your test framework" — you already know).
- Frame for answers you can convert into trigger-action rules.
- Record answers; integrate into Step 3 output.

**Question set (adapt wording per stack):**

1. **Top failure modes** — "What are the 2–3 things AI assistants (or junior engineers) get wrong most often in this codebase?" Convert each answer into a `WHEN X, DO NOT Y` rule.

2. **Hard nevers** — "What should an AI **never** do in this repo without explicit approval?" Examples to prompt with: "touch migrations / modify financial state without audit trail / change auth middleware / drop caches / skip the review step". These become the top Critical Rules (§0.x).

3. **Invisible conventions** — "Is there an architectural or naming convention that isn't obvious from reading the code?" (e.g., "all money is `decimal` with 4-digit scale", "handlers must emit a domain event", "routes live in `Endpoints/` not `Controllers/` even though we use MVC").

4. **Branch + PR workflow** — only ask if recent `git log` / PR templates didn't make this obvious. "How do you name branches and what's the PR convention?"

5. **Compliance / regulatory constraints** (always ask for regulated domains) — "Are there compliance constraints that should surface in reviews? (e.g., PII handling, audit log requirements, SOC2 scope, PCI scope)"

**What to do with answers:**
- Each `hard never` → top of Critical Rules, with `IMPORTANT:` prefix.
- Each `top failure mode` → rule in the relevant `.claude/rules/` file (e.g., failure about EF queries → `data-layer.md`).
- Each `invisible convention` → `project-specific.md`.
- Compliance answers → fold into `security.md` with `§1.x` numbering.

If `--non-interactive` is passed, skip this entire step but print a notice:
```
⚠️ Interview skipped. CLAUDE.md will be auto-detected only — consider running without --non-interactive for better team-specific rules.
```

## STEP 3: Generate CLAUDE.md + Rules Files

The generated output follows Claude Code best practices:
- **Root `CLAUDE.md`** target **60–80 lines**, hard cap **120 lines** (see Research-backed constraints above for the why) — every line must earn its place.
- **`.claude/rules/*.md`** files hold detailed, topic-specific rules (auto-loaded by Claude Code)
- **`.claude/references/`** files are read on-demand by skills and agents (not duplicated)
- **Hooks / `settings.json` deny-list** handle anything mechanically enforceable (formatting, secret scanning, banned commands) — do NOT duplicate those rules in CLAUDE.md.

### If CLAUDE.md does NOT exist → Generate from scratch

Create `CLAUDE.md` and `.claude/rules/` files following the templates below.

### If CLAUDE.md ALREADY exists → Merge mode (default)

1. Read the existing CLAUDE.md and check if `.claude/rules/` exists
2. **If monolithic CLAUDE.md (>200 lines, contains full rule sections):**
   - Extract each section into the corresponding `.claude/rules/` file
   - Replace CLAUDE.md with the lean template, preserving project-specific content
3. **If lean CLAUDE.md + `.claude/rules/` already exists:**
   - Compare each rules file against scan findings
   - Identify stale, missing, and conflicting content
4. Present a summary:
   ```
   CLAUDE.md Structure Analysis:
     Current: [monolithic N lines | lean + N rule files]
     Proposed changes:
       [list each change]
   ```
5. Apply the changes (in merge mode, don't ask — the engineer chose init knowing it modifies files)

### Root CLAUDE.md Template

**Target: 60–80 lines. Hard cap: 120 lines.** If it's longer, move detail to `.claude/rules/` or delete speculative rules entirely. Count before finishing.

**Mandatory footer** at end of CLAUDE.md (HTML comment — invisible to humans reading markdown, but required for `--audit` re-runs and compliance audits):

```html
<!-- mtk-setup: v{MANIFEST_VERSION}
     coding-guidelines: moberghr/coding-guidelines@{MANIFEST_SHA}
     generated: {ISO8601_UTC_NOW} -->
```

Resolve `{MANIFEST_VERSION}` and `{MANIFEST_SHA}` from `.claude/manifest.json`. `{ISO8601_UTC_NOW}` is `date -u +%Y-%m-%dT%H:%M:%SZ`.

````markdown
# [Project Name] — Engineering Standards

> Auto-generated by init on [date]. Based on:
> - Tech stack: [stack name from `.claude/tech-stack`]
> - Coding guidelines (`.claude/references/{stack}/coding-guidelines.md`)
> - Architecture principles (`.claude/references/architecture-principles.md`) [or "not found"]
> - Codebase scan of this repository
>
> This file + `.claude/rules/` are the source of truth for AI agents.
> Detailed standards live in `.claude/rules/`. Reference docs live in `.claude/references/`.

---

## Skill Routing

| What you need | Skill | When |
|---|---|---|
| Build a feature | `/mtk <feature description>` | New endpoints, tables, handlers, multi-file work (routes to implement) |
| Quick fix | `/mtk fix <description>` | Bug fixes, config tweaks, 1-3 file changes |
| Pre-commit check | `/mtk review before commit` | Before every commit — fast security-focused review |

**Decision rule:** If unsure, start with `/mtk fix <description>`. If the change grows beyond 3 files, switch to `/mtk <feature description>` (routes to implement). Set `MTK_AUTO_PROCEED=1` in `.claude/settings.local.json` `env` to skip the Phase 2.5 prompt on safe plans (see `.claude/references/orchestration-gates.md`).

---

## Tech Stack

- **Active stack:** [from `.claude/tech-stack`]
- **Build command:** [from tech stack skill `## Build & Test Commands`]
- **Test command:** [from tech stack skill `## Build & Test Commands`]
- **Format:** [human-readable form of the format command from tech stack skill `## Format Command` — show the manual project-wide form, e.g., `dotnet format --verbosity quiet`, `npx biome format --write <file>`, `ruff format <file>`. The PostToolUse hook (`hooks/format-on-edit.sh`) handles per-file targeting via stdin JSON; CLAUDE.md is for human readers.]

For framework-specific build/test commands and patterns, see the `tech-stack-{stack}` skill (provided by the MTK plugin, not a file in this repo).

---

## Project Profile

[Generate based on scan findings — adapt fields per stack]

For dotnet:
- **Framework:** .NET [version]
- **Data layer:** [EF Core / Dapper / Data API / etc.]
- **Patterns:** [MediatR/CQRS, Result pattern, FluentValidation, etc.]
- **Hosting:** [Lambda / ECS / App Service / etc.]
- **Database:** [PostgreSQL / SQL Server / etc.]
- **Test stack:** [xUnit/NUnit + Moq/NSubstitute + InMemory/SQLite/TestContainers]

For python:
- **Framework:** [Django / FastAPI / Flask / etc.]
- **Python version:** [from pyproject.toml or .python-version]
- **Data layer:** [SQLAlchemy / Django ORM / Tortoise / etc.]
- **Test stack:** [pytest / unittest, mocking framework]
- **Hosting:** [Lambda / ECS / docker / etc.]

For typescript:
- **Framework:** [React / Next.js / Tauri / Express / Fastify / Hono / NestJS / etc.]
- **Package manager:** [from `.claude/tech-stack-pm` — bun / pnpm / yarn / npm]
- **Build tool:** [Vite / Next / tsup / Rollup / Tauri / etc.]
- **Data layer:** [Prisma / Drizzle / TypeORM / Kysely / none (client-only) / etc.]
- **State / data fetching:** [TanStack Query / SWR / tRPC / Zustand / Redux / etc.]
- **Test stack:** [Vitest / Jest / Playwright / RTL / MSW / etc.]
- **Hosting:** [Vercel / Cloudflare Workers / AWS Lambda / Tauri desktop binary / etc.]
- **Tauri sidecar:** [Yes — `src-tauri/Cargo.toml` present / No]

---

## Critical Rules (Always Apply)

These are the highest-impact rules — the ones most commonly violated or most damaging when broken. Full detailed standards live in `.claude/rules/`.

[Generate the top **3–5** most critical rules (not 10 — every extra rule dilutes adherence). Prefer interview "hard nevers" first, then scan-derived failure modes. Number them §0.1–§0.N.

**Phrasing rules (non-negotiable):**
- Use trigger-action form: `WHEN X, DO NOT Y` or `NEVER Z WITHOUT W`.
- Negatives beat positives. `NEVER commit secrets` > `Always keep secrets safe`.
- Prefix the top 1–2 most damaging rules with `IMPORTANT:` or `YOU MUST` (research shows measurable compliance improvement — but only works if used sparingly).
- If a rule can be enforced by a hook, `settings.json` deny-list, or pre-commit-review-list, put it there and DO NOT list it here.
- Every rule must point to a concrete failure mode in this codebase — no aspirational rules.]

---

## Standards Reference

Detailed rules in `.claude/rules/` (auto-loaded by Claude Code):

| File | Covers | Rules |
|---|---|---|
| `security.md` | Auth, secrets, audit, PII | §1.x |
| `architecture.md` | Layers, slices, DI, patterns | §2.x |
| `coding-style.md` | Project-specific style overrides | §3.x |
| `testing.md` | Frameworks, coverage, naming | §4.x |
| `data-layer.md` | ORM, queries, connections | §5.x |
| `performance.md` | Async, caching, connection pooling | §6.x |
| `infrastructure.md` | IaC, containers, cloud services | §7.x |
| `git-workflow.md` | Branches, commits, PRs | §8.x |
| `project-specific.md` | Patterns unique to this repo | §9.x |

Full reference docs (read on-demand by skills and review agents):
- `.claude/references/{stack}/coding-guidelines.md` — Stack-specific coding style
- `.claude/references/architecture-principles.md` — Architecture principles
- `.claude/references/security-checklist.md` — Security checklist (shared)
- Stack-specific references listed in the `tech-stack-{stack}` skill's `## Reference Files` (MTK plugin)
````

### .claude/rules/ File Templates

Generate each file below. **Only generate files for sections relevant to this project.** Skip files for technologies the project doesn't use.

Each rules file target: **30–80 lines**. Be concise.

The rule file templates are largely the same as before — adapt the content per tech stack:
- `security.md` — generic, applies to all stacks
- `architecture.md` — based on actual patterns found
- `coding-style.md` — project-specific overrides only (don't duplicate the coding guidelines file)
- `testing.md` — based on test patterns found, reference the tech stack's testing supplement
- `data-layer.md` — based on actual data access patterns (EF Core / SQLAlchemy / etc.)
- `performance.md` — based on actual performance considerations
- `infrastructure.md` — IaC, containers, cloud services found
- `git-workflow.md` — commit and branch conventions
- `project-specific.md` — anything unique

### Rules for Generation
- **Counter-example gate (MANDATORY — run before emitting ANY absolute rule).** A pattern seen *somewhere* is not a law. Before writing any rule containing `NEVER`, `ALWAYS`, `all`, `every`, or `must`, grep for counter-examples and count hits that contradict it. If ANY exist, do NOT state it as absolute — soften to `Prefer X`, note the exception count/location, and tag `[CONVENTION]` not `[ENFORCED]`. Reserve absolute language / `[ENFORCED]` for zero-counter-example, build-gated or tool-enforced rules.
- Every rule in `.claude/rules/` must have a section number (§X.Y) for review agents to cite.
- Include **code examples** from the actual codebase where possible.
- Flag conflicts: "⚠️ Guideline says X, but codebase does Y. Standardize on: [recommendation]"
- Be specific to THIS project — skip technologies not in use.
- **Don't duplicate** content from `.claude/references/` — point to the file instead.
- Skip rules files for sections that don't apply.
- **Cache-stable ordering:** put invariants (Critical Rules, Standards Reference, Tech Stack commands) near the top; volatile state (project profile with versions, monorepo layout) below. This keeps the prompt prefix stable across sessions so prompt caching stays warm. See `.claude/skills/writing-skills/SKILL.md` `## Cache-Stable Prefixes`.

## STEP 3.5a: Verify Generated References

Before writing files (or presenting preview), validate every concrete directory, project, and file claim in ALL generated content. This prevents stale references from appearing when bootstrap runs alongside cleanup or when solution files reference deleted projects.

**Scope:** Verify claims in ALL generated files — `CLAUDE.md`, `.claude/references/architecture-principles.md`, every `.claude/rules/*.md`, and (if monorepo) every per-package `CLAUDE.md`.

**Verification procedure:** run `scripts/verify-references.sh` over every generated doc. It performs four mechanical checks — path/directory claims (only backtick-spanned path tokens, resolved against root, `src/`, and the git index to avoid prose false positives), `.csproj` project-file existence, an informational framework/version dump for cross-checking, and solution-membership vs disk reality — and prints `STALE …` lines (exit 3 if any found, 0 if clean). Rules files are passed in, which also covers their project/dir proper-noun references.

```bash
bash scripts/verify-references.sh CLAUDE.md \
  .claude/references/architecture-principles.md .claude/rules/*.md
# (if monorepo) also pass each per-package CLAUDE.md
```

**Action on stale references:**

- If a directory/project is referenced as "exists" but doesn't → remove the reference or mark as removed.
- If a directory/project is referenced as "not on disk" but does exist → correct the claim.
- If a framework version is claimed but no project file uses it → remove the claim.
- If a solution references a project that doesn't exist on disk → note the stale solution entry but do NOT modify the `.sln` file.
- Re-run this check after any file deletions or renames in the same session.

**Rule:** Never infer disk presence from solution membership, package manifests, or lock files alone. The `test -d` / `test -f` check is the source of truth. The generated content must reflect the repository state AT THE TIME OF WRITING, not at the time of scanning. **Claim-level grounding (MANDATORY):** after writing each generated doc, run `bash scripts/verify-claims.sh <file>` and apply `.claude/references/audit-grounding.md` (rule tags `[ENFORCED]/[CONVENTION]/[ASPIRATIONAL]`, `<!-- mtk-stamp -->` footer on CLAUDE.md, zero-hit downgrades, transient-state and terminology flags, paste-ready weak-claims report).

## STEP 3.5b: Preview Gate (if `--preview`)

If the engineer passed `--preview`, **do not write any files yet**. Instead:

1. Hold the generated content in memory (CLAUDE.md body, each `.claude/rules/*.md` body, AGENTS.md, pre-commit-review-list).
2. For each pending file, stage it to a temp path and compute size with `scripts/count-tokens.sh`:
   ```bash
   TMP=$(mktemp); echo "$CONTENT" > "$TMP"
   read -r LINES TOKENS < <(bash scripts/count-tokens.sh "$TMP")
   ```
3. Print a plan summary in table form (fixed columns, right-aligned numbers):
   ```
   📋 PROPOSED CHANGES (preview — nothing written yet)

   FILE                                          STATUS     LINES  ~TOKENS
   CLAUDE.md                                     NEW          178     1843   (cap 120 ← FAIL)
   .claude/rules/security.md                     NEW           47      512
   .claude/rules/architecture.md                 NEW           62      698
   .claude/rules/testing.md                      NEW           41      452
   .claude/rules/data-layer.md                   NEW           38      401
   .claude/rules/project-specific.md             NEW           29      314
   .claude/references/pre-commit-review-list.md  NEW           24      268
   AGENTS.md                                     NEW           23      287
   ```
   If any row shows `FAIL`, refuse to proceed: print "Generated CLAUDE.md exceeds 120 lines — move <section> to .claude/rules/<name>.md" and abort. This gate fires even without `--preview`.

   Follow the table with a one-block summary:
   ```
   Critical Rules (top of CLAUDE.md):
     §0.1 [first rule]
     §0.2 [second rule]
     ...
   Tech stack:  [stack]
   Package mgr: [pm, if ts]
   ```
4. Print the full CLAUDE.md body inline (inside a fenced code block) so the engineer can review it.
5. Ask via `AskUserQuestion`:
   ```
   question: "Proceed with writing these files?"
   header: "Bootstrap confirmation"
   options:
     - label: "Yes, write all"
       description: "Commit the proposed files as shown"
     - label: "Yes, but skip CLAUDE.md"
       description: "Write rules files only — I'll author CLAUDE.md myself"
     - label: "Cancel"
       description: "Discard the proposed output"
   ```
6. On "Cancel", stop and leave the repo untouched.
7. On "skip CLAUDE.md", write everything except root CLAUDE.md.
8. On "Yes, write all", proceed to STEP 4.

Without `--preview`, still compute the lines/tokens table and enforce the 120-line ceiling on CLAUDE.md — just skip the confirmation prompt.

## STEP 3.5c: Secret Scan Gate (always)

Before **any** `Write` of a generated file, run the secret scan on the content. This runs regardless of `--preview` — it is a safety gate, not a UX flourish.

For each file you are about to write, use a temp file to stage content and scan it:

```bash
TMP=$(mktemp)
# write content to $TMP, then:
bash scripts/secret-scan.sh "$TMP" || { echo "secret-scan blocked write of <filename>"; rm -f "$TMP"; exit 1; }
mv "$TMP" "<target-path>"
```

If the scan exits non-zero:
- Print the offending lines (the scan writes `<file>:<line>: <pattern>` to stderr).
- Abort the bootstrap entirely — do not proceed with remaining writes.
- Instruct the engineer to investigate the audit output or coding-guidelines for the suspected leak.

**Escape hatch:** `MTK_SECRET_SCAN_SKIP=1` bypasses the scan. Use only when a confirmed false positive blocks progress; log the bypass prominently in STEP 5's report.

## STEP 3.6: Prune Stack Reference Files Against Detected Tools

`setup-audit` writes `.claude/detected-tools.json` (see audit STEP 2.6). Reference files under `.claude/references/{stack}/` declare a `tools:` array in their YAML frontmatter listing which tools they cover. **Skip files whose `tools:` array does not intersect the detected tools** — this is what stops e.g. Drizzle/Prisma/TanStack-Query data-layer guidance from shipping into a Prismic-only repo.

**Procedure:**

1. If `.claude/detected-tools.json` is missing → ship every stack reference (current bloat-prone behavior). Print a one-line warning so the engineer knows pruning was skipped.
2. Otherwise, build the union set: `detected = framework ∪ data_layer ∪ test_framework ∪ additional ∪ {stack}`.
3. For each candidate stack reference (every file under `.claude/references/{stack}/` not already excluded by `status: placeholder`):
   - Read its frontmatter `tools:` array.
   - **No `tools:` declared** → ship (treat as alwaysApply for the stack).
   - **`tools:` ∩ `detected` non-empty** → ship.
   - **`tools:` ∩ `detected` empty** → SKIP. Do NOT copy into the target repo.
4. Print one summary line per stack: `references: shipped <N>, pruned <M> (no detected tool match)`. List the pruned filenames so the engineer can override if a tool was missed in detection.

**Override:** Engineers who want a pruned file anyway can either (a) add the relevant tool to `detected-tools.json` and re-run setup, or (b) `cp` the file from `$CLAUDE_PLUGIN_ROOT/.claude/references/{stack}/<file>.md` into their repo manually. Bootstrap never deletes manually-placed reference files.

**Detection cache:** `setup-bootstrap` re-runs `setup-audit` (or skips if a recent `detected-tools.json` exists, < 7 days old by default — same TTL convention as the architecture-principles cache).

## STEP 4: Set Up Supporting Files & Directories

### .claude/rules/ Directory
Create `.claude/rules/` if it doesn't exist:
```bash
mkdir -p .claude/rules
```
(Reminder from STEP 0: never add `.claude/tech-stack` to a `mkdir -p` — it is a file.)

### Settings Merge

Read the active tech stack skill's `## Settings Additions` section. Merge those entries into `.claude/settings.json`:
- `allowedTools` — union with existing
- `deny` — union with existing
- `hooks.PostToolUse` — append the stack's format hook

### Git Pre-Commit Hook

Install the deterministic linter as a git pre-commit hook so critical findings (secrets, raw SQL, etc.) block the commit automatically.

The hook source lives in the **plugin checkout**, not the target repo. A relative `ln -s ../../hooks/...` dangles once installed into a bootstrapped repo — resolve an ABSOLUTE source and verify it before linking, or copy the file.

1. **If `.git/hooks/pre-commit` does not exist** — install, guarding against a dangling symlink:
   ```bash
   HOOK_TARGET=".git/hooks/pre-commit"
   HOOK_SOURCE="${CLAUDE_PLUGIN_ROOT:-$(pwd)}/hooks/git-hooks/pre-commit"  # absolute
   if [ ! -e "$HOOK_SOURCE" ]; then
     echo "⚠️ Hook source not found at $HOOK_SOURCE — skipping git hook install."
   else
     mkdir -p .git/hooks && ln -s "$HOOK_SOURCE" "$HOOK_TARGET"
     # Dangling link → source path was wrong; copy instead.
     [ -e "$HOOK_TARGET" ] || { rm -f "$HOOK_TARGET"; cp "$HOOK_SOURCE" "$HOOK_TARGET" && chmod +x "$HOOK_TARGET"; }
   fi
   ```
2. **If it exists and is already a symlink to our hook** — skip (idempotent; check `readlink`).
3. **If `.git/hooks/pre-commit` exists but is something else** — do NOT overwrite. Print a warning:
   ```
   ⚠️ Existing git pre-commit hook found at .git/hooks/pre-commit.
   MTK's deterministic linter was NOT installed as a git hook.
   To chain it manually, add this line to your existing hook:
     exec hooks/git-hooks/pre-commit
   ```

The hook runs `hooks/pre-commit-linters.sh --cached` (< 1 second) and blocks on critical findings. Engineers bypass with `git commit --no-verify`. The full AI review (`/mtk review before commit`) remains a separate, manual step.

### Skills and Agents
Ensure the following files exist:
- `.claude/skills/implement/SKILL.md` — main implementation loop
- `.claude/skills/fix/SKILL.md` — quick fix loop
- `.claude/skills/pre-commit-review/SKILL.md` — pre-commit security review
- `.claude/skills/spec-driven-development/SKILL.md`
- `.claude/skills/incremental-implementation/SKILL.md`
- `.claude/skills/test-driven-development/SKILL.md`
- `.claude/skills/planning-and-task-breakdown/SKILL.md`
- `.claude/skills/debugging-and-error-recovery/SKILL.md`
- `.claude/skills/code-review-and-quality/SKILL.md`
- `.claude/skills/tech-stack-{stack}/SKILL.md` — for the active stack
- `.claude/agents/compliance-reviewer.md`
- `.claude/agents/test-reviewer.md`
- `.claude/agents/architecture-reviewer.md`
- `AGENTS.md`

If any are missing, tell the engineer to re-install the MTK plugin from the marketplace (`/plugin install mtk@moberghr`).

### Reference File Customization

Shared reference files ship as generic, multi-stack guidance with "match existing" placeholders. After confirming they exist, substitute those placeholders with concrete scan findings so that every subsequent `/mtk` implement and review run gets project-specific guidance without re-scanning.

**When to customize:** Only when the scan found exactly ONE tool in a category (unambiguous evidence).
**When NOT to customize:** If the scan found multiple tools (e.g., both xUnit and NUnit), or zero matches — leave the generic guidance intact.

The per-stack substitution tables (which generic placeholder maps to which concrete replacement, per category) and the full procedure live in **`.claude/references/bootstrap-customization.md`**. Read it now for the active stack and apply the substitutions. Only narrow on unambiguous single-tool evidence; never remove sections for tools the project doesn't use yet.

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

Add `tasks/todo.md` and `.claude.local.md` (personal, opt-in CLAUDE.md companion — `claude-md-capture` writes personal learnings here; never auto-created) to `.gitignore` if not already there. Do NOT gitignore `tasks/lessons.md`.

### .mtkignore (S1.14)

Create `.mtkignore` at the repo root if missing — same syntax as `.gitignore`, single source of truth for MTK scans (audit, repomap). Idempotent: never overwrite existing. Starter content: `graphify-out/`, `docs/translations/`, `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`. Committed so the team shares one set of exclusions.

### Analyzer Configuration (opt-in)

After distributing references, ask the engineer whether to configure recommended analyzers for the detected stack. This sets up Roslyn analyzers (.NET), ruff/mypy (Python), or biome/tsc-strict (TypeScript) so that build output feeds into the review pipeline with `source: "analyzer"` and `confidence: 100`.

1. Read `.claude/references/{stack}/analyzer-config.md` for the recommended packages and config
2. Ask: "Would you like to set up recommended analyzers for {stack}? This adds [packages] to your build and surfaces semantic findings in the review pipeline. (y/n)"
3. If yes: generate the appropriate config (`Directory.Build.props` additions for .NET, `pyproject.toml [tool.ruff]` for Python, `biome.json` for TypeScript)
4. If no: skip — the regex linter and AI review still work without analyzers
5. Add `.mtk/` to `.gitignore` (ephemeral analyzer output cache)

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

Write **one** provenance file: `.claude/mtk-version.json`. It records the installed MTK version (for session-start drift detection) and pins the external coding-guidelines fetch (sha + sha256, for reproducible re-fetch by `--update-guidelines`). Do **NOT** write a slim `.claude/manifest.json` into target repos — the toolkit's full manifest lives only at `$CLAUDE_PLUGIN_ROOT/.claude/manifest.json`. Scripts (`generate-tool-configs.sh`, `mtk-doctor.sh`) resolve it from the plugin root.

```bash
PM="${CLAUDE_PLUGIN_ROOT:-.}/.claude/manifest.json"
V=$(python3 -c "import json; print(json.load(open('$PM'))['version'])")
SHA=$(python3 -c "import json; print(json.load(open('$PM'))['coding-guidelines']['sha'])" 2>/dev/null || echo "")
S256=$(python3 -c "import json; print(json.load(open('$PM'))['coding-guidelines']['files']['CodingStyle.md'])" 2>/dev/null || echo "")
cat > .claude/mtk-version.json <<EOF
{"version":"$V","installed":"$(date -u +%Y-%m-%d)","source":"https://github.com/moberghr/mtk-agent-toolkit","coding-guidelines":{"repo":"moberghr/coding-guidelines","sha":"$SHA","files":{"CodingStyle.md":"$S256"}}}
EOF
```

Omit the `coding-guidelines` block when no external guidelines were pinned (placeholder stacks). Committed (not gitignored).

### Cross-Agent Compatibility

After generating CLAUDE.md and rules, generate portable configs for all AI coding tools:

1. Run `bash scripts/generate-agents-md.sh` (if the script exists in the plugin directory)
2. This creates an `AGENTS.md` at the repo root that Codex and other AGENTS.md-aware tools can read
3. The file contains coding guidelines, security requirements, testing expectations, and architecture principles — extracted from the references already distributed
4. Custom sections (prefixed `## Custom:`) are preserved across regeneration
5. If `AGENTS.md` already exists and has no `## Custom:` sections, the file is regenerated from current references
6. **Size budget — same instruction-budget discipline as CLAUDE.md** (compliance degrades past ~150 instructions). **Target 60–120 lines**; point to `.claude/rules/` and references rather than restating them.
7. **Git-ignore check** — surface in the STEP 5 report if the deliverable won't be committed: `git check-ignore -q AGENTS.md && echo "⚠️ AGENTS.md is git-ignored — generated but will NOT be committed."`
8. Run `bash scripts/generate-tool-configs.sh --all` (if the script exists) to generate native configs for other tools:
   - `.cursor/rules/mtk-*.mdc` — glob-scoped Cursor rules (applyTo globs from manifest)
   - `.github/copilot-instructions.md` — GitHub Copilot instructions
   - `.windsurfrules` — Windsurf rules
   - `GEMINI.md` — Gemini CLI guidelines
   - `.clinerules` — Cline/Roo rules

## STEP 4.5: Monorepo — Per-Package CLAUDE.md (conditional)

Research-backed: a documented monorepo case study reduced per-session context load by ~80% by splitting a 47k-word monolithic CLAUDE.md into a ~9k-word root + short per-package files that load on-demand when Claude accesses those directories.

### Detect if this is a monorepo

Run these checks in parallel:

```bash
# JS/TS workspaces
LERNA=$(test -f lerna.json && echo "yes")
PNPM_WS=$(test -f pnpm-workspace.yaml && echo "yes")
TURBO=$(test -f turbo.json && echo "yes")
NX=$(test -f nx.json && echo "yes")
RUSH=$(test -f rush.json && echo "yes")
PKG_WORKSPACES=$(grep -l '"workspaces"' package.json 2>/dev/null)

# .NET multi-project solutions
SLN_COUNT=$(find . -maxdepth 2 -name "*.sln" -o -name "*.slnx" 2>/dev/null | wc -l | tr -d ' ')
CSPROJ_COUNT=$(find . -maxdepth 4 -name "*.csproj" -not -path "*/bin/*" -not -path "*/obj/*" 2>/dev/null | wc -l | tr -d ' ')

# Python multi-package
PYPROJECT_COUNT=$(find . -maxdepth 3 -name "pyproject.toml" -not -path "*/.venv/*" -not -path "*/node_modules/*" 2>/dev/null | wc -l | tr -d ' ')

# Conventional layout
HAS_APPS=$(test -d apps && echo "yes")
HAS_PACKAGES=$(test -d packages && echo "yes")
HAS_SERVICES=$(test -d services && echo "yes")
HAS_LIBS=$(test -d libs && echo "yes")
```

**Classification:**
- **Not a monorepo** if: single `*.sln` with ≤3 `*.csproj` in a linear hierarchy, or single `pyproject.toml` at root, or single `package.json` with no `workspaces`. Skip the rest of this step. **Preservation:** any pre-existing nested `CLAUDE.md` (in a subdirectory) is hand-authored — leave it untouched and list it under "Preserved hand-authored files" in the STEP 5 report. Deciding not to generate per-package files is NEVER a reason to delete existing ones (see File Preservation Policy).
- **Monorepo** if: any of LERNA/PNPM_WS/TURBO/NX/RUSH/PKG_WORKSPACES is set, OR `CSPROJ_COUNT >= 4`, OR `SLN_COUNT >= 2`, OR `PYPROJECT_COUNT >= 2`, OR any of the conventional layout dirs exist and contain >1 subdirectory with a project marker.

If classification is ambiguous, ask via `AskUserQuestion`:
```
question: "Is this a monorepo? (Multiple packages/services sharing a repo)"
header: "Repo layout"
options:
  - label: "Yes — generate per-package CLAUDE.md files"
    description: "Short per-directory files pointing to root CLAUDE.md"
  - label: "No — single project"
    description: "Skip per-package generation"
```

### Enumerate packages

Build the list of package directories:

- **JS/TS workspaces:** read `workspaces` from `package.json`, `packages` from `pnpm-workspace.yaml`, or globs from `turbo.json` / `nx.json`. Expand globs.
- **.NET:** each directory containing a `*.csproj` is a package. Group by top-level folder if there's a clear `src/<Module>/<Project>.csproj` pattern.
- **Python:** each directory containing a `pyproject.toml`.
- **Convention-based:** each immediate subdirectory of `apps/`, `services/`, `packages/`, `libs/` that contains a project marker.

Cap at **20 packages**. If there are more, pick the top 20 by file count and print a note: "Skipped N packages — generate per-package CLAUDE.md manually for any that need special context."

### Generate per-package CLAUDE.md + update root

The per-package file template, the generation rules (15–30 line local delta, 5-line stub for trivial packages, never overwrite, never duplicate root rules), and the root **Monorepo Layout** block live in **`.claude/references/monorepo-bootstrap.md`**. Read it now and follow it for each enumerated package, then add the Monorepo Layout block to the root CLAUDE.md (inside the 120-line cap).

## STEP 4.8: Seed Template Cache (for future re-runs)

After every generated file is written to disk, also write an **unmodified copy of the template output** to `.claude/.mtk-cache/v<MANIFEST_VERSION>/`. This cache is what `--audit` re-runs diff against for 3-way merges. The cache is gitignored.

Files to snapshot (skip any the engineer declined in `--preview`):
- `CLAUDE.md`
- `AGENTS.md`
- `.claude/rules/*.md`
- `.claude/references/pre-commit-review-list.md`

Layout:
```
.claude/.mtk-cache/
  v7.0.0/
    CLAUDE.md
    AGENTS.md
    rules/
      security.md
      ...
    references/
      pre-commit-review-list.md
```

Implementation:
```bash
PM="${CLAUDE_PLUGIN_ROOT:-.}/.claude/manifest.json"
VERSION=$(python3 -c "import json; print(json.load(open('$PM'))['version'])")
CACHE_DIR=".claude/.mtk-cache/v${VERSION}"
mkdir -p "$CACHE_DIR/rules" "$CACHE_DIR/references"
# For each generated file, copy the pre-write version (not the on-disk edited one):
cp /tmp/mtk-staging/CLAUDE.md "$CACHE_DIR/CLAUDE.md"
# ...etc for each file
```

Retention: keep at most the 2 most recent versions. Older versions are pruned at this step.

## STEP 4.9: Rebuild References Index

After all reference files are written (including any newly emitted ones), rebuild the generated index:

```bash
bash scripts/build-references-index.sh
```

This produces `.claude/references.index` — a tab-separated file used by routing logic to auto-select references by file-pattern match. The index is gitignored (regenerated on every bootstrap and audit).

## STEP 4.95: Seed CODE_INDEX.md

Seed a repo-root `CODE_INDEX.md` from `.claude/references/code-index-template.md` (handlers/controllers/services by domain); skip if it exists; consumed by `code-simplification --audit-duplicates`. **Never ship the template's placeholder rows as real entries** (a prior-work scan would chase ghosts). Populate from the audit's actual capabilities — each row's `path:Symbol` MUST resolve (`test -f`/`git ls-files`) — or, if you can't, write an explicitly-empty index ("No capabilities indexed yet — run `/mtk audit duplicates`") with no rows that look like real entries.

## STEP 5: Verify & Report

```
✅ MTK INIT COMPLETE

Project: [name]
Tech stack: [stack name from .claude/tech-stack]

Standards sources:
  ✓ Tech stack skill: .claude/skills/tech-stack-{stack}/SKILL.md
  ✓ Coding guidelines: .claude/references/{stack}/coding-guidelines.md
  ✓ Architecture principles: .claude/references/architecture-principles.md [or ⚠️ not found]
  ✓ Codebase scan: [N] files across [N] projects/modules

Generated/Updated:
  ✓ .claude/tech-stack: [stack]
  ✓ CLAUDE.md ([N] lines — under 120 ✓)
  ✓ .claude/rules/ — [N] rule files generated
  ✓ .claude/references/pre-commit-review-list.md — [generated with N items | already exists, skipped]
  ✓ .claude/settings.json — merged [N] stack-specific entries
  ✓ Git pre-commit hook: [installed | ⚠️ existing hook found, skipped]
  ✓ Tool prerequisites: [all found | ⚠️ N missing — see details above]
  [if monorepo:]
  ✓ Monorepo detected — [N] packages found
      ✓ Generated per-package CLAUDE.md for: [list of packages]
      [⚠️ Skipped (already exists): list of packages]

Preserved hand-authored files (untouched):
  [list any pre-existing nested CLAUDE.md, custom commands/rules, or other non-MTK files left in place — or "none found"]
Retired prior MTK files (explicitly removed this run):
  [list any MTK-owned files this re-run superseded — or "none". If this section is non-empty, each entry must be an MTK-owned file, never hand-authored content.]

Codebase findings:
  [stack-specific summary based on scan]

Skills available:
  /mtk <feature>         — Full feature loop
  /mtk fix <description> — Quick fix (1-3 files)
  /mtk review before commit — Fast security-focused review of staged changes
  /mtk-setup --audit     — Re-run architecture audit
Keep CLAUDE.md fresh: press # mid-session to append a learning instantly; run claude-md-capture at session end to propose session learnings as diffs (personal notes → .claude.local.md).
Next: Try it with:
  /mtk Add [your feature description here]
```

## IMPORTANT
- Create `.claude/references/` and `.claude/rules/` directories if they don't exist
- **Default to merge mode** when CLAUDE.md already exists — don't ask overwrite/merge/abort
- If existing CLAUDE.md is monolithic (>200 lines), migrate to lean structure automatically
- If CLAUDE.md doesn't exist, generate from scratch without asking
- The generated files should be committed to the repo
- **Count CLAUDE.md lines before finishing.** Target 60–80. If over 120, move content to rules files or delete speculative rules.
- **Per-package / nested CLAUDE.md files are never overwritten OR deleted** — at any path other than root, monorepo or not. If one already exists, skip it and report it as preserved. These may be hand-authored. See the File Preservation Policy: bootstrap never `git rm`s a file it did not generate.
- **Per-package files must be small (15–30 lines) and contain only the local delta.** If a package has no notable delta, generate the 5-line stub pointing to root.
- The `.claude/tech-stack` file is critical — every skill reads it. Make sure it's written before reporting completion.
