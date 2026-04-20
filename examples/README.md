# MTK Examples

Real-world `CLAUDE.md` templates produced by `/mtk-setup` and lightly hand-edited. Use these as a reference for what your repo's `CLAUDE.md` should look like after bootstrap — or copy-paste a matching stack to get started without running setup.

| Template | Stack | Domain |
|:---|:---|:---|
| [`dotnet-akka-cluster-CLAUDE.md`](dotnet-akka-cluster-CLAUDE.md) | .NET 8 · Akka.NET · EF Core · MediatR | Distributed systems / fintech |
| [`python-fastapi-CLAUDE.md`](python-fastapi-CLAUDE.md) | Python 3.12 · FastAPI · SQLAlchemy 2.0 · Pydantic v2 | API services |
| [`typescript-nextjs-CLAUDE.md`](typescript-nextjs-CLAUDE.md) | TypeScript 5 · Next.js 15 · Prisma · tRPC | Full-stack web |
| [`user-level-CLAUDE.md`](user-level-CLAUDE.md) | Global overrides at `~/.claude/CLAUDE.md` | Personal preferences layered across all projects |

## How to use

**Option A — let `/mtk-setup` generate it.** Run `/mtk-setup` in a fresh repo. It detects your stack, audits your architecture, and produces a `CLAUDE.md` sized to your codebase. The files here show what that output typically looks like after one sprint of real use.

**Option B — copy-paste a template.** Pick the closest match, drop it into your repo root as `CLAUDE.md`, then adjust the Project Profile and Critical Rules to fit. Run `bash scripts/validate-toolkit.sh` to confirm it stays under the 200-line budget.

**Either way.** Never overwrite `CLAUDE.md` during plugin updates — it's in the manifest's `protected` list. Your edits survive upgrades.

## Structure

Every template follows the same shape so skills can reliably extract context:

1. **Skill Routing** — which entry point does what
2. **Build & Test** — the exact commands for this stack
3. **Project Profile** — stack, languages, test approach, audience
4. **Critical Rules** — stack-specific rules cited by reviewers as C0.x
5. **Standards Reference** — pointers to `.claude/rules/` and `.claude/references/`

Keep each section tight. MTK enforces a 200-line budget on `CLAUDE.md` — detail belongs in `.claude/rules/` or `.claude/references/`.
