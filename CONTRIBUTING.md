# Contributing to claude-helpers

This toolkit is the shared source of truth for AI-assisted development at Moberg HR.
Anyone on the team can extend it — add commands, agents, or references.

## How the Toolkit Works

```
This repo (.claude/)          moberg-install/update          Target repos (.claude/)
  commands/*.md          ───────────────────────────>        commands/*.md
  agents/*.md                                               agents/*.md
  references/*.md                                           references/*.md
  settings.json            (merge, not overwrite)           settings.json
  manifest.json            (controls what ships)
```

`manifest.json` is the registry. It lists every file that gets distributed, how it gets
distributed (`sync` = overwrite, `merge` = intelligent union), and which files are
`protected` (never touched by updates).

## Adding a New Command

1. Create `.claude/commands/your-command.md` with this structure:

```yaml
---
description: One-line description shown in the command list (keep it under 80 chars)
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
argument-hint: [optional] <expected arguments>
---

# Command Title

[Role statement — who is the agent when running this command]

---

## STEP/PHASE N: [Name]

[Instructions for this step]

### Exit criteria
- [ ] [What must be true before moving on]

---

## COMMON RATIONALIZATIONS — Do Not Fall For These

| Rationalization | Reality |
|---|---|
| [Excuse the LLM will generate to skip a step] | [Why the shortcut is wrong — be specific] |

---

## CRITICAL RULES

1. [Non-negotiable rules as a numbered list]
```

### Required sections

| Section | Purpose |
|---|---|
| **Frontmatter** | `description`, `allowed-tools`, optional `argument-hint` and `model` |
| **Role statement** | Sets the agent's persona and context |
| **Steps/Phases** | The actual workflow, with clear separation |
| **Exit criteria** | Per-step checkboxes — what must be true before proceeding |
| **Common Rationalizations** | Table of excuses + rebuttals (prevents the LLM from talking itself out of following the process) |
| **Critical Rules** | Hard constraints as a numbered list at the end |

### Optional sections

| Section | When to include |
|---|---|
| **Red Flags** | For multi-phase commands — observable signs the process is going wrong |
| **Scope guards** | For commands with defined boundaries (like moberg-fix's 3-file limit) |

2. Register it in `manifest.json`:

```json
"commands/your-command.md": {
  "target": ".claude/commands/your-command.md",
  "action": "sync",
  "description": "What this command does"
}
```

3. Bump the `version` in `manifest.json`.

## Adding a New Agent

Agents are standalone personas invoked by commands (e.g., `moberg-implement` invokes `compliance-reviewer`).

1. Create `.claude/agents/your-agent.md`:

```yaml
---
name: your-agent
description: What it does and when commands should invoke it
allowed-tools: Read, Glob, Grep, Bash
model: sonnet
---

# Agent instructions...
```

**Design rules for agents:**
- Agents should have **restricted tools** — typically read-only (Read, Glob, Grep, Bash for read commands). Don't give agents Write/Edit unless they need to modify files.
- Agents should be **adversarial by default** for review tasks — they exist to find problems, not rubber-stamp.
- Use `model: sonnet` for agents that don't need the full reasoning of opus (review, analysis).

2. Register in `manifest.json` and bump version.

## Adding References

References are shared documents that commands and agents read (coding guidelines, checklists, architecture principles).

1. Place the file in `.claude/references/your-reference.md`
2. Register in `manifest.json` with `"action": "sync"`
3. If the reference should be project-specific and never overwritten by updates, add it to the `protected` array instead

## Writing Anti-Rationalization Tables

This is the most impactful section you can add to a command. LLMs talk themselves out of
following instructions constantly. The table format works because it pre-empts the exact
internal monologue the LLM would generate.

**Good rationalizations are:**
- **Specific** — not "I'll skip this step" but "This is a one-line fix, I don't need to run the tests"
- **Realistic** — things the LLM actually says to itself, not strawmen
- **Paired with sharp rebuttals** — explain WHY the shortcut fails, with concrete consequences
- **Domain-aware** — reference fintech/compliance/audit concerns where relevant

**Bad rationalizations:**
- Generic advice ("always follow best practices")
- Repeating the rule without explaining the consequence
- Hypothetical scenarios that don't actually occur

## Testing Changes Locally

Before pushing changes:

1. **Verify command syntax** — open Claude Code in this repo and run your command to check it loads
2. **Check the manifest** — ensure every new file has a manifest entry
3. **Protected files** — if your command generates files that shouldn't be overwritten by updates,
   add them to `manifest.json`'s `protected` array
4. **Version bump** — increment `version` in `manifest.json` so `moberg-update` picks up changes

## Style Guidelines

- **Be opinionated.** Vague advice is worthless. "Consider using X" is weaker than "Use X. Here's why."
- **Be concrete.** Include code examples, exact commands, specific file paths.
- **Be brief.** Every line the LLM reads costs tokens. Cut ruthlessly.
- **Number rules.** Use §X.Y notation so the review agent can cite exact rules.
- **Match existing patterns.** Read 2-3 existing commands before writing a new one.
