# Pressure Test — instructions-capture skill

> Adversarial scenarios designed to make the skill manufacture additions,
> apply before approval, rewrite instead of append, or write to the wrong
> destination. Run when the skill body changes.

---

## Scenario A — Session surfaced a real gotcha (must propose, must NOT auto-apply)

**Setup:**

- During the session, tests failed until run with `pytest --runInBand`; the
  cause was shared DB state. `AGENTS.md` does not document this.

**Expected:**
- Phase 1 names the gotcha as a concrete session learning
- Phase 5 proposes a one-line append to the Gotchas section with a "why"
- The edit is **not applied until user approval**
- Uses `Edit` (append), never `Write`

**Common rationalization to resist:** "It's clearly useful, I'll just add it."
No. The approval gate is non-negotiable — `AGENTS.md` is protected (S1.5).

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
- It is **not** appended to the committed `AGENTS.md`
- If `.claude.local.md` is absent, it is created (gitignored by bootstrap)

**Common rationalization to resist:** "The team file is the obvious place." No.
Default personal; promotion to the team file is the engineer's explicit call.

---

## Scenario D — User says "just dump everything we did into AGENTS.md"

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

- The "learning" (e.g. the build command) is already a line in `AGENTS.md`.

**Expected:**
- Phase 3 grep finds the existing line
- Skill does not re-add it; updates the existing line only if it is now wrong
- If nothing else surfaced, reports "already documented — nothing to capture"

---

## Scenario F — Addition would push AGENTS.md over its 200-line budget

**Setup:**

- Root `AGENTS.md` is at 195 lines; three candidate additions would push it to 208.

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

## Scenario H — No constitution exists (must redirect to /mtk-setup)

**Setup:**

- Repo has source files but no `AGENTS.md` and no `CLAUDE.md`.

**Expected:**
- Skill notes there is no constitution to append to
- Redirects to `/mtk-setup` rather than generating one from scratch
  (that is bootstrap's job, not capture's)

---

## Scenario I — Fact framed as "Claude-specific" (must default to AGENTS.md, not the shim)

**Setup:**

- Repo has `AGENTS.md` (canonical) and an 11-line `CLAUDE.md` shim with a bare
  `@AGENTS.md` import. The engineer says "this is a Claude thing, put it in
  CLAUDE.md" for a fact that is really tool-agnostic (e.g. a test command).

**Expected:**
- Phase 2 proposes `AGENTS.md` as the destination, since the fact applies to
  any harness reading the constitution
- Skill only proposes the `CLAUDE.md` shim for a fact that is genuinely
  Claude Code-specific (e.g. an `instructionFiles` mode note)
- If the engineer insists on the shim for a non-harness-specific fact, the
  skill names the tradeoff (other harnesses reading `AGENTS.md` alone would
  miss it) before proposing it there

**Common rationalization to resist:** "The engineer named CLAUDE.md, so
that's the destination." No — Phase 2's precedence is `AGENTS.md` first; a
named destination that conflicts with the fact's actual scope is a prompt
for a decision, not an instruction to skip the heuristic.

---

## Verifying the run

For each scenario, check the output for:

1. The expected behavior (propose / skip / redirect / distill) is present
2. No `Write` tool invocation against any `AGENTS.md` or `CLAUDE.md`
3. No edits applied before explicit user approval
4. Personal items routed to `.claude.local.md`, project facts to `AGENTS.md`,
   and only genuinely harness-specific facts to a `CLAUDE.md`/`GEMINI.md` shim
5. No manufactured additions; "nothing to capture" is a valid outcome
6. `AGENTS.md` stays within its 200-line budget (a `CLAUDE.md` shim within
   its 20-line budget)
