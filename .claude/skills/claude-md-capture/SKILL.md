---
name: claude-md-capture
description: Capture learnings from the current session into CLAUDE.md — discovered commands, gotchas, env quirks, and patterns that would help future sessions. Reflect at the end of a session, propose minimal append-only additions, and apply only with approval. Use at the end of a session that surfaced context CLAUDE.md was missing.
type: skill
license: MIT
compatibility:
  - claude-code
  - cursor
  - codex
trigger: capture-claude-md|session-learnings|update-claude-md|what-did-we-learn|revise-claude-md
skip_when: bootstrap|first-time-setup|mid-task|nothing-learned
user-invocable: false
---

# CLAUDE.md Capture

## Current Targets

```!
echo "--- Writable CLAUDE.md files ---"
{ find . -maxdepth 6 -name CLAUDE.md -not -path "./.git/*" -not -path "*/node_modules/*" 2>/dev/null; } | sort -u
echo "--- Personal (gitignored) ---"
test -f .claude.local.md && echo ".claude.local.md (present)" || echo ".claude.local.md (absent — create for personal-only notes)"
echo "--- Line budget of root CLAUDE.md ---"
test -f CLAUDE.md && echo "CLAUDE.md: $(wc -l < CLAUDE.md) lines (root cap 120)" || echo "(no root CLAUDE.md — run /mtk-setup first)"
```

## Overview

A session often surfaces context that CLAUDE.md was missing — a build command you
had to discover, a gotcha you hit, an env quirk, a pattern the codebase follows.
That knowledge should compound into project memory so the next session starts
where this one ended. This skill **reflects on the finished session**, drafts
minimal additions, shows them as diffs, and applies only what the engineer
approves.

It is distinct from its two siblings:

- **`claude-md-audit`** re-grades what is *already* in CLAUDE.md against a rubric
  and fixes rot. Capture *adds new* knowledge this session produced.
- **`correction-capture`** records *engineer corrections* as reusable lessons in
  `lessons.md`. Capture records *project facts* (commands, gotchas, env) into
  CLAUDE.md — the prompt every session loads.

It honors S1.5 (CLAUDE.md is protected): append-only by default, `Edit` never
`Write`, no additions applied before approval.

## When To Use

- At the end of a session that revealed context CLAUDE.md was missing
- When the engineer says "save what we learned", "update CLAUDE.md", "remember
  this for next time", or invokes the equivalent end-of-session capture
- After discovering a non-obvious command, env requirement, or codebase pattern
  that future sessions will need

### When NOT To Use

- First-time repo setup — use `/mtk-setup` (runs `setup-bootstrap`)
- Mid-task — capture at a natural stopping point, not while work is in flight
- Re-grading or fixing stale content — use `claude-md-audit`
- Recording an engineer correction — use `correction-capture` (writes a lesson,
  not a CLAUDE.md fact)
- The session surfaced nothing durable — say so and stop. Do not manufacture
  additions to look useful.

## Workflow

### Phase 1 — Reflect

Review the session. What context, had it been in CLAUDE.md at the start, would
have saved time? Look specifically for:

- **Commands** discovered or corrected (build, test, dev, lint, deploy, migrate)
- **Gotchas** — ordering dependencies, prerequisites, "delete X if Y" recovery steps
- **Environment / config quirks** — required vars, flags, version pins
- **Codebase patterns** that were not obvious from a first read

If none of these came up, stop here and tell the engineer there is nothing worth
capturing.

### Phase 2 — Decide destination (team vs personal)

| Destination | When |
|---|---|
| `CLAUDE.md` (committed, team-shared) | Project facts every contributor and agent benefits from |
| `.claude.local.md` (gitignored, personal) | Your own preferences, local-only paths, machine-specific setup |

Heuristic: first-person preference ("I like to run…") → personal. Project fact
("tests must run with `--runInBand` due to shared DB state") → team. When in
doubt, propose it as personal.

For monorepos, prefer the **nearest** package `CLAUDE.md` when the fact is local
to one package; only put cross-cutting facts in the root file.

### Phase 3 — Check for duplicates

Before drafting, grep the target file (and `tasks/lessons.md`) for the keyword.
If the fact is already documented, do not re-add it — update the existing line
only if it is now wrong.

```bash
grep -in "<keyword>" CLAUDE.md .claude.local.md tasks/lessons.md 2>/dev/null
```

### Phase 4 — Draft additions (concise)

One line per concept. CLAUDE.md is part of the prompt — brevity is the whole
point. Format: `` `<command or pattern>` — <brief description> `` and match the
existing file's style (table vs bullet list — do not impose a new structure).

Avoid: verbose explanations, restating what the code already says, generic best
practices, and one-off fixes unlikely to recur.

Mind the budget: the root CLAUDE.md cap is 120 lines. If an addition would push
it over, propose moving detail to the relevant `.claude/rules/` file instead, or
drop the lowest-value candidate.

### Phase 5 — Show proposed changes (no edits yet)

**Stop before any edit.** For each candidate, show where it goes, the diff, and
one line of why it helps future sessions.

```
### Addition 1 → ./CLAUDE.md (Gotchas section)

**Why:** Tests silently corrupt each other without --runInBand; future sessions
would re-discover this the hard way.

\`\`\`diff
+ Tests must run sequentially (`pytest --runInBand`) — shared DB state.
\`\`\`
```

Then ask: **"Apply these? (yes / partial / no)"**

### Phase 6 — Apply with approval

After explicit approval, apply with `Edit` (never `Write`). Append into the
relevant section; never restructure. If the engineer approved "partial", apply
only the named subset. If a personal item was chosen and `.claude.local.md` does
not exist, create it (it is gitignored by `setup-bootstrap`).

## Rules

- **Never apply before approval.** Phase 5 output is a proposal, not an edit.
- **Append over rewrite.** New facts go at the end of the relevant section.
- **Use `Edit`, never `Write`** on CLAUDE.md (S1.5 protected-file rule).
- **One line per concept.** If you need a paragraph, it belongs in `.claude/rules/`.
- **Match the file's existing style.** Do not impose a template.
- **No manufactured additions.** "Nothing to capture" is a valid, common outcome.

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` for the shared MTK table.
Capture-specific traps:

- **"I should add a few things so the session feels productive."** No. Capture
  only what was genuinely surfaced. Empty output beats noise in the prompt.
- **"This gotcha is obvious."** If you had to discover it this session, it was
  not obvious to a cold-start agent — capture it.
- **"I'll rewrite the Commands section to be cleaner while I'm here."** No. That
  is `claude-md-audit`'s job, gated on its own rubric. Capture appends; it does
  not refactor.
- **"This is a personal preference, but the team file is easier."** Default
  personal. Promotion to the team file is the engineer's explicit call.

## Red Flags

- Additions applied before the engineer approved them
- A whole-section rewrite proposed instead of an append
- Generic best practices ("write tests", "use good names") added as if
  project-specific
- Root CLAUDE.md pushed over 120 lines by the additions
- `.claude.local.md` content committed (it must stay gitignored)

## Verification

- [ ] Phase 1 reflection named concrete session learnings (or "nothing to capture")
- [ ] Each addition is project-specific and one line per concept
- [ ] Duplicates were grep-checked before drafting
- [ ] Proposal shown as diffs with a one-line "why"; no edits before approval
- [ ] Edits used `Edit` with explicit old/new strings (never `Write`)
- [ ] Root CLAUDE.md still within its 120-line budget after additions
- [ ] Personal items went to `.claude.local.md`, not the committed file
