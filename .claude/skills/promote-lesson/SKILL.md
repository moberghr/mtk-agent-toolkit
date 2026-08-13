---
name: promote-lesson
description: Promote a personal lesson from .claude/lessons/personal.md to the team-wide tasks/lessons.md, optionally rewording for team applicability.
type: skill
allowed-tools: Read, Write, Edit, Bash, AskUserQuestion
argument-hint: [keyword to filter lessons]
user-invocable: true
---

# Promote Lesson

## Overview

Personal lessons in `.claude/lessons/personal.md` are gitignored — they belong to the engineer, not the team. When a personal lesson matures into a rule that every contributor should follow, promote it to the committed `tasks/lessons.md`. This skill is the explicit, audited path for that move.

## When To Use

- The engineer asks to "share a personal lesson with the team"
- A personal lesson has recurred 3+ times and clearly applies to others
- The engineer says "promote", "share", "make this team-wide", "add this to lessons"

### When NOT To Use

- Lesson is genuinely personal preference (style, individual workflow)
- Lesson is already in `tasks/lessons.md`
- The personal file does not exist or is empty (nothing to promote)

## Workflow

1. **Locate the personal file.** Resolve to main worktree if in a worktree. If `.claude/lessons/personal.md` does not exist, tell the engineer there is nothing to promote and stop.

2. **List candidates.** Read `.claude/lessons/personal.md` and extract every `## ` header with its block. If the engineer passed a keyword argument, filter blocks whose body matches the keyword (case-insensitive). Show the list, numbered, with the title and a one-line excerpt.

3. **Ask which to promote.** Use `AskUserQuestion` with the numbered list. Accept multiple selections.

4. **Reword for team.** For each selected lesson, rewrite first-person language (`I`, `my`) into team-applicable phrasing (`engineers`, `the codebase`, `we`). Show the proposed reworded text and confirm with the engineer before writing — wording matters when it lands in a committed file.

5. **Append to team store.**
   - **Structured (preferred when `scripts/learnings.sh` is present).** Add a JSONL entry with `--scope team --source promotion` and the reworded body, then `learnings.sh regen-markdown` to rebuild `tasks/lessons.md`:
     ```bash
     # Resolve the script: project copy first, else the plugin's copy.
     LS="$([ -n "${MTK_HELPER_ROOT:-}" ] && echo "$MTK_HELPER_ROOT/scripts/learnings.sh" || ([ -f scripts/learnings.sh ] && echo scripts/learnings.sh || echo "${CLAUDE_PLUGIN_ROOT:-.}/scripts/learnings.sh"))"
     bash "$LS" add --scope team --source promotion \
       --decision-origin "<inherit from the personal entry being promoted>" \
       --severity warn --phase any \
       --title "<reworded title>" --body "<reworded body>" \
       --rule "<rule>" --applies-when "<when>"
     bash "$LS" regen-markdown
     ```
   - **Markdown fallback.** Append the reworded entry to `tasks/lessons.md` at the bottom (newest last). Keep the structure: `## [Date] — [Title]`, `**Correction:**`, `**Rule:**`, `**Why:**`, `**Applies to:**`. Add a `**Promoted from personal:**` note with the original date so provenance is auditable.

5b. **Optional: attach an executable contract (v7.25).** Promotion is the natural point to make a lesson *checkable* rather than advisory. When the lesson has a verifiable outcome, add the contract fields so a future session can confirm it, not just read it:
   ```bash
   # $LS resolved in step 5 (project copy, else plugin copy).
   bash "$LS" add --scope team --source promotion ... \
     --confidence high \
     --output-contract '{"required_files":[...],"json_fields":[...]}' \
     --prefinal-checklist '[{"check_id":"...","description":"...","verification_method":"...","blocking":true}]' \
     --source-evidence-refs "ref1,ref2"
   ```
   Reserve `--confidence high` for a lesson whose golden path was **actually verified** — an unverified guess stays `low`/`medium`. `mtk-doctor` lints contract well-formedness. Contracts are optional; a prose lesson is still a valid lesson. See `.claude/references/learnings-schema.md` → *Executable lesson contract*.

6. **Remove from personal file.** Delete the promoted entry from `.claude/lessons/personal.md`. Do not leave a duplicate — the team file is now authoritative for that rule.

7. **Suggest CLAUDE.md promotion.** If the lesson is foundational (architectural rule, security constraint, repeated correction), tell the engineer this might belong in `CLAUDE.md` or `.claude/rules/` rather than `tasks/lessons.md`. CLAUDE.md is for permanent standards; lessons.md is for accumulated patterns.

8. **Offer team-wide contribute-back (optional).** A team-promoted lesson can also be shared across *all* repos via the central toolkit. After step 5, ask via `AskUserQuestion` whether to open a contribute-back PR to the MTK repo (`moberghr/mtk-agent-toolkit`). Default is **no** — only offer, never auto-push.

   If the engineer accepts:
   a. **Anonymize first (mandatory).** Run the anonymization checklist below against the lesson text. The lesson is going to a shared repo — it must contain zero client/repo-identifying or secret material.
   b. Write the anonymized lesson to a single file `lessons/contributed/<YYYY-MM-DD>-<slug>.md` following the format documented in `lessons/contributed/README.md`.
   c. Open a PR with `gh pr create` targeting `main`, touching only that one file. The CI workflow `.github/workflows/validate-lesson-pr.yml` validates path/size/secret/injection constraints and labels the PR `lesson-validated`; **a human merges it** — the workflow never auto-merges.
   d. Do not push anything else in that PR. One lesson per PR keeps the audit trail clean.

   **Anonymization checklist (every item must pass before the PR is opened):**
   - [ ] No client, customer, or internal repo names (replace with a generic role, e.g. "a payments service")
   - [ ] No internal URLs, hostnames, ticket IDs, or employee names
   - [ ] No credentials, tokens, connection strings, or key material of any shape
   - [ ] No file paths that reveal a private project's structure (generalize to the pattern)
   - [ ] The rule still makes sense stripped of specifics — if it doesn't, it's too project-specific to contribute; keep it in `tasks/lessons.md` only

## Rules

- Never auto-promote based on heuristics. Promotion is always explicit.
- Never silently rewrite — show the proposed team wording and get confirmation.
- Preserve the original capture date; mark the promotion date separately.
- A promoted lesson must be removed from `personal.md` — duplication defeats the split.
- If `tasks/lessons.md` does not exist (new repo), create it with the standard header before appending.

## Verification

- [ ] Selected lessons appended to `tasks/lessons.md`
- [ ] First-person language rewritten and confirmed by the engineer
- [ ] Selected lessons removed from `.claude/lessons/personal.md`
- [ ] Provenance note (`Promoted from personal: <date>`) preserved
- [ ] Engineer notified if any lesson belongs in CLAUDE.md instead
- [ ] Contribute-back offered (not forced); if accepted, anonymization checklist passed and a single-file PR opened under `lessons/contributed/` with no auto-merge

## Red Flags

- Promoting without the engineer's explicit selection
- Leaving the lesson in both files (creates two sources of truth)
- Promoting style preferences ("I prefer 4-space indents") that should stay personal
- Mass-promoting all personal lessons in one go without per-lesson confirmation
