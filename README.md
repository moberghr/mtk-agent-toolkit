<div align="center">

# Moberg Toolkit

### AI-Assisted Development Framework for .NET Fintech Teams

**Enforce coding standards, security compliance, and architectural consistency across every AI-generated line of code.**

[![Version](https://img.shields.io/badge/version-4.1.0-blue.svg)](https://github.com/moberghr/claude-helpers/releases)
[![Platform](https://img.shields.io/badge/platform-Claude%20Code-purple.svg)](https://claude.ai/code)
[![.NET](https://img.shields.io/badge/.NET-8.0%2B-512BD4.svg)](https://dotnet.microsoft.com/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[Quick Start](#quick-start) | [Architecture](#architecture) | [Commands](#commands) | [Skills](#skills) | [Review Agents](#review-agents) | [Contributing](#contributing)

</div>

---

## Why This Exists

AI code assistants are powerful but unpredictable. Without guardrails, they produce code that compiles but violates your team's standards: wrong patterns, missing tests, security gaps, inconsistent style. In fintech, where every line of code touches money, compliance, or customer data, "it works" is not enough.

The Moberg Toolkit solves this by embedding your engineering standards directly into the AI workflow. Every feature goes through planning, implementation, verification, and adversarial review, all guided by your team's actual patterns and rules.

**What it enforces:**
- Coding standards are checked, not suggested
- Security and compliance rules are embedded in every workflow phase
- Tests are required before code is considered complete
- Review agents find real problems, not just style nits
- Evidence of passing builds and tests is required before claiming "done"

**What it does not do:**
- Replace human judgment on architecture decisions
- Auto-merge or auto-deploy anything
- Work outside of Claude Code (it is a Claude Code plugin)

---

## Table of Contents

- [Quick Start](#quick-start)
- [Architecture](#architecture)
  - [Design Principles](#design-principles)
  - [Component Model](#component-model)
  - [How Components Compose](#how-components-compose)
- [Commands](#commands)
  - [implement](#implement) | [fix](#fix) | [init](#init) | [scan](#scan) | [quick-check](#quick-check)
  - [install](#install) | [update](#update) | [doctor](#doctor) | [validate](#validate) | [merge](#merge)
- [Skills](#skills)
  - [Core Workflow](#core-workflow-skills)
  - [Quality & Review](#quality--review-skills)
  - [Meta & Enabling](#meta--enabling-skills)
- [Review Agents](#review-agents)
  - [Two-Stage Review Model](#two-stage-review-model)
  - [compliance-reviewer](#compliance-reviewer)
  - [test-reviewer](#test-reviewer)
  - [architecture-reviewer](#architecture-reviewer)
- [References](#references)
- [Workflows](#workflows)
  - [Feature Implementation](#feature-implementation-workflow)
  - [Bug Fix](#bug-fix-workflow)
  - [Repository Onboarding](#repository-onboarding-workflow)
  - [Toolkit Lifecycle](#toolkit-lifecycle-workflow)
- [Configuration](#configuration)
  - [Permissions](#permissions)
  - [Hooks](#hooks)
  - [Distribution & Protected Files](#distribution--protected-files)
- [Project Standards Generation](#project-standards-generation)
  - [CLAUDE.md Structure](#claudemd-structure)
  - [Rules Files](#rules-files)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)

---

## Quick Start

### Option A: Plugin Install (Recommended)

```bash
# In Claude Code
/plugin marketplace add moberghr/claude-helpers
/plugin install moberg@moberghr
```

### Option B: Manual Install

```bash
# Clone the toolkit
git clone git@github.com:moberghr/claude-helpers.git

# In Claude Code, from your target repo
/moberg:install --project
```

### Bootstrap Your Repository

```bash
# Generate project-specific CLAUDE.md and .claude/rules/ from your codebase
/moberg:init
```

### Start Building

```bash
# Implement a feature (full workflow: plan -> build -> test -> review)
/moberg:implement Add user notification preferences endpoint

# Quick fix (lightweight: debug -> fix -> verify)
/moberg:fix Fix null reference in PaymentProcessor when amount is zero
```

---

## Architecture

### Design Principles

| Principle | Description |
|-----------|-------------|
| **Evidence over assertion** | No task is complete without cited build output, test counts, and exit codes. "Should work" is never sufficient. |
| **Security as a design constraint** | Security is not a final polish phase. It is embedded in planning, implementation, and review. |
| **Progressive disclosure** | Context is loaded when needed, not all at once. Reference docs load at the phase where they are first relevant. |
| **Anti-rationalization** | Every step an AI might skip has an explicit rebuttal. Skills contain "Common Rationalizations" tables that counter shortcuts. |
| **Commands compose skills** | Commands are thin entry points. Reusable workflow logic lives in skills. This prevents command bloat and enables reuse. |
| **Specialists over generalists** | Review agents are narrow experts (compliance, testing, architecture), not one agent trying to check everything. |

### Component Model

```
                    ┌─────────────────────────────────────────────┐
                    │              MOBERG TOOLKIT                  │
                    └─────────────────────────────────────────────┘
                                        │
              ┌─────────────────────────┼─────────────────────────┐
              │                         │                         │
     ┌────────┴────────┐     ┌─────────┴─────────┐     ┌────────┴────────┐
     │    COMMANDS      │     │      SKILLS        │     │     AGENTS      │
     │  (Entry Points)  │     │ (Reusable Workflow) │     │  (Specialists)  │
     └────────┬────────┘     └─────────┬─────────┘     └────────┬────────┘
              │                         │                         │
  /implement  │   context-engineering   │   compliance-reviewer   │
  /fix        │   spec-driven-dev       │   test-reviewer         │
  /init       │   planning              │   architecture-reviewer │
  /scan       │   incremental-impl      │                         │
  /update     │   TDD                   │                         │
  /doctor     │   debugging             │                         │
  /quick-check│   code-review           │                         │
  /validate   │   security-hardening    │                         │
  /install    │   source-driven-dev     │                         │
  /merge      │   verification          │                         │
              │   simplification        │                         │
              │   brainstorming         │                         │
              │   correction-capture    │                         │
              │   git-worktrees         │                         │
              │   writing-skills        │                         │
              │                         │                         │
     ┌────────┴─────────────────────────┴─────────────────────────┘
     │
     │  ┌─────────────────────────────────────────────────────────┐
     └──│                   REFERENCES                             │
        │  (Shared Standards — loaded progressively by phase)      │
        │                                                          │
        │  coding-guidelines.md    security-checklist.md            │
        │  testing-patterns.md     performance-checklist.md         │
        │  ef-core-checklist.md    mediatr-slice-patterns.md        │
        └─────────────────────────────────────────────────────────┘
```

### How Components Compose

Commands do not contain workflow logic directly. They orchestrate skills:

```
/moberg:implement "Add payment retry endpoint"
  │
  ├── Phase 0: context-engineering          ← Load CLAUDE.md, references, lessons
  ├── Phase 0.5: brainstorming             ← (if approach unclear)
  ├── Phase 1: spec-driven-development     ← Produce executable spec with manifest
  ├── Phase 2: planning-and-task-breakdown ← Write tasks/todo.md with batches
  ├── Phase 3: incremental-implementation  ← Build in verified batches
  │   ├── test-driven-development          ← Failing test → code → pass
  │   ├── source-driven-development        ← Verify SDK/framework behavior
  │   └── security-and-hardening           ← (if scope touches sensitive areas)
  ├── Phase 4: code-review (two-stage)
  │   ├── Stage 1: compliance-reviewer     ← Security, correctness, standards
  │   └── Stage 2: test-reviewer           ← Coverage gaps
  │               architecture-reviewer    ← Boundary violations
  ├── Phase 5: Fix review findings         ← Iterate (max 3 rounds)
  ├── Phase 6: code-simplification         ← Behavior-preserving cleanup
  └── Phase 7: Compound                    ← Capture lessons, update standards
```

---

## Commands

### Primary Commands

#### `implement`

**Full feature implementation workflow.** Use for new endpoints, tables, handlers, or any multi-file work.

```bash
/moberg:implement Add user notification preferences with email and SMS channels
```

Composes 11 skills across 7 phases. Produces an executable spec, implements in verified batches with TDD, runs two-stage adversarial review, and captures lessons for future sessions.

**Flags:**
- `--auto` — Skip approval waits (planning still happens)
- `--terse` — Minimal output for senior engineers who read diffs
- `--verbose` — Full explanations for learning or unfamiliar areas

#### `fix`

**Lightweight bug fix workflow.** Use for 1-3 file changes that don't require feature planning.

```bash
/moberg:fix Fix null reference in PaymentProcessor when amount is zero
```

Composes debugging, targeted TDD, and verification. Has a built-in scope guard: if the change grows beyond 3 files, it tells you to switch to `implement`.

#### `init`

**Bootstrap a repository for AI-assisted development.** Run once per repo.

```bash
/moberg:init
```

Scans the codebase to understand patterns, pulls shared coding guidelines, and generates:
- `CLAUDE.md` (lean, under 200 lines) with project profile and critical rules
- `.claude/rules/*.md` files with detailed, topic-specific standards
- `.claude/references/quick-check-list.md` with project-specific verification items

#### `quick-check`

**Pre-commit security scan.** Fast, focused, run before every commit.

```bash
/moberg:quick-check
```

Checks staged changes against the security checklist: hardcoded secrets, SQL injection, PII in logs, missing auth, audit gaps.

#### `scan`

**Extract architecture principles from a codebase.** Produces a descriptive document of how the team actually builds software.

```bash
/moberg:scan
```

Outputs `.claude/references/architecture-principles.md`. Documents what IS, not what should be. Flags inconsistencies for the team to resolve.

### Lifecycle Commands

| Command | Purpose |
|---------|---------|
| `install` | Install toolkit globally (`~/.claude/`) or locally (`./.claude/`). First-time setup. |
| `update` | Pull latest toolkit version from central repo. Respects protected files. |
| `doctor` | Health check: CLAUDE.md present? References valid? Toolkit version current? |
| `validate` | Validate toolkit structure, manifest metadata, and skill anatomy. For toolkit contributors. |
| `merge` | Unify architecture scans from multiple repos into a single document. |

---

## Skills

Skills are reusable workflow building blocks. Commands compose them; they are not invoked directly by users.

### Core Workflow Skills

| Skill | Trigger | What It Does |
|-------|---------|-------------|
| **context-engineering** | Session start, phase switch, unfamiliar code | Loads project norms progressively; anchors context to CLAUDE.md and references |
| **spec-driven-development-dotnet** | New feature, breaking change, multi-file work | Produces executable spec with change manifest, test manifest, and approval gates |
| **planning-and-task-breakdown** | After spec approval | Writes `tasks/todo.md` with vertical-slice batches and checkpoint criteria |
| **incremental-implementation-dotnet** | Approved multi-file work | Implements in verified batches; triggers early review if cumulative churn exceeds 300 lines |
| **test-driven-development-dotnet** | New behavior, bug fix, public contract change | Red-green-refactor: failing test first, minimal passing code, then improve |
| **debugging-and-error-recovery** | Bug, failing test, runtime error | Reproduce first, then fix root cause within scope, add regression test |
| **source-driven-development** | Unfamiliar SDK/framework behavior | Verify from authoritative sources before implementing; mark confidence levels |

### Quality & Review Skills

| Skill | Trigger | What It Does |
|-------|---------|-------------|
| **code-review-and-quality-fintech** | After implementation, before merge | Adversarial review across correctness, security, architecture, performance, testing |
| **security-and-hardening-fintech** | Auth, secrets, financial state, audit trails, infra | Identifies trust boundaries; verifies auth/authz, PII handling, transaction safety |
| **code-simplification** | After verification passes | Behavior-preserving cleanup: dead code, unnecessary complexity, naming |
| **verification-before-completion** | Before reporting "done" | Requires fresh build output, test counts, and exit codes as cited evidence |

### Meta & Enabling Skills

| Skill | Trigger | What It Does |
|-------|---------|-------------|
| **brainstorming** | Approach unclear, multiple viable designs | Explores 2-3 concrete approaches with tradeoffs; converges on approved direction |
| **correction-capture** | Engineer says "no", "stop", redirects approach | Captures correction as reusable lesson in `tasks/lessons.md`; applies immediately |
| **using-git-worktrees** | Parallel development, experimentation | Safe worktree creation with gitignore and baseline test verification |
| **writing-skills** | Creating new skills for the toolkit | Ensures skill follows anatomy, CSO principle, and passes adversarial pressure tests |

### Skill Anatomy

Every skill follows a standardized structure:

```markdown
---
name: skill-name
description: Condition-based trigger description (not workflow summary)
---

# Skill Title

## Overview          ← What this skill ensures
## When To Use       ← Concrete trigger conditions
## When NOT To Use   ← Prevents misapplication
## Workflow          ← Step-by-step process
## Verification      ← How to confirm the skill was applied correctly
## Common Rationalizations  ← Why agents skip steps + sharp rebuttals
## Red Flags         ← Signs the skill was not followed
```

The **Common Rationalizations** table is a key innovation. It lists the exact excuses an AI will use to skip important steps, paired with rebuttals that counter each one. This is tested against adversarial pressure tests.

---

## Review Agents

### Two-Stage Review Model

Reviews are **sequential, not parallel**. Spec compliance comes first because if the implementation doesn't match the spec, quality review is wasted effort.

```
                    ┌──────────────────────┐
                    │    Implementation     │
                    │    Complete           │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │  STAGE 1:            │
                    │  compliance-reviewer  │
                    │                      │
                    │  Security            │
                    │  Correctness         │
                    │  Standards           │
                    │  Architecture        │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │  Critical issues?    │
                    └──┬───────────────┬───┘
                   Yes │               │ No
                       │               │
              ┌────────▼──┐   ┌────────▼───────────┐
              │  Fix &    │   │  STAGE 2:           │
              │  Re-review│   │  test-reviewer      │
              │  (max 3x) │   │  architecture-      │
              └───────────┘   │  reviewer            │
                              └────────┬───────────┘
                                       │
                              ┌────────▼───────────┐
                              │  Findings?         │
                              └──┬─────────────┬───┘
                             Yes │             │ No
                                 │             │
                        ┌────────▼──┐ ┌────────▼──┐
                        │  Fix &    │ │  PASS     │
                        │  Re-review│ │           │
                        └───────────┘ └───────────┘
```

### compliance-reviewer

**Adversarial senior code reviewer for fintech/investment banking.** Must find at least 2 substantive issues or provide a detailed argument for why the code is genuinely flawless. Style nits alone don't count.

**Checks:** Security & compliance (auth, secrets, audit, PII), architecture (slices, layers, DI), coding style (40+ rules from guidelines), data layer (AsNoTracking, N+1, projections), performance, infrastructure (IAM, VPC, security groups), test coverage, codebase consistency.

**Reads:** `CLAUDE.md`, `.claude/rules/*.md`, all 6 reference documents, security-hardening skill, and 2-3 neighboring files for pattern comparison.

### test-reviewer

**Focused reviewer for test coverage and verification quality.** Checks that new behavior has tests, mutation paths have success/failure cases, assertions are specific, and test providers match the behavior being tested.

### architecture-reviewer

**Focused reviewer for slice boundaries and architectural fit.** Checks dependency direction, handler/controller/service splits, naming consistency, abstraction justification, and cross-layer leaks.

### Agent Self-Escalation

All agents can report `BLOCKED` or `NEEDS_CONTEXT` instead of producing uncertain output. A clear escalation is always more valuable than a low-confidence review.

---

## References

Shared standards documents loaded progressively by commands and agents:

| Reference | Phase Loaded | Content |
|-----------|-------------|---------|
| `coding-guidelines.md` | Phase 0 (always) | Moberg C# style: naming, LINQ conventions, file structure, MediatR patterns |
| `security-checklist.md` | Phase 1 (planning) | Input validation, auth, secrets management, PII, audit trails |
| `testing-patterns.md` | Phase 1 (planning) | Test selection (unit/integration/E2E), EF Core providers, coverage rules |
| `performance-checklist.md` | Phase 3 (implementation) | AsNoTracking, projections, N+1, async/cancellation, HttpClient factory |
| `ef-core-checklist.md` | Phase 3 (implementation) | Query rules, write rules, configuration patterns, review questions |
| `mediatr-slice-patterns.md` | Phase 3 (implementation) | Request/Response/Handler structure, Command/Query suffixes, side effects |

References are loaded at the **phase where they are first needed**, not all upfront. This preserves context budget for the actual code and decisions that matter in each phase.

---

## Workflows

### Feature Implementation Workflow

```
Engineer                    Toolkit                         Repository
   │                           │                               │
   │  /moberg:implement        │                               │
   │  "Add payment retry"      │                               │
   │──────────────────────────>│                               │
   │                           │  Load CLAUDE.md, guidelines   │
   │                           │  Read lessons.md              │
   │                           │──────────────────────────────>│
   │                           │                               │
   │                           │  Scan codebase for patterns   │
   │                           │  Produce executable spec      │
   │  Review spec              │<──────────────────────────────│
   │<──────────────────────────│                               │
   │                           │                               │
   │  "Approved"               │                               │
   │──────────────────────────>│                               │
   │                           │  Write tasks/todo.md          │
   │                           │  Implement batch 1            │
   │                           │  Run tests ──────────────────>│
   │                           │  Implement batch 2            │
   │                           │  Run tests ──────────────────>│
   │                           │  ...                          │
   │                           │  Full dotnet test ───────────>│
   │                           │                               │
   │                           │  Stage 1: compliance-reviewer │
   │                           │  Stage 2: test-reviewer       │
   │                           │           arch-reviewer       │
   │                           │                               │
   │                           │  Fix findings (if any)        │
   │                           │  Re-verify ──────────────────>│
   │                           │                               │
   │                           │  Simplify code                │
   │                           │  Capture lessons              │
   │  Final report             │  Update lessons.md            │
   │<──────────────────────────│──────────────────────────────>│
```

### Bug Fix Workflow

```
Engineer                    Toolkit                         Repository
   │                           │                               │
   │  /moberg:fix              │                               │
   │  "Fix null ref in X"      │                               │
   │──────────────────────────>│                               │
   │                           │  Load context                 │
   │                           │  Reproduce the bug            │
   │                           │  Identify root cause          │
   │                           │  Write failing test ─────────>│
   │                           │  Apply minimal fix            │
   │                           │  Verify test passes ─────────>│
   │                           │  Run full test suite ────────>│
   │  Done + evidence          │                               │
   │<──────────────────────────│                               │
```

### Repository Onboarding Workflow

```
1. Install toolkit          /moberg:install --project
2. Scan architecture        /moberg:scan
3. Bootstrap standards      /moberg:init
4. Review generated files   CLAUDE.md, .claude/rules/*.md, quick-check-list.md
5. First feature            /moberg:implement <description>
6. Keep current             /moberg:update (periodically)
7. Health check             /moberg:doctor (if issues arise)
```

### Toolkit Lifecycle Workflow

```
Central Repo (claude-helpers)          Target Repos
        │                                    │
        │  Contributor adds skill            │
        │  or updates reference              │
        │                                    │
        │  /moberg:validate                  │
        │  (check structure + metadata)      │
        │                                    │
        │  Bump manifest.json version        │
        │  Push to main                      │
        │                                    │
        │              /moberg:update         │
        │<───────────────────────────────────│
        │                                    │
        │  manifest.json controls:           │
        │  - sync: overwrite target          │
        │  - merge: intelligent union        │
        │  - protected: never overwrite      │
        │────────────────────────────────────>│
        │                                    │
        │  Project-specific files preserved: │
        │  - CLAUDE.md                       │
        │  - architecture-principles.md      │
        │  - tasks/lessons.md                │
        │  - .claude/rules/ (generated)      │
```

---

## Configuration

### Permissions

The toolkit ships with a default permission set in `.claude/settings.json`:

**Allowed by default:**
- File operations: `Read`, `Write`, `Edit`, `Glob`, `Grep`
- Build/test: `dotnet build`, `dotnet test`, `dotnet format`
- Git (read): `git diff`, `git status`, `git log`, `git add`
- Shell: `ls`, `find`, `head`, `tail`, `wc`, `curl`, `cat`

**Denied (hard block):**
- `rm -rf` — Destructive file operations
- `git checkout main` — Prevents accidental main branch switches
- `dotnet publish` — Prevents accidental deployments

**Prompted (user decides per-invocation):**
- `git push` — User confirms each push
- `git commit` — User confirms each commit
- Any tool not in the allow list

### Hooks

The toolkit includes three hooks that enforce workflow discipline:

| Hook | Trigger | Purpose |
|------|---------|---------|
| **Auto-format** | After writing/editing `.cs` files | Runs `dotnet format` to enforce style automatically |
| **Verification gap** | When assistant stops | Catches completion claims without cited evidence (build output, test counts) |
| **Task completion** | When a task is marked done | Reminds agent that stale evidence doesn't count for implementation tasks |

### Distribution & Protected Files

The `manifest.json` controls what gets distributed and how:

| Action | Behavior | Used For |
|--------|----------|----------|
| `sync` | Overwrite target file | Commands, skills, agents, references (shared standards) |
| `merge` | Intelligent union of settings | `settings.json` (preserves project-specific tool permissions) |

**Protected files** are never overwritten by `update`:

| File | Why Protected |
|------|---------------|
| `CLAUDE.md` | Project-specific standards generated by `init` |
| `.claude/settings.local.json` | Engineer's personal overrides |
| `tasks/lessons.md` | Team's accumulated learnings |
| `tasks/todo.md` | In-progress work |
| `.claude/references/architecture-principles.md` | Project-specific architecture doc |
| `.claude/references/quick-check-list.md` | Project-specific verification checklist |

---

## Project Standards Generation

When you run `/moberg:init`, the toolkit scans your codebase and generates standards files that follow Claude Code best practices.

### CLAUDE.md Structure

The root `CLAUDE.md` is kept **under 200 lines** for maximum AI adherence. It contains:

| Section | Content |
|---------|---------|
| Command Routing | Which command to use for which task |
| Build & Test | Actual build/test commands for this project |
| Project Profile | Framework, data layer, patterns, hosting, test stack |
| Critical Rules (§0.x) | Top 5-10 highest-impact rules from all categories |
| Standards Reference | Table pointing to `.claude/rules/` files and `.claude/references/` |

### Rules Files

Detailed standards live in `.claude/rules/`, auto-loaded by Claude Code:

| File | Section | Content |
|------|---------|---------|
| `security.md` | §1.x | Auth, secrets, audit trails, PII handling |
| `architecture.md` | §2.x | Layer structure, dependency direction, DI, patterns |
| `coding-style.md` | §3.x | Project-specific style overrides (references `coding-guidelines.md`) |
| `testing.md` | §4.x | Frameworks, naming, coverage, integration patterns |
| `data-layer.md` | §5.x | EF Core patterns, AsNoTracking, projections, connections |
| `performance.md` | §6.x | Async, caching, HttpClient, unbounded collections |
| `infrastructure.md` | §7.x | CDK, Lambda, Docker, AWS services, IAM |
| `git-workflow.md` | §8.x | Branch naming, commit conventions, PR templates |
| `project-specific.md` | §9.x | Patterns unique to the repository |

Rules are numbered (§X.Y) so review agents can cite specific violations in their findings. Only files relevant to the project's technology stack are generated.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `/moberg:implement` says "run /moberg:init first" | Missing `CLAUDE.md` | Run `/moberg:init` to bootstrap |
| Review agent reports `BLOCKED` | Required files inaccessible | Check that `.claude/references/` files exist; run `/moberg:update` |
| `dotnet format` hook fails silently | .NET SDK not on PATH | Ensure `dotnet` is available in your shell profile |
| `/moberg:update` overwrites local changes | File is not in `protected` list | Add it to `protected` array in `manifest.json` |
| Toolkit version mismatch | Stale local copy | Run `/moberg:update` to pull latest |
| Skills not loading | Missing skill files | Run `/moberg:doctor` to diagnose; `/moberg:update` to restore |
| "Verification gap" hook fires frequently | Completion claims without evidence | This is working as intended. Cite build/test output before reporting done. |

Run `/moberg:doctor` for automated health checks covering all common issues.

---

## FAQ

**Q: Do I need to run `/moberg:init` on every branch?**
A: No. Run it once per repository. The generated `CLAUDE.md` and `.claude/rules/` are committed to the repo and shared across branches.

**Q: Can I customize the generated rules?**
A: Yes. After `init` generates the files, edit them freely. The `update` command will never overwrite `CLAUDE.md`, `.claude/rules/`, or `architecture-principles.md` — they are protected.

**Q: Does this work with projects that don't use .NET?**
A: The skills and references are .NET/fintech-focused. The architecture (commands, skills, agents, references) is framework-agnostic and can be adapted. See `docs/skill-anatomy.md` for how to write skills for other stacks.

**Q: How does this differ from just writing a CLAUDE.md manually?**
A: Three key differences: (1) the toolkit generates CLAUDE.md from your actual codebase, not guesswork; (2) it provides workflow enforcement (planning, TDD, review) not just rules; (3) adversarial review agents actively find violations.

**Q: What if the review agent finds a false positive?**
A: Review agents can be wrong. If a finding is incorrect, dismiss it and move on. If the same false positive recurs, add a clarification to the relevant `.claude/rules/` file.

**Q: How do I add a custom skill for my team?**
A: See [Contributing](#contributing) and `docs/skill-anatomy.md`. Create the skill, register it in `manifest.json`, add routing in `AGENTS.md`, and run `/moberg:validate`.

**Q: Can I use this alongside other Claude Code plugins?**
A: Yes. The toolkit's permissions and hooks merge with other plugins' settings. Check for conflicts with `/moberg:doctor`.

---

## Repo Structure

```
claude-helpers/
  .claude/
    commands/              # 11 command entry points
      implement.md         #   Full feature workflow
      fix.md               #   Lightweight bug fix
      init.md              #   Repository bootstrap
      scan.md              #   Architecture extraction
      merge.md             #   Multi-repo scan unification
      install.md           #   Toolkit installation
      update.md            #   Toolkit sync
      validate.md          #   Toolkit validation
      doctor.md            #   Health diagnostics
      quick-check.md       #   Pre-commit security scan
    skills/                # 16 reusable workflow skills
      context-engineering/
      spec-driven-development-dotnet/
      planning-and-task-breakdown/
      incremental-implementation-dotnet/
      test-driven-development-dotnet/
      debugging-and-error-recovery/
      code-review-and-quality-fintech/
      security-and-hardening-fintech/
      source-driven-development/
      code-simplification/
      verification-before-completion/
      brainstorming/
      correction-capture/
      using-git-worktrees/
      writing-skills/
    agents/                # 3 specialist reviewers
      compliance-reviewer.md
      test-reviewer.md
      architecture-reviewer.md
    references/            # 6 shared standards
      coding-guidelines.md
      testing-patterns.md
      security-checklist.md
      performance-checklist.md
      ef-core-checklist.md
      mediatr-slice-patterns.md
    manifest.json          # Distribution registry
    settings.json          # Shared permissions and hooks
  .claude-plugin/          # Plugin marketplace config
    plugin.json
    marketplace.json
  hooks/                   # Session initialization
    hooks.json
    session-start
  docs/
    skill-anatomy.md       # Skill authoring guide
  scripts/
    validate-toolkit.sh    # Structure validation
  tests/
    pressure-tests/        # Adversarial skill tests
      security-hardening-pressure.md
      verification-pressure.md
      code-review-pressure.md
  AGENTS.md                # Routing rules for skills and agents
  CONTRIBUTING.md          # Contribution guidelines
  README.md                # This file
```

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for full guidelines. Summary:

1. **Commands** are entry points. Keep orchestration here, workflow logic in skills.
2. **Skills** follow `docs/skill-anatomy.md`. Include anti-rationalization tables.
3. **Agents** are narrow specialists. Keep tools read-only. Use `model: sonnet`.
4. **References** are durable standards. Register with `"action": "sync"` in manifest.
5. **Every new file** must be registered in `manifest.json` and version bumped.
6. **Run `/moberg:validate`** before pushing. Run `bash scripts/validate-toolkit.sh` for structural checks.

---

## Security

This toolkit is designed for fintech environments where code quality and security are non-negotiable.

**What the toolkit enforces:**
- No hardcoded secrets, connection strings, or API keys
- Parameterized queries only (SQL injection prevention)
- No PII in logs, errors, or exception messages
- Audit trails for financial state changes (in the same transaction)
- Authentication on every endpoint; RBAC at service layer
- Least-privilege IAM and infrastructure permissions
- Input validation at API boundaries

**What the toolkit does NOT do:**
- Access production systems or databases
- Store or transmit secrets
- Make network requests beyond fetching coding guidelines from GitHub
- Modify files outside the working directory

**Reporting security issues:** If you discover a security vulnerability in the toolkit itself, contact the maintainers directly. Do not open a public issue.

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

<div align="center">

**Moberg Toolkit** v4.1.0 | [Moberg d.o.o.](https://www.moberg.hr) | Built for teams that ship production code, not prototypes.

</div>
