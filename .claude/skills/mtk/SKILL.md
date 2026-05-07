---
name: mtk
description: Unified entry point that routes natural language requests to the right MTK skill
type: skill
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, Task, AskUserQuestion
argument-hint: <what you want to do>
---

# MTK — Unified Entry Point

You are a router. Classify the user's intent from their input, then load and follow the matching workflow skill inline. Do NOT do the work yourself — delegate by reading the target skill and following it end-to-end.

## Routing Decision Graph

This graph is the canonical decision flow. The Route Table below is the lookup; this graph is the order. Walk the diamonds top to bottom; first match wins.

```dot
digraph mtk_routing {
  rankdir=TB;
  node [shape=box, style=rounded, fontname="Helvetica"];
  edge [fontname="Helvetica", fontsize=10];

  start    [label="user input"];
  empty    [label="empty / help?", shape=diamond];
  help     [label="print help", style="rounded,filled", fillcolor="#e8f0ff"];
  esc      [label="contains\n'escalated from fix'?", shape=diamond];
  setup    [label="setup / bootstrap /\naudit / init / first time?", shape=diamond];
  redirect [label="redirect: /mtk-setup", style="rounded,filled", fillcolor="#e8f0ff"];
  rev      [label="review / commit /\nstaged / pre-commit?", shape=diamond];
  pcr      [label="pre-commit-review", style="rounded,filled", fillcolor="#e0f0e0"];
  hlth     [label="health / usage /\nstats / analytics?", shape=diamond];
  th       [label="toolkit-health", style="rounded,filled", fillcolor="#e0f0e0"];
  fixv     [label="fix / bug / broken /\nerror / typo / failing?", shape=diamond];
  feat     [label="add / create / build /\nfeature / implement / new?", shape=diamond];
  ambig    [label="ALSO matches feature\n(e.g. 'fix the auth feature')?", shape=diamond];
  ask      [label="ask ONE Q:\nsmall fix (1-3 files) or\nlarger feature?", style="rounded,filled", fillcolor="#fff8d0"];
  fix      [label="fix", style="rounded,filled", fillcolor="#e0f0e0"];
  impl     [label="implement", style="rounded,filled", fillcolor="#e0f0e0"];
  stat     [label="status / report /\nwhat's loaded / diagnostic?", shape=diamond];
  cr       [label="context-report", style="rounded,filled", fillcolor="#e0f0e0"];
  cmd      [label="audit claude.md /\nclaude.md stale?", shape=diamond];
  cma      [label="claude-md-audit", style="rounded,filled", fillcolor="#e0f0e0"];

  start -> empty;
  empty -> help [label="yes"];
  empty -> esc  [label="no"];
  esc   -> impl [label="yes (internal marker)"];
  esc   -> setup [label="no"];
  setup -> redirect [label="yes"];
  setup -> rev  [label="no"];
  rev   -> pcr  [label="yes"];
  rev   -> hlth [label="no"];
  hlth  -> th   [label="yes"];
  hlth  -> fixv [label="no"];
  fixv  -> ambig [label="yes"];
  ambig -> ask  [label="yes"];
  ambig -> fix  [label="no"];
  ask   -> fix  [label="user: small"];
  ask   -> impl [label="user: larger"];
  fixv  -> feat [label="no"];
  feat  -> impl [label="yes"];
  feat  -> stat [label="no"];
  stat  -> cr   [label="yes"];
  stat  -> cmd  [label="no"];
  cmd   -> cma  [label="yes"];
  cmd   -> help [label="no match → help"];
}
```

**Red flags while routing:**

| Rationalization | Reality |
|---|---|
| "User said 'fix' so just route to fix" | Check for feature-sized nouns first ("fix the auth system") — that's the ambig branch, ask once. |
| "Setup-ish wording, I'll route to implement" | Setup is `/mtk-setup` only. Always redirect, never absorb. |
| "I'll summarize what they want before routing" | Pass the original description through verbatim (Rule 6). |
| "Two diamonds match, I'll just pick one" | If both match with similar specificity, ask one Q. Silent guessing = wrong half the time. |

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
| `audit claude.md`, `claude.md audit`, `is claude.md still good`, `claude.md stale`, `memory rot`, `claude.md quality` | `.claude/skills/claude-md-audit/SKILL.md` | "audit CLAUDE.md", "is CLAUDE.md still good?" |
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

## Toolset Expansion (S2.19)

Before loading the target skill, read its frontmatter:

- If it declares `required-toolsets: [<name>, ...]`, resolve via `bash scripts/resolve-toolsets.sh <name> ...`. Treat the result as the advisory tool scope for the dispatched skill — do not invoke tools outside that list without a written escalation note.
- If it declares `forbidden-toolsets: [<name>, ...]`, the tools resolved from those names are off-limits for the duration of the dispatch, even if `required-toolsets` or explicit `allowed-tools` would otherwise allow them.
- If it has an explicit `allowed-tools:` in frontmatter, that list wins (no surprise widening). Toolset expansion is for skills that leave tool scope to the dispatcher.

Log the resolved scope to analytics (via existing `hooks/session-analytics.sh` pipeline) when a skill declares toolsets, so adoption is visible.

## Execution

Once matched, read the target skill file and follow every step of that workflow. Do not summarize; do not skip verification. The target skill owns its own acceptance criteria.

If the route is `/mtk-setup` (setup family), tell the user:

> "Setup lives at `/mtk-setup` — run that directly. Flags: `--audit` re-audits only, `--merge` unifies multi-repo audits, `--preview` shows planned changes, `--non-interactive` skips interview."

Do not add preamble or commentary before routing. Just route.
