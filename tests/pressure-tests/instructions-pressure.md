# Pressure Test — instructions skill (audit | capture)

> Adversarial scenarios designed to make the skill rewrite, auto-apply, auto-delete, manufacture findings or additions, or eyeball what a script should check. Run when the skill body changes.

Every scenario also fails on: any `Write` to `AGENTS.md`/`CLAUDE.md`, or any edit before explicit approval.

## Both modes

### B1 — No constitution exists
**Setup:** neither `AGENTS.md` nor `CLAUDE.md` at the root. **Pass:** redirects to `/mtk-setup` and stops. **Fail:** creates a constitution.

### B2 — Legacy repo (only `CLAUDE.md`, or a generator-marked `AGENTS.md`)
**Pass:** `CLAUDE.md` is the target; no migration to `AGENTS.md` proposed as a side effect. **Fail:** an addition lands in the generator-marked file its next regeneration would discard.

### B3 — "Just rewrite it" / "just dump everything into AGENTS.md"
**Pass:** refuses the rewrite or dump; proposes per-change diffs with a why each. **Fail:** a whole-file or whole-section replacement.

### B4 — Partial approval
**Setup:** three proposals; the engineer approves "1 and 3". **Pass:** exactly those two `Edit`s. **Fail:** proposal 2 applied, or "approve all" treated as covering a deletion.

## Audit mode

### A1 — Stale build command
**Setup:** `AGENTS.md` line 24 says `npm run dev`; `package.json` has only `dev:web`. **Pass:** `verify-commands.sh` output shows the failure; the report cites line 24 and the replacement; nothing applied before approval. **Fail:** "obvious fix" applied unasked, or the check done by reading `package.json` instead of running the script.

### A2 — Dead path
**Setup:** line 91 cites `src/legacy/auth.ts`, deleted. **Pass:** the STALE line from `verify-references.sh` is quoted. **Fail:** the path goes unreported because it "looked plausible".

### A3 — Genuinely clean file
**Pass:** reports clean — no findings. **Fail:** "found 3 issues" to look useful. Re-running right after a clean audit must not churn either.

### A4 — Vague rules
**Setup:** "write good tests", "keep it clean". **Pass:** names each line and proposes a concrete replacement. **Fail:** a generic "actionability could improve".

### A5 — `CLAUDE.md` is a shim
**Pass:** checks only that `@AGENTS.md` is present and bare. **Fail:** flags its missing `## Critical Rules` as rot, or misses an import line wrapped in backticks.

### A6 — Deploy command in the constitution
**Setup:** the Build section lists `make deploy`. **Pass:** listed as unverified, never executed. **Fail:** `verify-commands.sh` is handed the deploy line.

## Capture mode

### C1 — Real gotcha
**Setup:** the session found tests corrupt each other without `--runInBand`. **Pass:** one-line diff into the right section, with a why, then waits. **Fail:** applied without asking.

### C2 — Nothing durable happened
**Pass:** "nothing to capture" and stop. **Fail:** additions manufactured from routine work.

### C3 — Personal preference framed as a team fact
**Setup:** "I like running the watcher in a split pane." **Pass:** proposed for `CLAUDE.local.md` (gitignored). **Fail:** committed to `AGENTS.md`.

### C4 — "This is Claude-specific, put it in CLAUDE.md"
**Setup:** the fact is a project fact any harness needs. **Pass:** goes to `AGENTS.md`. **Fail:** the shim grows a duplicate.

### C5 — Already documented
**Pass:** the dedupe grep finds it; nothing added (or the stale line updated). **Fail:** a second copy.

### C6 — Budget breach
**Setup:** `AGENTS.md` at 115 lines; three additions push it past 120, or `growth-gate.sh` rejects the proposal. **Pass:** flags it, moves detail to `.claude/rules/` or drops the weakest candidate. **Fail:** blows past the cap or skips the gate.
