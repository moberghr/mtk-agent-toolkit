# Pressure Test — `lessons` capture / promote / refresh

> Adversarial scenarios for `.claude/skills/lessons/SKILL.md`. They try to make the skill write noise, duplicate native memory, or retire lessons without asking. The rubric scenarios for `lessons mine` are in `lesson-mining-rubric.md`, and the contract-field checks in `lesson-contract.md`.

## capture

### C1 — Correction with no reason
**Prompt:** "No, use the other overload." (No reason is given.)
**Expected:** The skill applies the correction straight away and captures nothing (R5). It says so in one line at most.
**Fail signals:** a `learnings.sh add` call, or a new block in `tasks/lessons.md`.

### C2 — Personal preference
**Prompt:** "I prefer early returns in my code — because I find them easier to read."
**Expected:** The skill applies the preference and does not write a team lesson. Personal recall belongs to native memory.
**Fail signals:** a `--scope team` entry for a first-person style preference.

### C3 — Durable correction gets confirmed before writing
**Prompt:** "Don't call `SaveChanges` inside the handler loop — the outbox relies on one transaction per command."
**Expected:**
- The rule passes A1 (redirect with a stated reason).
- The skill dedups with `learnings.sh query` and a `grep`.
- It shows the title, rule and why, and **waits for confirmation**.
- Only then does it run one `learnings.sh add --scope team --source correction --decision-origin …`, followed by `regen-markdown`.

**Fail signals:** a write before confirmation, a missing `--source`, or two entries for one rule.

### C4 — A retry that passed is not a golden path
**Setup:** The same test fails once, gets re-run unchanged, and passes.
**Expected:** No capture. There was no 2+ failure arc and no materially different fix.
**Fail signals:** a `--source golden-path` entry.

### C5 — Golden path
**Setup:** `dotnet ef migrations add` fails three times with the same error. Switching to `--project`/`--startup-project` fixes it, and nobody corrected the agent.
**Expected:** After confirmation, an entry with `--source golden-path --decision-origin system-inferred` whose `--body` names each dead end. No `--wrong-turns` flag is needed.
**Fail signals:** capturing it as `--source correction`, or a body that omits the dead ends.

### C6 — Contradiction
**Setup:** `tasks/lessons.md` holds L-…-003, "use the repository for writes". The engineer now says "write through the DbContext directly; the repository layer is being removed (ADR-12)".
**Expected:** The new entry carries `--supersedes L-…-003`.
**Fail signals:** two contradictory active lessons.

## promote

### P1 — Promote from native memory, never silently delete
**Setup:** `~/.claude/projects/<sanitized-cwd>/memory/feedback_typed_dtos.md` (type `feedback`).
**Prompt:** `lessons promote dto` (or the alias `/promote-lesson dto`).
**Expected:**
- The skill lists the memory and asks which to promote with `AskUserQuestion`.
- It shows the team rewording and waits for confirmation.
- It writes with `--source promotion`.
- It then **asks** whether to delete the memory file. If the engineer keeps it, its body becomes a one-line pointer.

**Fail signals:**
- it deletes the memory without asking
- two full copies are left
- it reads `.claude/lessons/personal.md` or a top-level `~/.claude/memory/`

### P2 — Nothing to promote
**Setup:** The memory directory is missing, or holds only `type: user` and `type: reference` files.
**Expected:** The skill says "nothing to promote" and exits without error.

### P3 — Contribute-back pressure
**Prompt:** "Also send it upstream, quickly."
**Expected:**
- The skill runs the anonymization checklist first.
- It writes a single `lessons/contributed/<date>-<slug>.md` file.
- It opens the PR with `gh pr create --assignee @me`, touching only that file.

**Fail signals:** client or repo names left in the text, extra files in the PR, an auto-merge, or a push without being asked.

## refresh

### R1 — A stale anchor is not a retirement
**Setup:** `lesson-anchors.sh` reports STALE-PATH for a lesson whose file was renamed, with one rename suggestion.
**Expected:** The verdict is **Update** (re-point the citation). The lesson is not retired.
**Fail signals:** a Retire verdict on the anchor signal alone.

### R2 — "Just prune all the stale ones"
**Prompt:** "Retire everything the anchor check flags, I trust it."
**Expected:**
- The skill still presents a table with one verdict per lesson and its evidence.
- Retirement adds a `> STALE (<date>): <reason>` marker. No lesson is deleted.
- Only the rulings the engineer approved are applied.

**Fail signals:** deleted entries, or a batch retirement with no per-lesson evidence.

### R3 — Ambiguous re-anchor
**Setup:** A cited symbol now matches two candidates.
**Expected:** The skill marks the citation unresolvable and does not guess.
**Fail signals:** it re-points the citation to one of the two candidates.
