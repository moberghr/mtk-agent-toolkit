# Pressure Test — Personal vs Team Lessons Split

> Adversarial test for the two-tier lessons system: `correction-capture` defaults to `.claude/lessons/personal.md` (gitignored), `/promote-lesson` moves a lesson to `tasks/lessons.md` (committed).

## Setup

```bash
cd "$(mktemp -d -t mtk-lessons-XXXX)"
mkdir -p .claude/lessons tasks
```

## Scenarios

### S1 — Personal preference defaults to personal.md

**Prompt:** "I prefer 4-space indents in this file going forward."

**Expected behavior:**
- Lesson appended to `.claude/lessons/personal.md`, NOT `tasks/lessons.md`
- First-person language preserved ("I prefer...")
- No prompt asking which file to use (clear personal signal)

**Fail signals:**
- Lesson written to `tasks/lessons.md`
- Lesson written to both files
- Asked the engineer where to put it (heuristic should have decided)

### S2 — Team-wide rule asks before writing to team file

**Prompt:** "The team's auth pattern is to use middleware, not per-route checks."

**Expected behavior:**
- Acknowledges the team-wide signal ("the team's...")
- Asks the engineer: personal or team?
- On "team" → writes to `tasks/lessons.md`
- On "personal" → writes to `.claude/lessons/personal.md`

**Fail signals:**
- Auto-writes to `tasks/lessons.md` without asking
- Defaults to personal without confirming when team signals are strong

### S3 — Ambiguous → defaults to personal

**Prompt:** "Don't use `dynamic` here — use the typed DTO."

**Expected behavior:**
- No clear personal/team signal → default to personal
- Engineer can override via "actually, this is a team rule"

### S4 — SessionStart announces personal lessons

**Setup:** Populate `.claude/lessons/personal.md` with one entry, then trigger SessionStart hook.

```bash
cat > .claude/lessons/personal.md <<EOF
## 2026-04-29 — Test entry

**Rule:** Test
EOF
bash hooks/session-start
```

**Expected:** Output contains `Personal lessons active: 1 entries` and points at `/promote-lesson`.

**Fail signals:**
- No mention of personal lessons in SessionStart output
- Mentions personal lessons even when file is empty

### S5 — Empty personal.md does not announce

```bash
: > .claude/lessons/personal.md
bash hooks/session-start | grep "Personal lessons active" && echo "FAIL"
```

**Expected:** No "Personal lessons active" line emitted.

### S6 — `/promote-lesson` moves lesson and removes from personal

**Setup:** Personal file has one entry titled "Use typed DTOs".

**Prompt:** `/promote-lesson typed`

**Expected behavior:**
- Lists matching entries
- Asks which to promote
- On selection: shows reworded text (first-person → team phrasing) and asks for confirmation
- After confirmation: appends to `tasks/lessons.md` with `**Promoted from personal:** 2026-XX-XX` provenance
- Removes the entry from `.claude/lessons/personal.md`

**Fail signals:**
- Entry exists in both files (duplication)
- Wording landed unchanged when first-person phrasing was clear
- Promoted without explicit selection

### S7 — `/promote-lesson` with empty personal.md exits cleanly

```bash
: > .claude/lessons/personal.md
# Run /promote-lesson
```

**Expected:** Says "nothing to promote", exits without error.

### S8 — `.gitignore` excludes personal.md

```bash
git init -q
echo "test" > .claude/lessons/personal.md
git status --porcelain | grep personal.md && echo "FAIL: personal.md is tracked"
```

**Expected:** `personal.md` is gitignored — does not appear in `git status`.

## Red flags

- `correction-capture` writes architectural rules to personal file silently (heuristic too aggressive toward personal)
- `correction-capture` writes individual preferences to team file silently (heuristic too aggressive toward team)
- `/promote-lesson` modifies tasks/lessons.md without confirmation
- `/promote-lesson` leaves the entry in personal.md after promotion
- SessionStart announces personal lessons that don't exist
- Personal lesson contents leak into git history
