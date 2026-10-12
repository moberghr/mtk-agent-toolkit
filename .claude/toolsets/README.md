# Toolsets (S2.19)

Named bundles of tools that skills can require or forbid. Inspired by HolmesGPT runbook-scoped toolsets: narrow the agent's tool surface to the task class, not the repo.

## Schema

```yaml
name: <toolset-name>              # must match filename: <name>.yaml
description: <one sentence>
extends: <parent-toolset>         # optional; inherits parent tools
tools:
  - <ClaudeCode tool spec>        # e.g. Read, Edit, Bash(git diff:*)
```

## Usage in a skill

```yaml
---
name: my-review-skill
required-toolsets: [read-only]    # expanded by /mtk router into allowed-tools
forbidden-toolsets: [code-edit]   # explicit deny; stronger signal than omission
---
```

When `/mtk` (or any orchestrator) dispatches the skill, it resolves the declared toolsets via `scripts/resolve-toolsets.sh <name>` and injects the merged tool list as `allowed-tools`. Existing explicit `allowed-tools` in a skill take precedence (no surprise widening).

## Built-in toolsets

| Toolset | Purpose | Extends |
|---|---|---|
| `read-only` | Review, audit, drift detection | — |
| `git-safe` | Stage/unstage, read stash — no push/reset | `read-only` |
| `code-edit` | Implementation: edit files, run build/test | `git-safe` |

## Why this exists

In a regulated context, a compliance-review run should **not** have `git push` or `dotnet run` in scope. The toolset is the contract. Static agents (`.claude/agents/*.md`) already declare `allowed-tools:` directly — toolsets are for dynamic dispatch from workflow skills where scope varies by invocation.

## Rules

- Toolset name in YAML must match filename (minus `.yaml`).
- `extends:` forms a DAG — no cycles. Validator catches this.
- A skill's `forbidden-toolsets` wins over `required-toolsets` on any overlap.
