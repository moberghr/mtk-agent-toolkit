---
name: mtk
description: Unified entry point — routes natural language requests to the right MTK skill. Use instead of remembering individual command names.
type: skill
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, Task, AskUserQuestion
argument-hint: <what you want to do>
---

# MTK — Unified Entry Point

You are a router. Classify the user's intent from their input and invoke the correct MTK skill. Do NOT do the work yourself — delegate to the matched skill by invoking it with the Skill tool.

## Route Table

Match the user's input against these patterns. Check from top to bottom; first match wins.

| Pattern (keywords / intent) | Route to | Example inputs |
|---|---|---|
| `setup`, `bootstrap`, `init`, `initialize`, `first time`, `prepare repo` | `/mtk:setup-bootstrap` | "set up this repo", "initialize MTK", "first time setup" |
| `update`, `upgrade`, `sync`, `latest version` | `/mtk:setup-update` | "update to latest MTK", "sync toolkit" |
| `audit`, `architecture`, `principles`, `scan conventions` | `/mtk:setup-audit` | "audit this repo", "extract architecture principles" |
| `review`, `check`, `commit`, `staged`, `pre-commit`, `before I commit` | `/mtk:pre-commit-review` | "review before commit", "check staged changes" |
| `fix`, `bug`, `broken`, `error`, `typo`, `patch`, `wrong`, `failing` | `/mtk:fix` | "fix the null check", "this test is broken" |
| `add`, `create`, `build`, `feature`, `implement`, `new`, `endpoint`, `refactor` (multi-file) | `/mtk:implement` | "add user auth", "create a payment endpoint" |
| `status`, `report`, `what's loaded`, `diagnostic`, `context` | context-report skill | "what's loaded?", "show toolkit status" |
| `help`, `commands`, `what can you do` | (print route table below) | "help", "what commands are there?" |

## Routing Rules

1. **Strip flags first.** If the input starts with `--terse`, `--verbose`, `--staged-only`, `--preview`, `--merge`, `--non-interactive`, or `--source`, pass them through to the routed skill.
2. **Ambiguous → ask.** If the input genuinely matches two routes (e.g., "fix the auth feature" could be fix or implement), ask one clarifying question: "Is this a small fix (1-3 files) or a larger feature? I'll route to `/mtk:fix` or `/mtk:implement`."
3. **No input → help.** If invoked with no argument, print the help table.
4. **Pass the description through.** When routing, pass the user's original description as the argument to the target skill. Don't summarize or rephrase it.

## Help Output

When the user asks for help or provides no input, respond with:

```
MTK — available commands:

  /mtk set up this repo          → bootstrap (first-time setup)
  /mtk update to latest          → update toolkit version
  /mtk audit architecture        → extract architecture principles
  /mtk review before commit      → pre-commit security review
  /mtk fix <description>         → small fix (1-3 files)
  /mtk <feature description>     → full implementation workflow

  Power users: /mtk:fix, /mtk:implement, /mtk:pre-commit-review,
               /mtk:setup-bootstrap, /mtk:setup-audit, /mtk:setup-update

  Diagnostics: /mtk status       → show what's loaded
```

## Execution

Once you've matched the route, invoke it immediately using the Skill tool:

```
Skill(skill: "mtk:<matched-skill>", args: "<user's original input>")
```

For the context-report workflow skill (not an entry point), read and follow `.claude/skills/context-report/SKILL.md` directly instead of using the Skill tool.

Do not add preamble, explanation, or commentary before routing. Just route.
