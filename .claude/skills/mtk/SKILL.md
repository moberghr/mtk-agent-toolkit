---
name: mtk
description: Unified entry point that routes natural language requests to the right MTK skill
type: skill
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, Task, AskUserQuestion
argument-hint: <what you want to do>
---

# MTK — Unified Entry Point

You are a router. Classify the user's intent from their input, then load and follow the matching workflow skill inline. Do NOT do the work yourself — delegate by reading the target skill and following it end-to-end.

## Route Table

Match the user's input against these patterns. Check from top to bottom; first match wins.

| Pattern (keywords / intent) | Route to | Example inputs |
|---|---|---|
| `escalated from fix` (internal marker from fix Scope Guard) | `.claude/skills/implement/SKILL.md` | — internal self-escalation only |
| `review`, `check`, `commit`, `staged`, `pre-commit`, `before I commit` | `.claude/skills/pre-commit-review/SKILL.md` | "review before commit", "check staged changes" |
| `health`, `usage`, `stats`, `analytics`, `adoption` | `.claude/skills/toolkit-health/SKILL.md` | "toolkit health", "show usage stats" |
| `fix`, `bug`, `broken`, `error`, `typo`, `patch`, `wrong`, `failing` | `.claude/skills/fix/SKILL.md` | "fix the null check", "this test is broken" |
| `add`, `create`, `build`, `feature`, `implement`, `new`, `endpoint`, `refactor` (multi-file) | `.claude/skills/implement/SKILL.md` | "add user auth", "create a payment endpoint" |
| `status`, `report`, `what's loaded`, `diagnostic`, `context` | `.claude/skills/context-report/SKILL.md` | "what's loaded?", "show toolkit status" |
| `setup`, `bootstrap`, `init`, `initialize`, `first time`, `prepare repo`, `audit`, `architecture`, `principles` | `/mtk-setup` (direct the user) | "set up this repo", "audit this repo" |
| `help`, `commands`, `what can you do` | (print help below) | "help", "what commands are there?" |

## Routing Rules

1. **Strip flags first.** If the input starts with `--terse`, `--verbose`, `--staged-only`, `--preview`, `--merge`, `--non-interactive`, pass them through to the target skill.
2. **Unambiguous → route silently.** If the input matches exactly one row of the table, invoke immediately — no confirmation question.
3. **Escalation marker → implement.** If the input literally contains `escalated from fix`, route straight to `implement` (produced only by the `fix` Scope Guard).
4. **Ambiguous → ask, but only if genuinely ambiguous.** If input matches two rows with similar specificity (e.g., "fix the auth feature" — fix verb + feature-sized noun), ask one clarifying question: "Is this a small fix (1-3 files) or a larger feature?" Do not ask for inputs that clearly match one row.
5. **No input → help.** If invoked with no argument, print the help text.
6. **Pass description through.** When loading the target skill, treat the user's original description as the task input — don't summarize or rephrase.
7. **Setup requests → redirect.** If the user asks for setup/bootstrap/audit, tell them to run `/mtk-setup` directly (with appropriate flags) rather than routing through mtk.

## Help Output

When the user asks for help or provides no input, respond with:

```
MTK — two entry points:

  /mtk-setup                     → first-time setup (bootstrap + audit)
  /mtk-setup --audit             → re-run architecture audit
  /mtk-setup --merge             → merge multi-repo audits

  /mtk <description>             → everything else:
    /mtk review before commit      → pre-commit security review
    /mtk fix <description>         → small fix (1-3 files)
    /mtk <feature description>     → full implementation workflow
    /mtk status                    → show what's loaded

Update: MTK is distributed as a Claude Code plugin — use the plugin
manager to update rather than an in-repo update skill.
```

## Execution

Once matched, read the target skill file and follow every step of that workflow. Do not summarize; do not skip verification. The target skill owns its own acceptance criteria.

If the route is `/mtk-setup` (setup family), tell the user:

> "Setup lives at `/mtk-setup` — run that directly. Flags: `--audit` re-audits only, `--merge` unifies multi-repo audits, `--preview` shows planned changes, `--non-interactive` skips interview."

Do not add preamble or commentary before routing. Just route.
