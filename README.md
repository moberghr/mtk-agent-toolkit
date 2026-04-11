<div align="center">

# Moberg Toolkit

### AI-Assisted Development Framework for .NET Fintech Teams

**Enforce coding standards, security compliance, and architectural consistency across every AI-generated line of code.**

[![Version](https://img.shields.io/badge/version-4.2.0-blue.svg)](https://github.com/moberghr/claude-helpers/releases)
[![Platform](https://img.shields.io/badge/platform-Claude%20Code-purple.svg)](https://claude.ai/code)
[![.NET](https://img.shields.io/badge/.NET-8.0%2B-512BD4.svg)](https://dotnet.microsoft.com/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[Quick Start](#-quick-start) · [Architecture](#-architecture) · [Commands](#-commands) · [Skills](#-skills) · [Review Agents](#-review-agents) · [Workflows](#-workflows) · [FAQ](#-faq) · [Contributing](#-contributing)

</div>

---

## Why This Exists

AI code assistants are powerful but unpredictable. Without guardrails, they produce code that compiles but violates your team's standards — wrong patterns, missing tests, security gaps, inconsistent style. In fintech, where every line of code touches money, compliance, or customer data, *"it works"* is not enough.

The Moberg Toolkit solves this by embedding your engineering standards directly into the AI workflow. Every feature goes through planning, implementation, verification, and adversarial review — all guided by your team's actual patterns and rules.

**What it enforces** | **What it does NOT do**
---|---
Coding standards are checked, not suggested | Replace human judgment on architecture
Security and compliance rules embedded in every phase | Auto-merge or auto-deploy anything
Tests required before code is considered complete | Work outside of Claude Code
Review agents find real problems, not style nits | Access production systems or databases
Evidence of passing builds required before "done" | Store or transmit secrets

---

## 🚀 Quick Start

### Option A: Plugin Install (Recommended)

```bash
# In Claude Code
/plugin marketplace add moberghr/claude-helpers
/plugin install moberg@moberghr
```

### Option B: Manual Install

```bash
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
# Implement a feature (full workflow: plan → build → test → review)
/moberg:implement Add user notification preferences endpoint

# Quick fix (lightweight: debug → fix → verify)
/moberg:fix Fix null reference in PaymentProcessor when amount is zero
```

---

## 🏗 Architecture

### Design Principles

| Principle | Description |
|:---|:---|
| **Evidence over assertion** | No task is complete without cited build output, test counts, and exit codes |
| **Security as a design constraint** | Embedded in planning, implementation, and review — not a final polish phase |
| **Progressive disclosure** | Context loaded when needed, not all at once |
| **Anti-rationalization** | Every step an AI might skip has an explicit rebuttal in a "Common Rationalizations" table |
| **Commands compose skills** | Commands are thin entry points; reusable workflow logic lives in skills |
| **Specialists over generalists** | Review agents are narrow experts, not one agent trying to check everything |

### Component Model

```mermaid
graph TB
    subgraph Toolkit["MOBERG TOOLKIT"]
        direction TB

        subgraph Commands["Commands — Entry Points"]
            implement["/implement"]
            fix["/fix"]
            init["/init"]
            scan["/scan"]
            quickcheck["/quick-check"]
            install["/install"]
            update["/update"]
            doctor["/doctor"]
            validate["/validate"]
            merge["/merge"]
            handoff["/handoff"]
        end

        subgraph Skills["Skills — Reusable Workflow"]
            ctx["context-engineering"]
            spec["spec-driven-dev"]
            plan["planning"]
            impl["incremental-impl"]
            tdd["TDD"]
            debug["debugging"]
            review["code-review"]
            sec["security-hardening"]
            src["source-driven-dev"]
            verify["verification"]
            simplify["simplification"]
            brain["brainstorming"]
            corr["correction-capture"]
            wt["git-worktrees"]
            ws["writing-skills"]
        end

        subgraph Agents["Agents — Specialist Reviewers"]
            cr["compliance-reviewer"]
            tr["test-reviewer"]
            ar["architecture-reviewer"]
        end

        subgraph References["References — Shared Standards"]
            cg["coding-guidelines"]
            sc["security-checklist"]
            tp["testing-patterns"]
            pc["performance-checklist"]
            ef["ef-core-checklist"]
            ms["mediatr-slice-patterns"]
        end
    end

    Commands --> Skills
    Commands --> Agents
    Skills --> References
    Agents --> References
```

### How Components Compose

Commands do not contain workflow logic directly. They orchestrate skills:

```mermaid
graph LR
    CMD["/moberg:implement<br/>Add payment retry endpoint"] --> P0

    subgraph Phases
        direction TB
        P0["Phase 0<br/>context-engineering"] --> P0b
        P0b["Phase 0.5<br/>brainstorming<br/><i>if approach unclear</i>"] --> P1
        P1["Phase 1<br/>spec-driven-development"] --> P2
        P2["Phase 2<br/>planning-and-task-breakdown"] --> P3
        P3["Phase 3<br/>incremental-implementation<br/>+ TDD + source-driven-dev<br/>+ security-hardening"] --> P4
        P4["Phase 4<br/>code-review (two-stage)"] --> P5
        P5["Phase 5<br/>fix review findings<br/><i>max 3 rounds</i>"] --> P6
        P6["Phase 6<br/>code-simplification"] --> P7
        P7["Phase 7<br/>capture lessons"]
    end
```

---

## 🎮 Commands

### Primary Commands

| Command | Purpose | Scope |
|:---|:---|:---|
| **`/moberg:implement`** | Full feature implementation workflow | Multi-file features, new endpoints, handlers |
| **`/moberg:fix`** | Lightweight bug fix workflow | 1–3 file changes, focused debugging |
| **`/moberg:init`** | Bootstrap repo for AI-assisted dev | Run once per repository |
| **`/moberg:quick-check`** | Pre-commit security scan | Staged changes only |
| **`/moberg:scan`** | Extract architecture principles | Outputs descriptive doc of team patterns |

#### implement

Composes 11 skills across 7 phases. Produces an executable spec, implements in verified batches with TDD, runs two-stage adversarial review, and captures lessons for future sessions.

```bash
/moberg:implement Add user notification preferences with email and SMS channels
```

**Flags:** `--auto` (skip approval waits) · `--terse` (minimal output) · `--verbose` (full explanations)

#### fix

Composes debugging, targeted TDD, and verification. Has a built-in scope guard — if the change grows beyond 3 files, it tells you to switch to `implement`.

```bash
/moberg:fix Fix null reference in PaymentProcessor when amount is zero
```

#### init

Scans the codebase, pulls shared coding guidelines, and generates a lean `CLAUDE.md` (under 200 lines), `.claude/rules/*.md` files, and a project-specific quick-check list.

```bash
/moberg:init
```

#### quick-check

Checks staged changes against the security checklist: hardcoded secrets, SQL injection, PII in logs, missing auth, audit gaps.

```bash
/moberg:quick-check
```

#### scan

Documents what IS, not what should be. Outputs `.claude/references/architecture-principles.md` and flags inconsistencies for the team to resolve.

```bash
/moberg:scan
```

### Lifecycle Commands

| Command | Purpose |
|:---|:---|
| **`install`** | Install toolkit globally (`~/.claude/`) or locally (`./.claude/`). First-time setup |
| **`update`** | Pull latest toolkit version from central repo. Respects protected files |
| **`doctor`** | Health check: CLAUDE.md present? References valid? Toolkit version current? |
| **`validate`** | Validate toolkit structure, manifest metadata, and skill anatomy |
| **`merge`** | Unify architecture scans from multiple repos into a single document |
| **`handoff`** | Capture session state for context continuity across sessions |

---

## 🧩 Skills

Skills are reusable workflow building blocks. Commands compose them; they are not invoked directly by users.

### Core Workflow

| Skill | Trigger | What It Does |
|:---|:---|:---|
| **context-engineering** | Session start, phase switch, unfamiliar code | Loads project norms progressively; anchors to CLAUDE.md |
| **spec-driven-development** | New feature, breaking change, multi-file work | Produces executable spec with change manifest and approval gates |
| **planning-and-task-breakdown** | After spec approval | Writes vertical-slice batches with checkpoint criteria |
| **incremental-implementation** | Approved multi-file work | Implements in verified batches; early review if churn > 300 lines |
| **test-driven-development** | New behavior, bug fix, public contract change | Red → green → refactor cycle |
| **debugging-and-error-recovery** | Bug, failing test, runtime error | Reproduce first, then fix root cause within scope |
| **source-driven-development** | Unfamiliar SDK/framework behavior | Verify from authoritative sources before implementing |

### Quality & Review

| Skill | Trigger | What It Does |
|:---|:---|:---|
| **code-review-and-quality** | After implementation, before merge | Adversarial review: correctness, security, architecture, performance |
| **security-and-hardening** | Auth, secrets, financial state, audit trails | Identifies trust boundaries; verifies transaction safety |
| **code-simplification** | After verification passes | Behavior-preserving cleanup: dead code, complexity, naming |
| **verification-before-completion** | Before reporting "done" | Requires fresh build output, test counts, and exit codes as evidence |

### Meta & Enabling

| Skill | Trigger | What It Does |
|:---|:---|:---|
| **brainstorming** | Approach unclear, multiple viable designs | Explores 2–3 approaches with tradeoffs; converges on direction |
| **correction-capture** | Engineer says "no" or redirects approach | Captures correction as reusable lesson; applies immediately |
| **using-git-worktrees** | Parallel development, experimentation | Safe worktree creation with gitignore and baseline verification |
| **writing-skills** | Creating new toolkit skills | Ensures anatomy, CSO principle, and adversarial pressure tests |

### Skill Anatomy

Every skill follows a standardized structure:

```
┌─────────────────────────────────────────┐
│  --- frontmatter ---                    │
│  name · description · type              │
├─────────────────────────────────────────┤
│  ## Overview           What it ensures  │
│  ## When To Use        Trigger conds    │
│  ## When NOT To Use    Prevents misuse  │
│  ## Workflow            Step-by-step    │
│  ## Verification       Confirm applied  │
│  ## Common Rationalizations             │
│     ↳ Why agents skip + sharp rebuttals │
│  ## Red Flags          Signs of drift   │
└─────────────────────────────────────────┘
```

The **Common Rationalizations** table lists the exact excuses an AI will use to skip important steps, paired with rebuttals that counter each one. See [docs/skill-anatomy.md](docs/skill-anatomy.md) for the full authoring guide.

---

## 🔍 Review Agents

### Two-Stage Review Model

Reviews are **sequential, not parallel**. Spec compliance comes first — if the implementation doesn't match the spec, quality review is wasted effort.

```mermaid
flowchart TD
    DONE["Implementation<br/>Complete"] --> S1

    S1["Stage 1<br/><b>compliance-reviewer</b><br/>Security · Correctness · Standards"]
    S1 --> CHECK1{Critical<br/>issues?}

    CHECK1 -- Yes --> FIX1["Fix & Re-review<br/><i>max 3 rounds</i>"]
    FIX1 --> S1

    CHECK1 -- No --> S2["Stage 2<br/><b>test-reviewer</b> + <b>architecture-reviewer</b><br/>Coverage gaps · Boundary violations"]
    S2 --> CHECK2{Findings?}

    CHECK2 -- Yes --> FIX2["Fix & Re-review"]
    FIX2 --> S2

    CHECK2 -- No --> PASS["✓ PASS"]
```

### compliance-reviewer

**Adversarial senior code reviewer for fintech/investment banking.** Must find at least 2 substantive issues or provide a detailed argument for why the code is genuinely flawless. Style nits alone don't count.

**Checks:** Security & compliance (auth, secrets, audit, PII) · Architecture (slices, layers, DI) · Coding style (40+ rules) · Data layer (AsNoTracking, N+1, projections) · Performance · Infrastructure (IAM, VPC, security groups) · Test coverage · Codebase consistency

### test-reviewer

**Focused reviewer for test coverage and verification quality.** Checks that new behavior has tests, mutation paths have success/failure cases, assertions are specific, and test data providers match the behavior under test.

### architecture-reviewer

**Focused reviewer for slice boundaries and architectural fit.** Checks dependency direction, handler/controller/service splits, naming consistency, abstraction justification, and cross-layer leaks.

### Agent Self-Escalation

All agents can report `BLOCKED` or `NEEDS_CONTEXT` instead of producing uncertain output. A clear escalation is always more valuable than a low-confidence review.

---

## 📚 References

Shared standards documents, loaded progressively by phase — not all upfront:

```mermaid
graph LR
    subgraph Always
        CG["coding-guidelines"]
    end
    subgraph Planning
        SC["security-checklist"]
        TP["testing-patterns"]
    end
    subgraph Implementation
        PC["performance-checklist"]
        EF["ef-core-checklist"]
        MS["mediatr-slice-patterns"]
    end
    subgraph Review
        QC["quick-check-list"]
    end

    Always --> Planning --> Implementation --> Review
```

| Reference | Phase | Content |
|:---|:---|:---|
| `coding-guidelines.md` | Always | Moberg C# style: naming, LINQ, file structure, MediatR patterns |
| `security-checklist.md` | Planning | Input validation, auth, secrets, PII, audit trails |
| `testing-patterns.md` | Planning | Test selection, EF Core providers, coverage rules |
| `performance-checklist.md` | Implementation | AsNoTracking, projections, N+1, async, HttpClient factory |
| `ef-core-checklist.md` | Implementation | Query rules, write rules, configuration patterns |
| `mediatr-slice-patterns.md` | Implementation | Request/Response/Handler, Command/Query, side effects |

---

## 🔄 Workflows

### Feature Implementation

```mermaid
sequenceDiagram
    participant E as Engineer
    participant T as Toolkit
    participant R as Repository

    E->>T: /moberg:implement "Add payment retry"
    T->>R: Load CLAUDE.md, guidelines, lessons
    T->>R: Scan codebase for patterns
    T-->>E: Executable spec for review

    E->>T: "Approved"
    T->>R: Write tasks/todo.md
    loop Verified Batches
        T->>R: Implement batch N
        T->>R: Run tests
    end
    T->>R: Full dotnet test

    Note over T: Stage 1: compliance-reviewer
    Note over T: Stage 2: test-reviewer + arch-reviewer

    opt Findings
        T->>R: Fix & re-verify
    end

    T->>R: Simplify code
    T->>R: Capture lessons
    T-->>E: Final report with evidence
```

### Bug Fix

```mermaid
sequenceDiagram
    participant E as Engineer
    participant T as Toolkit
    participant R as Repository

    E->>T: /moberg:fix "Fix null ref in X"
    T->>R: Load context
    T->>R: Reproduce the bug
    T->>T: Identify root cause
    T->>R: Write failing test
    T->>R: Apply minimal fix
    T->>R: Verify test passes
    T->>R: Run full test suite
    T-->>E: Done + evidence
```

### Repository Onboarding

```mermaid
graph LR
    A["1. Install<br/>/moberg:install --project"] --> B["2. Scan<br/>/moberg:scan"]
    B --> C["3. Bootstrap<br/>/moberg:init"]
    C --> D["4. Review<br/>CLAUDE.md + rules"]
    D --> E["5. First feature<br/>/moberg:implement"]
    E --> F["6. Stay current<br/>/moberg:update"]
    F --> G["7. Troubleshoot<br/>/moberg:doctor"]
```

### Toolkit Lifecycle

```mermaid
sequenceDiagram
    participant C as Central Repo<br/>(claude-helpers)
    participant T as Target Repos

    Note over C: Contributor adds skill<br/>or updates reference
    C->>C: /moberg:validate
    C->>C: Bump manifest + plugin version
    C->>C: Push to main + tag

    T->>C: /moberg:update
    Note over C,T: manifest.json controls distribution

    C->>T: sync → overwrite target
    C->>T: merge → intelligent union
    Note over T: Protected files preserved:<br/>CLAUDE.md, architecture-principles,<br/>lessons.md, settings.local.json
```

---

## ⚙ Configuration

### Permissions

The toolkit ships with a default permission set in `.claude/settings.json`:

| Category | Policy | Examples |
|:---|:---|:---|
| **Allowed** | Auto-approved | `Read`, `Write`, `Edit`, `dotnet build`, `dotnet test`, `git diff`, `git status` |
| **Denied** | Hard blocked | `rm -rf`, `git checkout main`, `dotnet publish` |
| **Prompted** | User decides each time | `git push`, `git commit`, any unlisted tool |

### Hooks

| Hook | Trigger | Purpose |
|:---|:---|:---|
| **Auto-format** | After writing/editing `.cs` files | Runs `dotnet format` to enforce style |
| **Verification gap** | When assistant stops | Catches completion claims without cited evidence |
| **Task completion** | When a task is marked done | Reminds agent that stale evidence doesn't count |

### Distribution & Protected Files

The `manifest.json` controls what gets distributed and how:

| Action | Behavior | Used For |
|:---|:---|:---|
| `sync` | Overwrite target file | Commands, skills, agents, references |
| `merge` | Intelligent union of settings | `settings.json` (preserves project-specific permissions) |

**Protected files** — never overwritten by `update`:

| File | Why Protected |
|:---|:---|
| `CLAUDE.md` | Project-specific standards generated by `init` |
| `.claude/settings.local.json` | Engineer's personal overrides |
| `tasks/lessons.md` | Team's accumulated learnings |
| `tasks/todo.md` | In-progress work |
| `architecture-principles.md` | Project-specific architecture doc |
| `quick-check-list.md` | Project-specific verification checklist |

---

## 📐 Project Standards Generation

When you run `/moberg:init`, the toolkit scans your codebase and generates standards that follow Claude Code best practices.

### CLAUDE.md Structure

The root `CLAUDE.md` is kept **under 200 lines** for maximum AI adherence:

| Section | Content |
|:---|:---|
| Command Routing | Which command for which task |
| Build & Test | Actual build/test commands for this project |
| Project Profile | Framework, data layer, patterns, hosting, test stack |
| Critical Rules (§0.x) | Top 5–10 highest-impact rules |
| Standards Reference | Pointers to `.claude/rules/` and `.claude/references/` |

### Rules Files

Detailed standards live in `.claude/rules/`, auto-loaded by Claude Code:

| File | Section | Content |
|:---|:---|:---|
| `security.md` | §1.x | Auth, secrets, audit trails, PII handling |
| `architecture.md` | §2.x | Layer structure, dependency direction, DI |
| `coding-style.md` | §3.x | Style overrides (references `coding-guidelines.md`) |
| `testing.md` | §4.x | Frameworks, naming, coverage, integration |
| `data-layer.md` | §5.x | EF Core patterns, AsNoTracking, projections |
| `performance.md` | §6.x | Async, caching, HttpClient, collections |
| `infrastructure.md` | §7.x | CDK, Lambda, Docker, AWS, IAM |
| `git-workflow.md` | §8.x | Branch naming, commit conventions, PRs |
| `project-specific.md` | §9.x | Patterns unique to the repository |

Rules are numbered (§X.Y) so review agents can cite specific violations.

---

## 🗂 Repo Structure

```
claude-helpers/
├── .claude/
│   ├── commands/              # 11 command entry points
│   │   ├── implement.md       #   Full feature workflow
│   │   ├── fix.md             #   Lightweight bug fix
│   │   ├── init.md            #   Repository bootstrap
│   │   ├── scan.md            #   Architecture extraction
│   │   ├── merge.md           #   Multi-repo scan unification
│   │   ├── install.md         #   Toolkit installation
│   │   ├── update.md          #   Toolkit sync
│   │   ├── validate.md        #   Toolkit validation
│   │   ├── doctor.md          #   Health diagnostics
│   │   ├── quick-check.md     #   Pre-commit security scan
│   │   └── handoff.md         #   Session state capture
│   ├── skills/                # 16 reusable workflow skills
│   │   ├── context-engineering/
│   │   ├── spec-driven-development-dotnet/
│   │   ├── planning-and-task-breakdown/
│   │   ├── incremental-implementation-dotnet/
│   │   ├── test-driven-development-dotnet/
│   │   ├── debugging-and-error-recovery/
│   │   ├── code-review-and-quality-fintech/
│   │   ├── security-and-hardening-fintech/
│   │   ├── source-driven-development/
│   │   ├── code-simplification/
│   │   ├── verification-before-completion/
│   │   ├── brainstorming/
│   │   ├── correction-capture/
│   │   ├── using-git-worktrees/
│   │   └── writing-skills/
│   ├── agents/                # 3 specialist reviewers
│   │   ├── compliance-reviewer.md
│   │   ├── test-reviewer.md
│   │   └── architecture-reviewer.md
│   ├── references/            # 6 shared standards
│   │   ├── coding-guidelines.md
│   │   ├── testing-patterns.md
│   │   ├── security-checklist.md
│   │   ├── performance-checklist.md
│   │   ├── ef-core-checklist.md
│   │   └── mediatr-slice-patterns.md
│   ├── manifest.json          # Distribution registry
│   └── settings.json          # Shared permissions & hooks
├── .claude-plugin/            # Plugin marketplace config
│   └── plugin.json
├── hooks/                     # Session initialization
│   ├── hooks.json
│   └── session-start
├── docs/
│   └── skill-anatomy.md       # Skill authoring guide
├── scripts/
│   └── validate-toolkit.sh    # Structure validation
├── tests/
│   └── pressure-tests/        # Adversarial skill tests
├── AGENTS.md                  # Routing rules
├── CONTRIBUTING.md            # Contribution guidelines
└── README.md                  # This file
```

---

## 🔧 Troubleshooting

| Symptom | Cause | Fix |
|:---|:---|:---|
| `implement` says "run init first" | Missing `CLAUDE.md` | Run `/moberg:init` |
| Review agent reports `BLOCKED` | Required files inaccessible | Check `.claude/references/`; run `/moberg:update` |
| `dotnet format` hook fails silently | .NET SDK not on PATH | Ensure `dotnet` is in your shell profile |
| `update` overwrites local changes | File not in `protected` list | Add to `protected` in `manifest.json` |
| Toolkit version mismatch | Stale local copy | Run `/moberg:update` |
| Skills not loading | Missing skill files | Run `/moberg:doctor` then `/moberg:update` |
| "Verification gap" fires often | Claims without evidence | Working as intended — cite build/test output |

Run **`/moberg:doctor`** for automated health checks covering all common issues.

---

## ❓ FAQ

<details>
<summary><b>Do I need to run <code>/moberg:init</code> on every branch?</b></summary>

No. Run it once per repository. The generated `CLAUDE.md` and `.claude/rules/` are committed and shared across branches.
</details>

<details>
<summary><b>Can I customize the generated rules?</b></summary>

Yes. After `init` generates the files, edit them freely. `update` will never overwrite `CLAUDE.md`, `.claude/rules/`, or `architecture-principles.md` — they are protected.
</details>

<details>
<summary><b>Does this work with non-.NET projects?</b></summary>

The skills and references are .NET/fintech-focused. The architecture (commands, skills, agents, references) is framework-agnostic and can be adapted. See [docs/skill-anatomy.md](docs/skill-anatomy.md) for writing skills for other stacks.
</details>

<details>
<summary><b>How does this differ from writing a CLAUDE.md manually?</b></summary>

Three key differences: (1) the toolkit generates CLAUDE.md from your actual codebase, not guesswork; (2) it provides workflow enforcement (planning, TDD, review), not just rules; (3) adversarial review agents actively find violations.
</details>

<details>
<summary><b>What if the review agent finds a false positive?</b></summary>

Review agents can be wrong. Dismiss incorrect findings and move on. If the same false positive recurs, add a clarification to the relevant `.claude/rules/` file.
</details>

<details>
<summary><b>How do I add a custom skill?</b></summary>

See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/skill-anatomy.md](docs/skill-anatomy.md). Create the skill, register in `manifest.json`, add routing in `AGENTS.md`, and run `/moberg:validate`.
</details>

<details>
<summary><b>Can I use this alongside other Claude Code plugins?</b></summary>

Yes. The toolkit's permissions and hooks merge with other plugins' settings. Check for conflicts with `/moberg:doctor`.
</details>

---

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guide. The short version:

1. **Commands** are entry points — keep orchestration here, workflow logic in skills
2. **Skills** follow [docs/skill-anatomy.md](docs/skill-anatomy.md) — include anti-rationalization tables
3. **Agents** are narrow specialists — keep tools read-only, use `model: sonnet`
4. **References** are durable standards — register with `"action": "sync"` in manifest
5. **Every new file** must be in `manifest.json` with a version bump
6. **Run `/moberg:validate`** before pushing

---

## 🔒 Security

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
- Make network requests beyond fetching guidelines from GitHub
- Modify files outside the working directory

**Reporting security issues:** Contact the maintainers directly. Do not open a public issue.

---

## 📄 License

MIT License. See [LICENSE](LICENSE) for details.

---

<div align="center">

**Moberg Toolkit** v4.2.0 · [Moberg d.o.o.](https://www.moberg.hr) · Built for teams that ship production code, not prototypes.

</div>
