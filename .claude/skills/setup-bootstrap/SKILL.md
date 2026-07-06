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
- **`--no-verify-commands`** — skip STEP 3.5a's "Command verification" subsection entirely: no build/test/format commands are executed, and CLAUDE.md's Tech Stack section is written with no `<!-- verified: ... -->` stamp and no `[UNVERIFIED]` annotations. Use on a slow or sandboxed runner where executing the repo's build is undesirable. Noted in the STEP 5 report (`Command verification: skipped via --no-verify-commands`).

All three flags can combine, e.g. `--preview --non-interactive --no-verify-commands` runs silently, skips command verification, and still asks to confirm writes.

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

- **Only MTK-owned files may be overwritten in place.** An MTK-owned file is one carrying the `<!-- mtk-setup` provenance stamp, OR one of MTK's known generated paths (`CLAUDE.md` root, `.claude/rules/*` in the standard set, `.claude/references/*` — including `.claude/references/product.md` and `.claude/references/decisions.md` (STEP 3.8) — `.claude/tech-stack`, `.claude/settings.json`, `.claude/detected-tools.json`, `.claude/mtk-version.json`, `CODE_INDEX.md`, `pre-commit-review-list.md`). Overwrite means rewrite the body — never `git rm`. **Exception:** `.claude/references/product.md` and `.claude/references/decisions.md` are never overwritten once present — same "leave it alone" rule as `architecture-principles.md` — a later re-run routes any change through `.claude/references/regen-diff-contract.md` instead of rewriting in place.
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

Run the mechanized detector once — it covers every marker above plus package-manager priority, React Native/Expo markers, and monorepo signals (STEP 4.5 reuses this same call):
```bash
bash scripts/setup-detect.sh --json
```
Read `stacks` (array), `primary_candidate`, `package_manager`, `react_native.detected` / `react_native.expo`, `go_detected`, and `multiple_lockfiles` from the output.

If `stacks` has more than one entry, ask the engineer:
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
Otherwise the primary stack is `primary_candidate`. **F11 — secondary stacks:** once the primary is chosen, if `stacks` had more than one entry, record the rest as secondary stacks — `setup-audit` STEP 2.6 writes them to `detected-tools.json`'s `secondary_stacks` array (STEP 2 runs their naming/testing scan recipes; STEP 3.6 folds their reference files into the detected-tool union).

If `stacks` is empty, stop and tell the engineer go is not yet supported (when `go_detected` is true) or to add a `tech-stack-{name}/` skill / open an issue (otherwise).

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

### Package manager + React Native/Expo (typescript only)

When the active stack is `typescript`, write `package_manager` (from the STEP 0 `setup-detect.sh --json` output) to `.claude/tech-stack-pm` so workflow skills can substitute `<pm>` in commands:
```bash
echo "$PM" > .claude/tech-stack-pm
```
If `multiple_lockfiles` is true, warn the engineer — that's almost always a mistake — and note that `package_manager` was picked automatically by priority (bun > pnpm > yarn > npm); do not prompt.

`react_native.detected` / `react_native.expo` feed `setup-audit`'s `detected-tools.json` (audit STEP 2.6) and reference pruning (STEP 3.6): when `detected` is true, add `react-native` (and `expo` when `react_native.expo` is true) to detected tools. Stack stays `typescript`.

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

## STEP 1.5: Scan Ledger (resumable)

Bootstrap scans and audits can run long enough to hit a session compaction or crash before STEP 5. Persist progress to a durable workflow artifact (`scripts/workflow-artifact.sh`) so a re-run resumes instead of re-scanning from zero.

**Start:**
```bash
UUID=$(bash scripts/workflow-artifact.sh init setup-bootstrap --goal "<one-line bootstrap goal>")
```
Keep `$UUID` for the rest of the run.

**Resume check (run before `init`, at skill start):**
```bash
bash scripts/workflow-artifact.sh list
```
If an **incomplete** `setup-bootstrap` artifact is found:
- **`updated` timestamp < 24h old:** offer via `AskUserQuestion`:
  ```
  question: "A previous setup-bootstrap run is in progress (last step: <current_step>). What do you want to do?"
  header: "Resume bootstrap"
  options:
    - label: "Resume from <current_step>"
      description: "Skip completed STEPs and reload their recorded outputs instead of re-scanning"
    - label: "Start fresh (abandon previous)"
      description: "Abandon the prior artifact and run bootstrap from STEP 0"
    - label: "Cancel"
      description: "Stop without doing anything"
  ```
  On "Resume from …", skip every STEP already marked `step_completed` in the artifact's event log and reload its recorded `outputs`/`summary` instead of re-running that STEP. On "Start fresh", run `bash scripts/workflow-artifact.sh abandon <old-uuid> --reason engineer-choice`, then `init` a new artifact. On "Cancel", stop the bootstrap.
- **`updated` timestamp ≥ 24h old:** abandon it automatically — `bash scripts/workflow-artifact.sh abandon <old-uuid> --reason stale-24h` — and start fresh, printing: `⚠️ Abandoned stale setup-bootstrap run (> 24h old) — starting fresh.`

**After each numbered STEP completes:**
```bash
bash scripts/workflow-artifact.sh event "$UUID" step_completed \
  --data '{"step":"STEP 2","outputs":["<files written or read>"],"summary":"<one concrete sentence>"}'
bash scripts/workflow-artifact.sh set "$UUID" current_step="STEP 2"
```
Summaries must be concrete ("scanned 214 files, 3 inconsistencies"), never vague ("did the scan").

**On completion (end of STEP 5):**
```bash
bash scripts/workflow-artifact.sh set "$UUID" status=completed
```

**Context economy (STEP 2's scan categories):** for repos with **>1000 tracked source files**, process the Scan Recipes categories one at a time — write each category's findings into the ledger's `step_completed` event immediately after it finishes, and keep only a 1–2 sentence summary in working context before moving to the next category. The ledger, not the conversation, is the working memory for large scans.

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

**F11 — secondary stacks:** for each secondary stack recorded in STEP 0, also run that stack's `## Scan Recipes` categories 5 (Naming Conventions) and 6 (Testing Patterns) so `conventions.md` covers it too — the rest of that stack's recipes are skipped (workflow skills remain primary-stack only).

## STEP 2.5: Post-Scan Interview (skip if `--non-interactive` and no persisted answers)

Auto-detection captures WHAT is in the codebase. It cannot capture the team's implicit knowledge — the things that make CLAUDE.md actually useful. Ask **3–7 focused questions** via `AskUserQuestion`. These answers feed directly into the Critical Rules and `project-specific.md`.

**Rules for the interview:**
- Keep it short. 7 static questions max, plus up to 3 adaptive questions from audit ambiguities (10 total ceiling). If the engineer pushes back or seems unsure, accept "skip" as a valid answer.
- Do NOT ask anything you can answer from the scan (e.g., "what's your test framework" — you already know).
- Frame for answers you can convert into trigger-action rules.
- Record answers; integrate into Step 3 output.

**Question set (adapt wording per stack):**

1. **Top failure modes** — "What are the 2–3 things AI assistants (or junior engineers) get wrong most often in this codebase?" Convert each answer into a `WHEN X, DO NOT Y` rule.

2. **Hard nevers** — "What should an AI **never** do in this repo without explicit approval?" Examples to prompt with: "touch migrations / modify financial state without audit trail / change auth middleware / drop caches / skip the review step". These become the top Critical Rules (§0.x).

3. **Invisible conventions** — "Is there an architectural or naming convention that isn't obvious from reading the code?" (e.g., "all money is `decimal` with 4-digit scale", "handlers must emit a domain event", "routes live in `Endpoints/` not `Controllers/` even though we use MVC").

4. **Branch + PR workflow** — only ask if recent `git log` / PR templates didn't make this obvious. "How do you name branches and what's the PR convention?"

5. **Compliance / regulatory constraints** (always ask for regulated domains) — "Are there compliance constraints that should surface in reviews? (e.g., PII handling, audit log requirements, SOC2 scope, PCI scope)"

6. **Definition of done** — "What must be true before a change in this repo counts as done? (build + tests green, review passed, manual QA, deploy verification, docs updated …)" Answers feed CLAUDE.md verification guidance and `.claude/rules/project-specific.md`.

7. **Product purpose** — "One sentence: what does this product do, and for whom?" Skippable like the rest. Feeds `.claude/references/product.md` (STEP 3.8).

**Adaptive questions (from audit ambiguities):** if `.claude/.mtk-cache/ambiguities.json` exists and its `ambiguities` array is non-empty, ask up to **3** additional `AskUserQuestion` items on top of the static set — total interview budget: static 7 + adaptive 3 max (10 total ceiling). Rank ambiguities by total hit count (sum of `competing_forms[].count`), highest first, and ask about the top ones only.

Phrasing pattern: "The codebase splits on `<claim>`: `<form A>` (N/M) vs `<form B>` (K/M). Which is the standard?" — options are the competing forms plus an explicit **"Leave ambiguous (document the split)"** option.

- **Persist:** write each answer under a new top-level `resolved_ambiguities` key in `.claude/setup-answers.json`, an object keyed by the ambiguity's `anchor`: `{"<anchor>": {"choice": "<form chosen, or \"leave-ambiguous\">", "decided": "<ISO8601 UTC>"}}`.
- **Doc upgrade:** where an ambiguity was resolved (not left ambiguous), upgrade that `[AMBIGUOUS]` line in the generated doc to a decided convention, citing `Evidence: engineer interview — .claude/setup-answers.json (resolved_ambiguities)`.
- **Re-run rule:** anchors already present in `resolved_ambiguities` are never re-asked. If a fresh scan contradicts a recorded resolution, emit a Needs review item instead of silently picking a side — same interview-conflict contract as setup-audit's "Interview answers are authoritative" rule (cited, not restated).

**What to do with answers:**
- Each `hard never` → top of Critical Rules, with `IMPORTANT:` prefix.
- Each `top failure mode` → rule in the relevant `.claude/rules/` file (e.g., failure about EF queries → `data-layer.md`).
- Each `invisible convention` → `project-specific.md`.
- Compliance answers → fold into `security.md` with `§1.x` numbering.
- Definition-of-done answers → CLAUDE.md's verification guidance (what "done" means for this repo) and `.claude/rules/project-specific.md`.
- Product purpose answer → persisted under answer key `product_purpose`; seeds `.claude/references/product.md` (STEP 3.8).
- **Evidence anchor (every rule sourced from an answer):** cite the steering file as the rule's evidence, e.g. `Evidence: engineer interview — .claude/setup-answers.json (hard_nevers)`. `scripts/verify-claims.sh` resolves real paths before content-grep, so these anchors always hit — engineer-stated rules are never auto-downgraded by the verify pass.

**Persist answers:**

After the interview (including when some questions are skipped), write `.claude/setup-answers.json` — committed, not gitignored. This write goes through the STEP 3.5c secret-scan gate like any other generated file.

```json
{
  "version": 1,
  "captured": "<ISO8601 UTC>",
  "source": "engineer-interview",
  "answers": {
    "hard_nevers": [],
    "failure_modes": [],
    "invisible_conventions": [],
    "branch_pr_workflow": "",
    "compliance_constraints": [],
    "done_definition": [],
    "product_purpose": ""
  },
  "skipped": [],
  "resolved_ambiguities": {}
}
```

**Re-run behavior:**
- **File exists (interactive re-run):** load it, show a compact summary of prior answers, and ask only the questions whose keys are empty/missing or newly introduced. Offer "revise a previous answer" as one of the `AskUserQuestion` options.
- **`--non-interactive` + file exists:** reuse the persisted answers silently — skip asking, and print a notice: `ℹ️ Reusing persisted interview answers from .claude/setup-answers.json (--non-interactive).`
- **`--non-interactive` + no file:** skip this entire step and print the existing notice:
  ```
  ⚠️ Interview skipped. CLAUDE.md will be auto-detected only — consider running without --non-interactive for better team-specific rules.
  ```

## STEP 2.7: Ingest Existing AI-Assistant Configs

Repos migrating to MTK often already carry AI-assistant configuration from other tools (Cursor, Copilot, Windsurf, Cline, Gemini, a prior CLAUDE.md). Treat what's found as interview-grade input feeding STEP 3 generation — read-only, evidence-anchored, with dedup/conflict rules against the STEP 2 scan.

The detection list, evidence-anchor convention, and dedup/conflict rules live in **`.claude/references/config-ingestion.md`**. Read it now and follow it. Report `Ingested AI configs: [list of source paths, or "none found"]` in STEP 5.

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
3. **If lean CLAUDE.md + `.claude/rules/` already exists:** classify and resolve each regenerated file (`CLAUDE.md`, each `.claude/rules/*.md`) per **`.claude/references/regen-diff-contract.md`** — read it now and follow §2 (classification against the `.claude/.mtk-cache/` ancestor), §3/§3a (per-hunk proposals; no-ancestor → additive-only), §4 (cache rule), and §6 (invariants: gate not skippable, non-interactive defers to NEEDS REVIEW, deletion never an outcome). Do not restate the contract's rules here; report per-file RESULT values and Needs review items in the STEP 5 report.

### Root CLAUDE.md Template

**Target: 60–80 lines. Hard cap: 120 lines.** If it's longer, move detail to `.claude/rules/` or delete speculative rules entirely. Count before finishing.

**Mandatory footer** at end of CLAUDE.md (HTML comment — invisible to humans reading markdown, but required for `--audit` re-runs and compliance audits):

```html
<!-- mtk-setup: v{MANIFEST_VERSION}
     coding-guidelines: moberghr/coding-guidelines@{MANIFEST_SHA}
     generated: {ISO8601_UTC_NOW} -->
```

Resolve `{MANIFEST_VERSION}` and `{MANIFEST_SHA}` from `.claude/manifest.json`. `{ISO8601_UTC_NOW}` is `date -u +%Y-%m-%dT%H:%M:%SZ`.

The literal CLAUDE.md template lives in **`.claude/references/root-claude-md-template.md`** — read it now, then reproduce it filling the [bracketed] placeholders from the scan/interview. It targets 60–80 lines (120 hard cap) and ends with the mandatory footer shown above.

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
- **Live references over restated facts (F8).** When a fact lives in a canonical machine-readable file (framework/runtime versions, dependency lists, package-manager choice), point at the file — `see \`package.json\`` — instead of restating the value: restated facts rot as the manifest changes; pointers don't. Exception: facts the instruction budget needs inline stay inline (build/test command lines). Use `@`-import form only for files ≤~50 lines (D6); never `@`-import a manifest or lockfile — that inlines the whole file into context and blows the instruction budget this rule protects.
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

### Command verification (F7)

Unless `--no-verify-commands` was passed (see `## Modes`), verify the exact commands you are about to publish in the Tech Stack section **before** writing CLAUDE.md. Command assembly (build/test/format), the `verify-commands.sh` invocation, and outcome handling — including the fourth branch for when the verifier itself is missing or returns non-JSON — live in **`.claude/references/command-verification.md`**. Read it now and follow it before writing the Tech Stack section.

Report line reminder: note the outcome (`N verified, N unverified, N skipped`, or `skipped via --no-verify-commands` / `skipped — verify-commands.sh not found`) in the STEP 5 report.

## STEP 3.5b: Preview Gate (if `--preview`)

If the engineer passed `--preview`, **do not write any files yet**. The plan-summary table, the ASCII example, and the `AskUserQuestion` confirmation flow live in **`.claude/references/preview-gate.md`**. Read it now and follow it.

**Unconditional (fires even without `--preview`):** compute the lines/tokens table and enforce the 120-line CLAUDE.md ceiling regardless of mode. If CLAUDE.md exceeds 120 lines, refuse to proceed — print "Generated CLAUDE.md exceeds 120 lines — move <section> to .claude/rules/<name>.md" and abort. Without `--preview`, only the confirmation prompt is skipped; the ceiling check always runs.

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
3. **F11:** when `secondary_stacks` is non-empty, the candidate set spans `.claude/references/{stack}/` for the primary stack **and every secondary stack** — same `detected` filter applies to all.
4. For each candidate stack reference (not already excluded by `status: placeholder`):
   - Read its frontmatter `tools:` array.
   - **No `tools:` declared** → ship (treat as alwaysApply for the stack).
   - **`tools:` ∩ `detected` non-empty** → ship.
   - **`tools:` ∩ `detected` empty** → SKIP. Do NOT copy into the target repo.
5. Print one summary line per stack: `references: shipped <N>, pruned <M> (no detected tool match)`. List the pruned filenames so the engineer can override if a tool was missed in detection.

**Override:** Engineers who want a pruned file anyway can either (a) add the relevant tool to `detected-tools.json` and re-run setup, or (b) `cp` the file from `$CLAUDE_PLUGIN_ROOT/.claude/references/{stack}/<file>.md` into their repo manually. Bootstrap never deletes manually-placed reference files.

**Detection cache:** `setup-bootstrap` re-runs `setup-audit` (or skips if a recent `detected-tools.json` exists, < 7 days old by default — same TTL convention as the architecture-principles cache).

## STEP 3.8: Product Context Artifacts

Read `.claude/references/product-context.md` (path per `## MTK File Resolution`) and follow it to generate two artifacts:

- **`.claude/references/product.md`** (≤40 lines) — purpose, users, key flows, non-goals. Sources: the README/docs scan (STEP 2) and interview question 7 (`.claude/setup-answers.json` → `answers.product_purpose`).
- **`.claude/references/decisions.md`** — ADR-lite, append-only decision log. Seed from detectable history (framework migrations, major version bumps in `git log`) and interview rationale (`hard_nevers`, `invisible_conventions` answers where a reason was given).

**Preservation:** if either file already exists, do NOT regenerate it — preserve it untouched and report it as preserved in STEP 5. Both files are part of the File Preservation Policy's known-generated-paths set and are never overwritten once present (see above); a future re-run routes any change through `.claude/references/regen-diff-contract.md` instead of rewriting in place.

**Gates:** both writes go through the STEP 3.5c secret-scan gate before landing on disk. After generating `.claude/references/product.md`, run `bash scripts/verify-claims.sh .claude/references/product.md` and apply the same one-retry loop used for other generated docs (fix the anchor or delete only the self-generated line that failed verification). It cannot run through STEP 3.5a because `product.md` doesn't exist yet at that point in the flow — it's generated here, in STEP 3.8. Surviving downgrades are reported in STEP 5.

Report one line each in STEP 5 (`generated` or `preserved (existing)`).

## STEP 4: Set Up Supporting Files & Directories

### .claude/rules/ Directory
Create `.claude/rules/` if it doesn't exist:
```bash
mkdir -p .claude/rules
```
(Reminder from STEP 0: never add `.claude/tech-stack` to a `mkdir -p` — it is a file.)

### Settings Merge

Read the active tech stack skill's `## Settings Additions` section.

- **`.claude/settings.json` does not exist (fresh bootstrap):** create it from the tech-stack skill's Settings Additions layered over a minimal `{}` base. Never copy the toolkit's own `settings.json` — that's MTK's dev config, not a template. Every hook command path written into the target repo must be `$CLAUDE_PLUGIN_ROOT`-relative; bare `hooks/...` or `$CLAUDE_PROJECT_DIR/hooks/...` dangle in plugin-cache installs.
- **`.claude/settings.json` exists:** merge — `allowedTools`/`deny` union with existing, `hooks.PostToolUse` appends the stack's format hook.
- **Write refused by the permission/session layer:** write the fully-merged content to `.claude/settings.json.mtk-proposed` instead and list it under **Needs review** in the STEP 5 report — one line: "review the diff, then `mv .claude/settings.json.mtk-proposed .claude/settings.json`". Never silently skip the merge; never retry the refused write verbatim.

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

### CI Staleness Gate (optional)

If this repo hosts on GitHub — `.github/workflows/` already exists, OR `git remote get-url origin` contains `github.com` — offer to install the CI staleness gate template. This is the `--check` loop's CI counterpart: it fails a PR when MTK-generated artifacts drift from source (D5, `docs/specs/2026-07-03-v719-setup-improvements.md`).

1. **Skip entirely** if neither signal is present (no `.github/workflows/` and no GitHub remote) — this is not a report-worthy skip, just move on.
2. **`--non-interactive`:** skip silently, no `AskUserQuestion`. Note it in the STEP 5 report as `skipped (--non-interactive)`.
3. **Already exists:** if `.github/workflows/mtk-staleness-check.yml` is already present, never overwrite it — report `already exists` in STEP 5.
4. **Otherwise, ask via `AskUserQuestion`:**
   ```
   question: "Install a CI staleness gate that fails PRs when MTK-generated files drift out of date?"
   header: "CI staleness gate"
   options:
     - label: "Yes, install the workflow"
       description: "Adds .github/workflows/mtk-staleness-check.yml — runs setup-refresh-plan.sh --check on every PR"
     - label: "No, skip"
       description: "Don't add a GitHub Actions workflow"
   ```
5. **On "Yes":** copy `templates/ci/mtk-staleness-check.yml` (path resolved per `## MTK File Resolution` — read from `$CLAUDE_PLUGIN_ROOT/templates/ci/mtk-staleness-check.yml` when set, else the project-relative path) to `.github/workflows/mtk-staleness-check.yml`, creating `.github/workflows/` if missing. Report `installed`.
6. **On "No":** report `declined`.

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
8. **Cross-agent mirrors (Cursor/Copilot/Windsurf/Gemini/Cline) — ask, don't assume** (real teams have deliberately chosen Claude-only configs before):
   - Interactive: ask once via `AskUserQuestion` — "Generate cross-agent configs?" options: "AGENTS.md only (Recommended)" / "All tools (AGENTS.md + Cursor/Copilot/Windsurf/Gemini/Cline)" / "None (Claude Code only)".
   - `--non-interactive`: default to **AGENTS.md only**; skip mirrors and note in the STEP 5 report: "cross-agent mirrors skipped — re-run interactively or run `scripts/generate-tool-configs.sh --all`".
   - On "All tools": run `bash scripts/generate-tool-configs.sh --all` (if the script exists) to generate:
     - `.cursor/rules/mtk-*.mdc` — glob-scoped Cursor rules (applyTo globs from manifest)
     - `.github/copilot-instructions.md` — GitHub Copilot instructions
     - `.windsurfrules` — Windsurf rules
     - `GEMINI.md` — Gemini CLI guidelines
     - `.clinerules` — Cline/Roo rules
   - Regardless of the answer: a tool with an existing config (marker or not) is regenerated/preserved per the existing marker rules — never orphan an already-adopted tool.

## STEP 4.5: Monorepo — Per-Package CLAUDE.md (conditional)

Research-backed: a documented monorepo case study reduced per-session context load by ~80% by splitting a 47k-word monolithic CLAUDE.md into a ~9k-word root + short per-package files that load on-demand when Claude accesses those directories.

### Detect if this is a monorepo

Reuse STEP 0's `bash scripts/setup-detect.sh --json` output (re-run it if the parsed values fell out of context). Read `monorepo.is_monorepo`, `monorepo.ambiguous`, `monorepo.packages`, and `monorepo.packages_skipped`.

- **`is_monorepo` true:** it's a monorepo — proceed to enumerate packages below.
- **`is_monorepo` false, `ambiguous` false:** not a monorepo. Skip the rest of this step. **Preservation:** any pre-existing nested `CLAUDE.md` (in a subdirectory) is hand-authored — leave it untouched and list it under "Preserved hand-authored files" in the STEP 5 report. Deciding not to generate per-package files is NEVER a reason to delete existing ones (see File Preservation Policy).
- **`is_monorepo` false, `ambiguous` true:** ask via `AskUserQuestion`:
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

Use `monorepo.packages` as the package list — already resolved from workspaces globs, csproj/pyproject counts, and conventional directories (`apps/`, `services/`, `packages/`, `libs/`), and capped at 20. When `monorepo.packages_skipped` is non-zero, print: "Skipped N packages — generate per-package CLAUDE.md manually for any that need special context."

### Generate per-package CLAUDE.md + update root

The per-package file template, the generation rules (15–30 line local delta, 5-line stub for trivial packages, never overwrite, never duplicate root rules), and the root **Monorepo Layout** block live in **`.claude/references/monorepo-bootstrap.md`**. Read it now and follow it for each enumerated package, then add the Monorepo Layout block to the root CLAUDE.md (inside the 120-line cap).

## STEP 4.8: Seed Template Cache (for future re-runs)

After every generated file is written to disk, also write an **unmodified copy of the template output** to `.claude/.mtk-cache/v<MANIFEST_VERSION>/`. This cache is what `--audit` re-runs diff against for 3-way merges. The cache is gitignored.

Files to snapshot (skip any the engineer declined in `--preview`):
- `CLAUDE.md`
- `AGENTS.md`
- `.claude/rules/*.md`
- `.claude/references/pre-commit-review-list.md`
- `.claude/references/architecture-principles.md` (when this bootstrap generated it)
- `.claude/references/conventions.md` (when this bootstrap generated it)
- `.claude/references/product.md` (when this bootstrap generated it — STEP 3.8)
- `.claude/references/decisions.md` (when this bootstrap generated it — STEP 3.8)
- `.claude/detected-tools.json`

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
Secondary stacks: [comma-separated list, or "none"] — workflow skills (implement/fix) operate on the primary stack only.
Ingested AI configs: [list of source paths, or "none found"]

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
  ✓ .claude/references/product.md — [generated | preserved (existing)]
  ✓ .claude/references/decisions.md — [seeded | preserved (existing)]
  ✓ .claude/settings.json — merged [N] stack-specific entries
  ✓ Git pre-commit hook: [installed | ⚠️ existing hook found, skipped]
  ✓ CI staleness gate: [installed | declined | skipped (--non-interactive) | already exists]
  ✓ Tool prerequisites: [all found | ⚠️ N missing — see details above]
  ✓ Command verification: [N verified, N unverified, N skipped | skipped via --no-verify-commands]
  [if any unverified:]
      ⚠️ [name]: [first line of detail from verify-commands.sh]
  [if monorepo:]
  ✓ Monorepo detected — [N] packages found
      ✓ Generated per-package CLAUDE.md for: [list of packages]
      [⚠️ Skipped (already exists): list of packages]

Preserved hand-authored files (untouched):
  [list any pre-existing nested CLAUDE.md, custom commands/rules, or other non-MTK files left in place — or "none found"]
Retired prior MTK files (explicitly removed this run):
  [list any MTK-owned files this re-run superseded — or "none". If this section is non-empty, each entry must be an MTK-owned file, never hand-authored content.]

Updated: [N] | Created: [N] | Preserved (untouched): [N] | Needs review: [N]
[if Needs review > 0:]
Needs review:
  [one line per item — file path + the conflicting hunk/region that could not be auto-applied, per .claude/references/regen-diff-contract.md]

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
