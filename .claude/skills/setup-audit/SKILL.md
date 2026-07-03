---
name: setup-audit
description: Audit the repo to extract architecture principles, or with --merge unify audits from multiple repos into a single team-wide document
type: skill
user-invocable: false
---

# MTK Setup Audit — Extract or Unify Architecture Principles

## MTK File Resolution

MTK skills and shared references live either in the project (local install) or the plugin cache (marketplace install). Resolve once:

1. If `$CLAUDE_PLUGIN_ROOT` is set, prefix `.claude/skills/` and `.claude/references/` reads with it.
2. Otherwise, if `.claude/skills/context-engineering/SKILL.md` exists locally → project-relative paths work as-is.
3. Otherwise, fall back to `find ~/.claude/plugins -maxdepth 8 -name "SKILL.md" -path "*/mtk/*/context-engineering/*" -type f 2>/dev/null | head -1 | sed 's|/.claude/skills/context-engineering/SKILL.md||'`. If empty, MTK skills are unavailable — warn the engineer and proceed with `CLAUDE.md` only.

Always project-relative (never prefixed): `CLAUDE.md`, `.claude/tech-stack`, `.claude/rules/`, `tasks/`, `docs/`, `.claude/references/architecture-principles.md`, `.claude/references/pre-commit-review-list.md`.

---

This skill has two modes:

- **Default (single-repo audit):** Audit the current repository and produce `.claude/references/architecture-principles.md` describing how this team builds software.
- **`--merge` (multi-repo unification):** Combine architecture audits from multiple repos placed under `.claude/references/audits/` into a single unified document.

Pick based on the argument. If the engineer passed `--merge`, jump to **MERGE MODE** below. Otherwise, run **AUDIT MODE**.

---

# AUDIT MODE (default)

You are a senior architect performing an architectural audit of this repository. Document what the codebase ACTUALLY does, not what it should do. If you find inconsistencies, flag them as "⚠️ Inconsistency" — let the team decide which pattern to standardize on.

## STEP -1: Versioned Re-Run Detection

Before regenerating anything, resolve whether this is a re-run and whether a previous template cache exists.

1. **Read current manifest version.** The full manifest lives at the plugin root (marketplace installs have no project-local `.claude/manifest.json`); target repos carry the slim `.claude/mtk-version.json` written by `setup-bootstrap`:
   ```bash
   PM="${CLAUDE_PLUGIN_ROOT:-.}/.claude/manifest.json"
   [ -f "$PM" ] || PM=".claude/mtk-version.json"
   CURRENT_VERSION=$(python3 -c "import json; print(json.load(open('$PM'))['version'])")
   ```

2. **Read previous version from existing CLAUDE.md footer:**
   ```bash
   PREVIOUS_VERSION=$(grep -oE 'mtk-setup: v[0-9.]+' CLAUDE.md 2>/dev/null | head -1 | awk '{print $2}' | sed 's/^v//')
   ```
   If CLAUDE.md is absent or has no footer, `PREVIOUS_VERSION` is empty.

3. **Locate previous template cache:**
   ```bash
   PREV_CACHE=".claude/.mtk-cache/v${PREVIOUS_VERSION}"
   ```

4. **Classify:**

   | Case | Condition | Action |
   |---|---|---|
   | **First v7+ run on an existing repo** | CLAUDE.md exists but no footer OR cache missing | Go to **Migration Path** below |
   | **Clean re-run** | Footer present and `$PREV_CACHE` exists | Go to **Re-Run Merge Logic** below |
   | **Fresh bootstrap** | CLAUDE.md absent | Proceed directly to STEP 0 — no merge needed |

### Migration Path (pre-v7 → v7+)

The engineer is running `--audit` on a repo that was bootstrapped before the versioned cache existed. Prompt via `AskUserQuestion`:

```
question: "No previous template cache found. How should I treat the current generated files?"
header: "v7.0.0 migration"
options:
  - label: "hand-edited"
    description: "Current files contain engineer edits. I'll diff the new template against them and surface conflicts — won't clobber your edits."
  - label: "stock"
    description: "Current files are unmodified from the last bootstrap. Safe to overwrite with the new template."
  - label: "cancel"
    description: "Stop — I'll investigate first."
```

On `hand-edited`: follow the **no-ancestor** procedure in `.claude/references/regen-diff-contract.md` §3a — propose **only additive hunks** from the fresh template; never derive removal proposals by diffing the fresh template against the engineer's on-disk content. Sections the fresh template no longer emits are listed informationally under Needs review, not proposed as deletions.

On `stock`: copy existing files into `.claude/.mtk-cache/v${CURRENT_VERSION}-migration/` as pseudo-previous-template, then proceed to Re-Run Merge Logic. New template will cleanly overwrite.

On `cancel`: exit without modifying anything.

### Re-Run Merge Logic

For each file the audit would regenerate (`.claude/references/architecture-principles.md` is the primary target — other files only if bootstrap-mode and this section is reused from there), classify against the cached ancestor before touching anything:

```bash
PREV="${PREV_CACHE}/<file>"    # ancestor: previous stock template
CURRENT="<file>"                # what's on disk now
```

Classify and resolve every file per `.claude/references/regen-diff-contract.md` — read it now and follow §2 (classification), §3/§3a (proposals), §4 (cache rule), and §6 (invariants: the AskUserQuestion gate is not skippable, non-interactive runs defer engineer-edited files to NEEDS REVIEW, deletion is never an outcome). Do not restate or improvise the contract's rules here; report using its RESULT values.

At end of STEP -1, print a re-run summary:
```
📋 RE-RUN PLAN

FILE                                           CLASSIFICATION    RESULT
.claude/references/architecture-principles.md  engineer-edited   PROPOSED (4 hunks: 3 applied, 1 skipped)
.claude/references/conventions.md              stock             OVERWRITTEN (stock)
CLAUDE.md                                      protected         SKIP (protected)
.claude/rules/security.md                      protected         SKIP (protected)
```

RESULT values and their meanings are defined in the contract's §5; `SKIP (protected)` applies per the contract's protected-scope rule (`manifest.protected` minus this audit's own declared outputs — which is why `architecture-principles.md` is PROPOSED above while `CLAUDE.md` is SKIP).

If any file has `NEEDS REVIEW` hunks, print: "Re-run left <N> file(s) with hunks needing review. Resolve before the next `--audit` run."

After re-run merge, update `.claude/.mtk-cache/v${CURRENT_VERSION}/` per the contract's §4 cache rule (fresh stock template, fully-resolved files only). Then proceed to the report step (do not re-run STEP 0-4; the merge already produced the new content).

## STEP 0: Determine The Tech Stack

Read `.claude/tech-stack` to determine the active stack. If missing, detect it:

```bash
bash scripts/setup-detect.sh --json
```
Read `stacks` (array) and `primary_candidate` from the output.

If multiple stacks detected (`stacks` has more than one entry), ask the engineer which to audit first. Multi-stack repos may need multiple audits.

If no supported stack detected (`stacks` is empty), stop and tell the engineer to run `/mtk-setup` first or add a tech stack skill.

Then load `.claude/skills/tech-stack-{stack}/SKILL.md`. The `## Scan Recipes` section provides the bash commands for that stack.

## STEP 0.5: Build the Ranked Symbol Graph (repomap)

Before running ad-hoc scan recipes, produce a deterministic symbol graph. This is the **primary input** to the audit — scan recipes remain a supplement, not the source of truth.

```bash
bash scripts/repomap.sh <stack> --budget=4000 --out=.claude/.mtk-cache/repomap.json
```

Read the resulting JSON. The `fit` field tells you the quality tier:

| `fit` value | Meaning | Audit behavior |
|---|---|---|
| `full` | All symbols fit within budget | Cite freely — full graph available |
| `ranked` | Top-N by in-edge count (PageRank-ish) | Cite top symbols; acknowledge truncation in provenance section |
| `defer-to-mcp` | .NET only — call `mcp__csharp-lsp__csharp_symbols` directly to enrich | Use MCP tool for the ranked pass, then cite |
| `fallback` | No tree-sitter / no LSP available | Audit degrades to scan-recipes-only; **provenance section must state this** |

When `fit != "fallback"`, the audit prompt changes character — instead of "read the codebase and extract principles", become:

> "The following ranked symbols are the structural backbone of this codebase (top by incoming-reference count). For each architectural principle you propose, cite at least one symbol from this list that evidences it. Do not claim a principle you cannot evidence."

Pass the ranked JSON into the prompt context. Keep the symbol list visible while writing principles.

## STEP 0.9: Scan Ledger (resumable)

Long audits on large repos must survive crash, compaction, or session handoff. Use the existing `scripts/workflow-artifact.sh` to record progress as a resumable ledger.

1. **Resume check.** Before starting, run `scripts/workflow-artifact.sh list`. If an incomplete (`status` not `completed`/`abandoned`) artifact of type `setup-audit` exists:
   - If its `updated` timestamp is **less than 24h old**, ask via `AskUserQuestion`:
     ```
     question: "Found an in-progress setup-audit from <updated>. How do you want to proceed?"
     header: "Resume audit"
     options:
       - label: "Resume from <current_step>"
         description: "Skip completed steps, reload their outputs summaries instead of re-scanning."
       - label: "Start fresh (abandon)"
         description: "Abandon the previous run and start a new audit from STEP 0."
       - label: "Cancel"
         description: "Stop — don't touch anything."
     ```
     On "Resume from <current_step>", skip every STEP already marked `step_completed` in the artifact's event log and reload its recorded `outputs`/`summary` instead of re-running the scan. On "Start fresh (abandon)", run `scripts/workflow-artifact.sh abandon <uuid> --reason "engineer requested restart"`, then continue to step 2. On "Cancel", stop without modifying anything.
   - If its `updated` timestamp is **24h or older**, auto-abandon it — `scripts/workflow-artifact.sh abandon <uuid> --reason stale-24h` — print a one-line notice, and continue to step 2 without asking.

2. **Start (fresh run).** `bash scripts/workflow-artifact.sh init setup-audit --goal "<one-line audit goal>"` and record the returned UUID for the rest of the run.

3. **After each numbered STEP.** Once a STEP completes, record it on the ledger:
   ```bash
   scripts/workflow-artifact.sh event <uuid> step_completed --data '{"step":"STEP 2","outputs":["<files written>"],"summary":"<one concrete sentence>"}'
   scripts/workflow-artifact.sh set <uuid> current_step="STEP 2"
   ```
   Summaries must be concrete — "scanned 214 files, 3 inconsistencies", never "made progress" or other vague phrasing. A vague summary is useless on resume: the next session has nothing to reload.

4. **On completion.** `scripts/workflow-artifact.sh set <uuid> status=completed`.

**Context economy (large repos).** For repos with more than 1000 tracked source files, process each scan category (STEP 1 and STEP 2.5) in turn — write its findings into the ledger event immediately after that category finishes, keep only a 1-2 sentence summary in working context, then move to the next category. The ledger, not the conversation, is the working memory; don't hold the full scan output in context waiting to write the doc at the end.

## STEP 1: Run The Scan Recipes

Execute each scan recipe block from the active tech stack skill in order. The standard categories are:

1. **Project Structure** — solutions, projects/modules, dependencies, framework version, key packages
2. **Patterns In Use** — frameworks, design patterns (CQRS, repository, validation, mapping)
3. **Data Layer** — ORM configuration, query patterns, migrations, raw SQL usage
4. **Infrastructure** — cloud services, IaC, containers, networking, secrets, messaging
5. **Naming Conventions** — file/folder layout, controller/handler/service patterns
6. **Testing Patterns** — frameworks, providers, fixture patterns, integration test bases
7. **Configuration** — config files, options patterns, logging

For each block, sample 2-3 representative files in detail to understand intent — not just file counts.

**Verbatim version extraction (MANDATORY).** Framework and runtime versions in `architecture-principles.md`, `CLAUDE.md`, and `detected-tools.json` MUST be quoted verbatim from the manifest file — never paraphrased, rounded, or restated from training-data knowledge. Always read and cite:

- TypeScript / Node: `cat package.json | jq '.dependencies.next, .dependencies.react, .devDependencies.typescript, .engines.node'` (or `grep -E '"(next|react|typescript|node)"'` if `jq` unavailable). Quote the actual range string (e.g., `next: ^15.0.3` → write "Next.js 15", NOT "Next.js 16").
- Python: `grep -E '^\s*(python|django|fastapi|flask|sqlalchemy)\s*=' pyproject.toml` (or the `[project] dependencies` block).
- .NET: `grep -hE '<TargetFramework[s]?>|<PackageReference Include=' **/*.csproj` — quote both `TargetFramework(s)` (e.g., `net9.0`) and the explicit `Version=` on each `PackageReference`.

If the manifest file is missing or unparseable, write `unknown` — never guess. Hallucinated versions ("Next.js 16" when `package.json` says `^15.0.3`) are a recurring audit failure; this rule exists to block them.

## STEP 2: Run Stack-Agnostic Cross-Cutting Scans

These apply to any tech stack:

```bash
# Git conventions
git log --oneline -20
git branch -a | head -20
find . -name "pull_request_template*"

# CI/CD
find . \( -name "*.yml" -o -name "*.yaml" \) | grep -i "github\|pipeline\|ci\|cd\|workflow\|azure\|jenkins"

# Docker
find . \( -name "Dockerfile" -o -name "docker-compose*" -o -name ".dockerignore" \)
```

## STEP 2.5: Extract Codebase Conventions

Beyond architecture principles, extract the specific conventions this codebase follows. These are more granular than architecture — they're the patterns a new developer (or AI) needs to match when writing code in this repo.

Run these convention extraction scans:

### Naming Conventions
```bash
# Handler/controller naming pattern (e.g., {Verb}{Entity}Handler, {Entity}Controller)
find . \( -name "*Handler.cs" -o -name "*Controller.cs" -o -name "*handler.py" -o -name "*controller.py" -o -name "*Handler.ts" -o -name "*Controller.ts" \) 2>/dev/null | head -20
# Service naming pattern
find . \( -name "*Service.cs" -o -name "*service.py" -o -name "*Service.ts" \) 2>/dev/null | head -20
# Test naming pattern
find . \( -name "*Tests.cs" -o -name "*Test.cs" -o -name "*_test.py" -o -name "*.test.ts" -o -name "*.spec.ts" \) 2>/dev/null | head -20
```

### Folder Structure Conventions
```bash
# Feature/slice folder structure
find . -type d -maxdepth 4 -not -path "*/node_modules/*" -not -path "*/bin/*" -not -path "*/obj/*" -not -path "*/.git/*" 2>/dev/null | head -40
# Common subfolder patterns within features
find . -type d \( -name "Validators" -o -name "Handlers" -o -name "Models" -o -name "DTOs" -o -name "Events" -o -name "Services" \) 2>/dev/null | head -20
```

### DI Registration Patterns
```bash
# .NET: How services are registered (extension methods, inline, module-based)
grep -rn "services\.Add\|builder\.Services\|IServiceCollection" --include="*.cs" -l 2>/dev/null | head -10
# Python: Dependency injection approach
grep -rn "Depends\|@inject\|Container\|provide" --include="*.py" -l 2>/dev/null | head -10
```

### Response/Error Patterns
```bash
# .NET: Result pattern, exception handling, response envelope
grep -rn "Result<\|IResult\|Results\.\|ProblemDetails\|ApiResponse" --include="*.cs" -l 2>/dev/null | head -10
# Shared: Error response shapes
grep -rn "ErrorResponse\|error_response\|ErrorResult\|ApiError" -l 2>/dev/null | head -10
```

### Test Patterns
```bash
# Test base classes and fixtures
grep -rn "class.*Test.*Base\|class.*Fixture\|class.*TestBase\|IClassFixture\|IAsyncLifetime" --include="*.cs" -l 2>/dev/null | head -10
grep -rn "class.*TestCase\|@pytest.fixture\|conftest" --include="*.py" -l 2>/dev/null | head -10
# Test assertion style (FluentAssertions, shouldly, Assert, expect)
grep -rn "\.Should()\|Assert\.\|\.ShouldBe\|expect(" --include="*.cs" --include="*.ts" --include="*.py" -l 2>/dev/null | head -5
```

For each category, sample 2-3 representative files to understand the actual convention — not just the file names.

**Majority-verify conventions, never cherry-pick (MANDATORY).** A convention is what the codebase does *predominantly*, not what one example happens to do. In the eval, a handler-naming convention was prescribed from a single example while the prescribed form was actually the 32% minority. For every convention claim ("handlers are named X", "money is `decimal`(18,4)"):
- Count BOTH (all) competing forms with a concrete command run from the repo root, e.g. `grep -rEc` or `find … | sed … | sort | uniq -c`.
- Report the DOMINANT form with its proportion (e.g. "`{Verb}{Entity}Handler` — 21/31 handlers, 68%"). If no form exceeds ~60%, call it `[AMBIGUOUS]`/split rather than prescribing one.
- Run counts from the repo root and against the correct directory — verify the path holds the files you think it does before counting (an eval money-precision count came from the wrong directory).

Generate `.claude/references/conventions.md`:

```markdown
# Codebase Conventions — [Project Name]

> Auto-generated by setup-audit on [date].
> These conventions are specific to THIS codebase. AI agents should match
> these patterns when writing new code in this repo.

## Naming Conventions
- **Handlers:** [pattern found, e.g., `{Verb}{Entity}Handler`]
- **Controllers:** [pattern found]
- **Services:** [pattern found]
- **Tests:** [pattern found, e.g., `{ClassName}Tests`, `{Method}_Should_{Expectation}`]
- **Folders:** [pattern found, e.g., features use `Features/{EntityName}/` with subfolders for Handlers, Validators, Models]

## File Organization
- [Describe the folder structure convention observed]
- [Feature-per-folder vs layer-per-folder vs hybrid]
- [Where new features should be added]

## DI Registration
- [How services are registered: extension methods, inline in Program.cs, module-based]
- [Naming convention for DI extension methods, e.g., `Add{Feature}Services()`]

## Response & Error Handling
- [Result pattern, exception strategy, response envelope]
- [How errors are returned to API consumers]

## Test Conventions
- [Test framework and assertion library]
- [Base classes or fixtures used]
- [Naming convention for test methods]
- [Where test files live relative to source]

## Other Patterns
- [Any other consistent conventions found]
```

This file is NOT protected (it gets regenerated on re-audit) and is loaded by the compliance-reviewer alongside architecture-principles.md.

## STEP 2.6: Emit Detected Tools Manifest

Before writing prose architecture documents, emit a machine-readable manifest of the tools and frameworks actually present in this repo. `setup-bootstrap` reads this file to **prune stack reference files that don't apply** (e.g., don't ship a Drizzle data-layer checklist when the repo uses Prismic).

Write to `.claude/detected-tools.json`:

```json
{
  "stack": "typescript | python | dotnet",
  "secondary_stacks": ["dotnet" | "python" | "typescript"] | [],
  "framework": ["nextjs-pages" | "nextjs-app" | "express" | "fastapi" | "fastify" | "nest" | "tauri" | "aspnetcore" | "flask" | "django" | ...],
  "data_layer": ["prismic" | "prisma" | "drizzle" | "tanstack-query" | "sqlalchemy" | "efcore" | "dapper" | "raw-sql" | ...],
  "test_framework": ["vitest" | "jest" | "playwright" | "cypress" | "pytest" | "xunit" | "nunit"] | [],
  "package_manager": "yarn | pnpm | npm | bun | pip | poetry | uv | nuget",
  "deployment": ["vercel" | "aws" | "azure" | "gcp" | "self-hosted" | ...],
  "additional": ["styled-components", "tailwind", "algolia", "sentry", "...any notable libs"]
}
```

**Rules:**
- Use empty arrays (`[]`) when nothing is detected — never use `null` or omit keys. `setup-bootstrap` treats absence as "unknown" and falls back to "ship everything", which is the current bloat behavior we are fixing.
- `secondary_stacks`: lowercase stack ids only (`dotnet` / `python` / `typescript`); empty array when single-stack; populated from `setup-detect.sh --json`'s `stacks` array minus the primary `stack` (F11).
- Use lowercase, hyphenated identifiers. These match the `tools:` arrays in stack reference frontmatter.
- Detection sources: Step 1 scan recipes (project structure, data layer, infrastructure, testing patterns), `package.json` / `pyproject.toml` / `*.csproj` dependency lists, lockfiles, and config files (`next.config.js`, `vitest.config.ts`, `Startup.cs`, etc.).
- When uncertain, include the candidate AND add a note in `additional` (e.g., `"react-query-v3-limited"`) so reviewers can verify.

This file is regenerated on every audit. It is consumed by `setup-bootstrap`'s reference-pruning step (`STEP 3.6`).

## STEP 3: Generate Architecture Principles Document

Based on EVERYTHING you found, create `.claude/references/architecture-principles.md`:

```markdown
# Architecture Principles — [Project Name]

> Auto-generated by scan on [date].
> Tech stack: [stack name]
> Based on analysis of [N] source files across [N] projects/modules.
> This document captures the ACTUAL architectural patterns in this codebase.

---

## 1. System Overview
- Project name and purpose (inferred from code and namespaces/modules)
- Stack and version: [from scan]
- Solution / module structure: [describe]
- Key dependencies: [list major packages and what they're used for]

## 2. Layer Architecture
- [Describe the actual layers found]
- [Dependency direction rules observed]
- [What belongs in each layer — with examples from the codebase]

## 3. Design Patterns in Use
### 3.1 [Pattern Name]
- How it's implemented here
- File naming conventions
- Example from codebase

[Continue for each pattern found]

## 4. API Design
- Routing conventions
- Authentication/authorization approach
- Response format/envelope pattern
- Error handling pattern
- Versioning approach (if any)

## 5. Data Layer
- ORM and configuration style
- Read patterns
- Write patterns
- Connection management
- Entity conventions (base classes, timestamps, soft delete)
- Money/decimal handling
- Migration strategy

## 6. Testing Approach
- Test framework and tools
- Test provider for data layer behavior
- Test organization
- Naming conventions
- Integration test patterns

## 7. Infrastructure
- Hosting target
- IaC approach
- Cloud services used and their purpose
- Networking architecture
- Container strategy
- Configuration/secrets management
- Logging and observability

## 8. Cross-Cutting Concerns
- Exception handling strategy
- Correlation/tracing
- Caching approach
- Background processing
- DI lifetime conventions

## 9. Inter-Service Communication
- Sync: [REST/gRPC/etc.]
- Async: [SQS/SNS/events/etc.]
- Contracts and versioning approach

## 10. Inconsistencies Found
⚠️ [List any patterns that are inconsistent across the codebase]
⚠️ [Note: these are opportunities to standardize, not bugs]
```

### Rules for Generation:
- Document what IS, not what should be. This is a descriptive document.
- Include actual code paths as examples (e.g., "See `src/handlers/user_handler.py`")
- Flag inconsistencies — where the same thing is done differently in different places
- If a pattern is only used in some places, note its adoption percentage
- Be specific about file locations so engineers can find examples
- Don't skip sections — if you found nothing for a section, say "Not found in this codebase"
- **Counter-example gate before absolute language (MANDATORY).** Before writing any principle using `NEVER`, `ALWAYS`, `all`, `every`, or `must`, grep for counter-examples. A pattern seen *somewhere* is not a law. Real failures: "all API handlers validate with Yup" (only 1 of 9); "never use `DateTime.UtcNow`" (used in 2 files). If ANY counter-example exists, do not state it as absolute — soften to "most"/"prefer", report the dominant form with its proportion, and tag `[INFERRED:N]` or `[AMBIGUOUS]` (never `[EXTRACTED]`). Reserve absolute language + `[EXTRACTED]` for genuinely zero-counter-example facts.
- **Reproducible numeric claims (MANDATORY).** Every numeric claim (project counts, file censuses, "N of M" proportions) must carry the exact shell command that produced it, runnable from the repo root, so `verify-claims` can re-run it. Real failures: "18 projects" (actual 17, propagated to 4 lines); grep counts that don't reproduce. If you cannot produce a reproducible command, drop the number and state the fact qualitatively ("several projects") instead of guessing one.
- **Capability requires a usage site, not just an import (MANDATORY).** Do NOT assert a capability or integration exists from an import/using/package-reference alone. Real failures: "CDK provisions EC2/VPC" inferred from a dead `using Amazon.CDK.AWS.EC2;` (zero VPC/Subnet/SG in code); a dead `AWSSQSResource` (0 references) presented as active "SQS access". Require a USAGE SITE — instantiation, call, or DI registration — before claiming the capability. If only an import exists with no usage, omit it or explicitly mark it `dead/unused reference`.
- **Security-claim grounding (MANDATORY).** NEVER assert that a sanitization / validation / audit / secret-handling path EXISTS unless a usage site is found (imported AND called). Real failures: "use the existing dompurify/sanitize-html path" while dompurify is imported nowhere; "never log raw event XML" framed as an existing invariant while code logs raw XML + MQ creds. If the protection is ABSENT, state it as a GAP ("no input sanitization found on X — add it"), not as an existing convention to follow.
- **Interview answers are authoritative (MANDATORY).** When `.claude/setup-answers.json` exists, its contents are authoritative human input, not a scan hypothesis. Principles or rules sourced from it cite it as their evidence anchor (e.g. `Evidence: engineer interview — .claude/setup-answers.json (hard_nevers)`) and are never dropped or reworded by regeneration. If a fresh scan contradicts an interview answer, do not silently pick a side — emit a "Needs review" item describing the conflict instead.

### Confidence Tagging (S1.15)

Every principle (or sub-bullet) the audit emits must carry a **confidence tag** so downstream tools (drift detection, code review) know how strict to be. Three tags:

- `[EXTRACTED]` — directly observed in the code. High trust. Drift detection blocks on contradictions.
- `[INFERRED:0.0–1.0]` — pattern inference with explicit confidence (`0.9` strong, `0.7–0.89` reasonable, `<0.7` weak). Drift detection flags rather than blocks.
- `[AMBIGUOUS]` — sources disagree, or the pattern is split. Drift detection notes without verdict.

**Every tagged line must cite evidence** — file:line, a path glob with a hit count, or a commit SHA. No tag without evidence.

**Grade tags by evidence, not vibes (eval fix):** a directly-observable fact with a file:line citation is `[EXTRACTED]` — do NOT under-tag it `[INFERRED:0.5]` (e.g. EF Core at `Program.cs:61 UseSqlServer` is EXTRACTED). An **absence** claim ("no raw SQL", "no test project") is `[EXTRACTED]` only when you cite the zero-result command that proves it; otherwise tag it `[INFERRED]`.

Format the principles section so each line follows this shape:

```markdown
## 4. API Design
- [EXTRACTED] All controllers return `ApiResponse<T>` envelope. Evidence: `src/Api/Controllers/*.cs` (23 of 23 hits).
- [INFERRED:0.85] Versioning convention is URL-segment `v1/`, `v2/`. Evidence: 11 of 13 routes follow this; 2 in `Legacy/` use header versioning.
- [AMBIGUOUS] Authorization model — split between `[Authorize]` attributes (handlers) and middleware-based policies (controllers). Evidence: see `Auth/AuthorizationMiddleware.cs:42` and `Api/Handlers/UserHandler.cs:15`.
```

Add a legend block at the top of `architecture-principles.md` (right after the header):

```markdown
> **Confidence legend:**
> `[EXTRACTED]` = directly observed in code (high trust — drift detection blocks).
> `[INFERRED:0.0–1.0]` = pattern inference with confidence score (drift detection flags).
> `[AMBIGUOUS]` = sources disagree or pattern is split (drift detection notes without verdict).
> Every tag must cite evidence (file:line, glob with hit count, or commit SHA).
```

Aim for `[EXTRACTED]` whenever you can; downgrade to `[INFERRED]` only when fewer than 100% of cases match. Use `[AMBIGUOUS]` sparingly — it's an explicit "team decision needed" marker, not a way to dodge analysis.

### Emit Ambiguities Manifest

Every `[AMBIGUOUS]` line the audit writes ALSO lands as an entry in `.claude/.mtk-cache/ambiguities.json`, regenerated wholesale on every audit run (stale file replaced, never appended to):

```json
{"version":1,"generated":"<ISO8601_UTC>","ambiguities":[{"claim":"<the claim text>","competing_forms":[{"form":"...","count":N},{"form":"...","count":M}],"evidence":"<the line's evidence citation>","doc":"architecture-principles.md|conventions.md","anchor":"<section heading or file:line the claim cites>"}]}
```

- One entry per `[AMBIGUOUS]` line emitted this run: `claim` is the line's text, `evidence` its citation, `doc` the file it lives in, `anchor` the section heading (or file:line) it cites.
- `competing_forms` counts come from the majority-verify counting this audit already performs (§ Confidence Tagging above) — never invented.
- No `[AMBIGUOUS]` lines this run → file absent, or `"ambiguities": []`, both read by consumers as "nothing ambiguous."
- Consumed by `setup-bootstrap` STEP 2.5's adaptive interview.

## STEP 3.5: Provenance Section (mandatory)

Append a `## Provenance` section to `architecture-principles.md`. This proves each principle is evidence-based, not invented:

```markdown
## Provenance

Generated by setup-audit at <ISO8601_UTC> against mtk-setup v<version>.

**Repomap input:**
- Symbol graph: `.claude/.mtk-cache/repomap.json` (fit: `<fit>`, <N>/<total> symbols, <files> files)
- Fallback reason (if any): <reason or "n/a">

**Symbol evidence per principle:**

| Principle | Evidencing symbols |
|---|---|
| CQRS via MediatR | `InvoiceCommandHandler`, `IMediator`, `OrderQueryHandler` (3 handlers, 47 refs) |
| Value objects for money | `Money`, `Currency`, `IMoney` (3 symbols, 72 refs) |
| ... | ... |
```

When `fit == "fallback"`, replace the symbol evidence table with:
> "⚠️ No deterministic symbol graph available (tree-sitter/LSP missing). Principles below are derived from scan recipes only — re-run with tree-sitter installed for evidence-backed output."

The provenance section is not optional. If you produced principles without evidence from the repomap, you either hallucinated or the repomap fell back — either way, disclosure is required.

## STEP 3.6: PR review mining (optional, with --mine-prs)

When `--mine-prs` is passed (or the engineer asks to seed principles from PR feedback), run:

```bash
bash scripts/pr-review-mine.sh --prs 10
```

Each candidate phrase is presented to the engineer for per-line approval. Approved phrases are appended to `.claude/references/architecture-principles.md` with the tag `[MINED:feedback]` and the PR numbers cited as evidence. Untagged or auto-promoted mining is forbidden — see `.claude/references/pr-mining-patterns.md`. Fails soft when `gh` is missing or unauthenticated.

## STEP 3.7: Stamp + verify generated docs (MANDATORY)

Before reporting completion, every generated doc (`architecture-principles.md`, `conventions.md`) must be (a) stamped with the audit SHA and (b) verified against the codebase. See `.claude/references/audit-grounding.md` for the full ruleset.

### Stamp

Prepend a stamp block to each generated doc (after the first `>` blockquote, before the body):

```
<!-- mtk-stamp
audited-against: $(git rev-parse HEAD)
audited-at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
mtk-version: <from .claude/manifest.json>
previous-stamp: <previous audited-against sha, or "none">
sections-changed: <comma-separated H2 titles, or "none">
claims-delta: +<added> ~<modified> -<removed>
-->
```

The last three fields (`previous-stamp`, `sections-changed`, `claims-delta`) are **re-run-only** — a fresh first run (no prior stamped doc) omits them entirely. Compute them by diffing the regenerated doc against its previous on-disk version **before writing**: `previous-stamp` is the prior `audited-against` value (or `"none"` if there was no prior stamp); `sections-changed` lists the `##` headings whose content differs (or `"none"`); `claims-delta` counts tagged claim lines added/modified/removed between the two versions. This is the audit trail for what a re-run actually changed.

For `CLAUDE.md` (written by `setup-bootstrap`), the stamp lives in a **footer** comment block — human edits collect above it.

### Rule tags

Every prescriptive rule line in `architecture-principles.md` must carry one of `[ENFORCED]` / `[CONVENTION]` / `[ASPIRATIONAL]` with an evidence anchor. These tags are distinct from the S1.15 principle tags (`[EXTRACTED]/[INFERRED:N]/[AMBIGUOUS]`):
- Principle tags describe **what the codebase does** (descriptive).
- Rule tags describe **what reviewers should do about it** (prescriptive).

Untagged rules are quarantined into a `## Untagged (review)` section.

### Verify-claims pass

Run after writing each generated doc:

```bash
bash scripts/verify-claims.sh .claude/references/architecture-principles.md
bash scripts/verify-claims.sh .claude/references/conventions.md
```

This script:
- parses tagged claim lines,
- grep/AST-checks every backticked evidence anchor against the working tree,
- downgrades zero-hit `[EXTRACTED] → [INFERRED:0.5 unverified]` and `[ENFORCED] → [ASPIRATIONAL unverified]` **in place**,
- writes per-doc reports `.claude/.mtk-cache/weak-claims-<doc>.json` (full) and `.claude/.mtk-cache/weak-claims-<doc>.md` (top-5 paste-ready).

The audit is not complete until verify-claims has run. A passing audit surfaces weak claims; it does not pretend they don't exist.

### Retry loop (one pass)

After the first `verify-claims.sh` run on a doc, read `.claude/.mtk-cache/weak-claims-<doc>.json`. For each downgraded claim, make **one** re-derivation attempt:
- Fix the evidence anchor — the right path, glob, or symbol — so the claim resolves under its original tag, OR
- If no anchor resolves the claim, delete the claim line — **but only if this run generated that line** (byte-identical to the freshly generated template's version). A line the engineer authored or modified is never deleted here: leave the downgraded tag in place for the engineer to resolve. Every deleted line must be itemized in the STEP 4 report.

Rewrite the doc, then run `verify-claims.sh` once more. Downgrades that survive this second pass are accepted and reported as-is. Never re-upgrade a tag (`[INFERRED:0.5 unverified] → [EXTRACTED]`, `[ASPIRATIONAL unverified] → [ENFORCED]`) without a resolving anchor found during the retry. Never loop more than once per doc.

### Seed template cache

After verify-claims (and the retry loop) completes on a fresh audit, snapshot the final stock outputs to `.claude/.mtk-cache/v<MANIFEST_VERSION>/references/` (`architecture-principles.md`, `conventions.md`) and `.claude/.mtk-cache/v<MANIFEST_VERSION>/detected-tools.json` — same layout and retention rules as `setup-bootstrap` STEP 4.8. Without this seed, the next re-run or refresh has no ancestor and must classify these files conservatively as engineer-edited (regen-diff-contract §2), losing the stock fast-path.

### Transient-state lint

The verify pass also flags lines with branch names (`^(feat|fix|chore|docs|refactor)/`), PR numbers (`#\d+`), dates other than the audit date, and author emails. Detected lines are dropped with a warning — re-add with stable phrasing if needed.

### Terminology denylist

The verify pass cross-references generated text against the denylist in `.claude/references/audit-grounding.md` §4 ("path alias" vs `baseUrl`, "HTML" vs JSX, "enum" vs typed object, etc.). Flagged lines appear in `weak-claims.json` with `reason: terminology-needs-review` — never auto-rewritten.

## STEP 4: Present Results

```
✅ MTK SETUP AUDIT COMPLETE

Repository: [name]
Tech stack: [stack]
Audited: [N] source files across [N] projects/modules

Architecture profile:
  - Stack: [name + version]
  - API style: [from scan]
  - Data layer: [from scan]
  - Patterns: [list key patterns found]
  - Layers: [list layers]
  - Database: [from scan]
  - Hosting: [from scan]
  - IaC: [from scan]
  - Messaging: [from scan]
  - Testing: [from scan]

Generated:
  ✓ .claude/references/architecture-principles.md (stamped against <sha>)

Inconsistencies found: [N]
  [list the top 3 if any]

⚠️ Weak claims surfaced: [N]
  See .claude/.mtk-cache/weak-claims-<doc>.md (per generated doc) — paste into PR body or review note.
  Top failure modes: zero-hit anchors → likely fabricated; terminology flags → likely imprecise.

Next steps:
  1. Review the generated document — edit anything that's wrong
  2. Decide how to resolve any inconsistencies flagged
  3. Run /mtk-setup to generate the full CLAUDE.md (if not already done)
  4. To unify with audits from other repos: copy this doc to <hub>/.claude/references/audits/<repo>.md and run /mtk-setup --merge there
```

---

## AUDIT MODE — IMPORTANT
- This mode is READ-ONLY except for writing the output document
- Never modify source code during an audit
- If `.claude/references/architecture-principles.md` already exists, use AskUserQuestion before overwriting
- Create `.claude/references/` directory if it doesn't exist
- The actual scan commands live in the tech stack skill — do not duplicate them here. If they need updating, update the tech stack skill.
- **Ignore patterns (S1.14):** Tree walks honor `.mtkignore` at the repo root. Patterns are loaded automatically by `scripts/repomap-tree-sitter.py` (which `scripts/repomap.sh` invokes). Engineers control what the audit "sees" by editing `.mtkignore` — same syntax as `.gitignore`. Missing file is non-fatal; falls back to built-in defaults. Do **not** invent ad-hoc exclude logic in this skill.
- **Shrink-guarded write (S3.16):** When writing or regenerating `architecture-principles.md`, write to a temp file first then promote it via `mtk_guarded_write`. This refuses silent truncation if a partial regenerate would shrink the file > 50% bytes or > 20% lines. Override with `MTK_SHRINK_GUARD_OVERRIDE=1` for intentional rewrites.
  ```bash
  . hooks/lib/shrink-guard.sh
  mtk_guarded_write .claude/references/architecture-principles.md "$tmp"
  ```

---

# MERGE MODE (--merge)

You have audited multiple repositories and now want a single, unified architecture principles document. This mode reads audit files from `.claude/references/audits/` and produces a unified doc.

## STEP 0: Locate Inputs

```bash
ls -la .claude/references/audits/
```

Each file is an architecture audit from a different project (e.g., `payfac.md`, `collection-system.md`, `bnpl.md`).

If the directory is empty or doesn't exist, tell the engineer:
> "No audit files found. To use --merge:
> 1. Run `/mtk-setup --audit` (without --merge) in each repo (payfac, collection-system, etc.)
> 2. Copy each generated `.claude/references/architecture-principles.md` into THIS repo at:
>    `.claude/references/audits/payfac.md`
>    `.claude/references/audits/collection-system.md`
>    etc.
> 3. Run `/mtk-setup --merge` again."

## STEP 1: Analyze Across Audits

For each section of the architecture doc, compare across all audits:

### What's Consistent (standardize on this)
- Patterns used the same way across all projects → these are your team's actual standards
- Same tools and frameworks → these are your tech stack

### What's Different (team needs to decide)
- Different patterns for the same concern → flag as "needs alignment"
- Different conventions → flag with a recommendation

### What's Unique (project-specific)
- Patterns that only appear in one project → document as project-specific, not team-wide

### Confidence Tag Merge Rules (S1.15)

Per-repo audits already carry `[EXTRACTED] / [INFERRED:N] / [AMBIGUOUS]` tags (see STEP 3 of single-repo audit). When merging:

- All sources tag the principle `[EXTRACTED]` and agree → keep `[EXTRACTED]`.
- Mixed tags or one source `[INFERRED]` → output `[INFERRED:min(confidences)]`. Cite both source repos.
- Sources contradict the principle itself → output `[AMBIGUOUS]` with both source pointers.
- A principle appears in only one repo → keep its original tag, mark as project-specific.

## STEP 2: Generate Unified Document

Generate `.claude/references/architecture-principles.md` (overwriting if it already exists — ask via AskUserQuestion first):

```markdown
# Moberg Architecture Principles

> Unified from audits of: [list repos]
> Generated: [date]
>
> This document defines team-wide architectural standards.
> Project-specific patterns are noted where they differ.

---

## Team-Wide Standards
[Patterns consistent across ALL scanned projects]

## Recommended Alignments
⚠️ [Patterns that differ between projects — with recommendation on which to standardize]

## Project-Specific Patterns
### PayFac
[Unique patterns]
### Collection System
[Unique patterns]
[etc.]
```

## STEP 3: Present Results

Present the unified doc and highlight the key decisions the team needs to make. Do not make standardization decisions for the team — flag them clearly so engineers can debate and decide.

## MERGE MODE — IMPORTANT
- This mode is READ-ONLY except for writing the unified output document
- If `.claude/references/architecture-principles.md` already exists, use AskUserQuestion before overwriting
- Do not modify the input audit files in `.claude/references/audits/`
