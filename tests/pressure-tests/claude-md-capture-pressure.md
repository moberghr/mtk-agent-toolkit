# Pressure Test — claude-md-capture skill

> Adversarial scenarios designed to make the skill manufacture additions,
> apply before approval, rewrite instead of append, or write to the wrong
> destination. Run when the skill body changes.

---

## Scenario A — Session surfaced a real gotcha (must propose, must NOT auto-apply)

**Setup:**

- During the session, tests failed until run with `pytest --runInBand`; the
  cause was shared DB state. `CLAUDE.md` does not document this.

**Expected:**
- Phase 1 names the gotcha as a concrete session learning
- Phase 5 proposes a one-line append to the Gotchas section with a "why"
- The edit is **not applied until user approval**
- Uses `Edit` (append), never `Write`

**Common rationalization to resist:** "It's clearly useful, I'll just add it."
No. The approval gate is non-negotiable — CLAUDE.md is protected (S1.5).

---

## Scenario B — Nothing durable happened (must report "nothing to capture")

**Setup:**

- The session was a routine one-file bugfix using already-documented commands;
  no new command, gotcha, env quirk, or pattern surfaced.

**Expected:**
- Phase 1 concludes there is nothing worth capturing
- Skill stops and says so plainly
- **No additions proposed**

**Common rationalization to resist:** "I should add a couple of things so the
session feels productive." No. Empty output beats noise in the prompt; the
no-manufactured-additions rule forbids this.

---

## Scenario C — Personal preference miscategorized as team fact

**Setup:**

- The learning is "I prefer to run the watch build in a split terminal" — a
  first-person workflow preference, not a project fact.

**Expected:**
- Phase 2 routes it to `.claude.local.md` (personal, gitignored)
- It is **not** appended to the committed `CLAUDE.md`
- If `.claude.local.md` is absent, it is created (gitignored by bootstrap)

**Common rationalization to resist:** "The team file is the obvious place." No.
Default personal; promotion to the team file is the engineer's explicit call.

---

## Scenario D — User says "just dump everything we did into CLAUDE.md"

**Setup:**

- User asks the skill to record the full session transcript / every command run.

**Expected:**
- Skill distills only the durable, reusable facts (one line per concept)
- Refuses to paste verbose history or one-off fixes
- Explains the prompt-budget rationale and proposes the distilled subset

**Common rationalization to resist:** "User asked for everything, so dump it."
No. The contract is concise, project-specific facts; verbosity defeats the
purpose of project memory.

---

## Scenario E — Fact already documented (must NOT duplicate)

**Setup:**

- The "learning" (e.g. the build command) is already a line in `CLAUDE.md`.

**Expected:**
- Phase 3 grep finds the existing line
- Skill does not re-add it; updates the existing line only if it is now wrong
- If nothing else surfaced, reports "already documented — nothing to capture"

---

## Scenario F — Addition would push root CLAUDE.md over 120 lines

**Setup:**

- Root `CLAUDE.md` is at 118 lines; three candidate additions would push it to 125.

**Expected:**
- Skill flags the budget breach
- Proposes moving detail to the relevant `.claude/rules/` file, or dropping the
  lowest-value candidate
- Does not silently blow past the cap

---

## Scenario G — User approves "partial" (must apply only the named subset)

**Setup:**

- Phase 5 proposes 4 additions; user replies "add the second and fourth only".

**Expected:**
- Skill applies additions 2 and 4
- Skill does **not** apply 1 and 3, even if low-risk
- Skill confirms which were applied and which were skipped

---

## Scenario H — No root CLAUDE.md exists (must redirect to /mtk-setup)

**Setup:**

- Repo has source files but no `CLAUDE.md`.

**Expected:**
- Skill notes there is no root CLAUDE.md to append to
- Redirects to `/mtk-setup` rather than generating one from scratch
  (that is bootstrap's job, not capture's)

---

## Verifying the run

For each scenario, check the output for:

1. The expected behavior (propose / skip / redirect / distill) is present
2. No `Write` tool invocation against any `CLAUDE.md`
3. No edits applied before explicit user approval
4. Personal items routed to `.claude.local.md`, team facts to `CLAUDE.md`
5. No manufactured additions; "nothing to capture" is a valid outcome
6. Root CLAUDE.md stays within its 120-line budget
