---
name: preview-gate
description: Preview Gate for setup-bootstrap --preview — plan-summary table, ASCII example, and the AskUserQuestion confirmation flow shown before any files are written. Read on-demand by setup-bootstrap STEP 3.5b when --preview is set.
globs: [".claude/skills/setup-bootstrap/**"]
alwaysApply: false
---

# Preview Gate — `setup-bootstrap --preview`

Read this companion from `setup-bootstrap` STEP 3.5b when the engineer passed
`--preview`. **Do not write any files yet** while following this flow.

1. Hold the generated content in memory (CLAUDE.md body, each
   `.claude/rules/*.md` body, AGENTS.md, pre-commit-review-list).
2. For each pending file, stage it to a temp path and compute size with
   `scripts/count-tokens.sh`:
   ```bash
   TMP=$(mktemp); echo "$CONTENT" > "$TMP"
   read -r LINES TOKENS < <(bash scripts/count-tokens.sh "$TMP")
   ```
3. Print a plan summary in table form (fixed columns, right-aligned numbers):
   ```
   📋 PROPOSED CHANGES (preview — nothing written yet)

   FILE                                          STATUS     LINES  ~TOKENS
   CLAUDE.md                                     NEW          178     1843   (cap 120 ← FAIL)
   .claude/rules/security.md                     NEW           47      512
   .claude/rules/architecture.md                 NEW           62      698
   .claude/rules/testing.md                      NEW           41      452
   .claude/rules/data-layer.md                   NEW           38      401
   .claude/rules/project-specific.md             NEW           29      314
   .claude/references/pre-commit-review-list.md  NEW           24      268
   AGENTS.md                                     NEW           23      287
   ```
   If any row shows `FAIL`, refuse to proceed: print "Generated CLAUDE.md
   exceeds 120 lines — move <section> to .claude/rules/<name>.md" and abort.
   This gate fires even without `--preview` (see the skill's STEP 3.5b for the
   unconditional form of this rule).

   Follow the table with a one-block summary:
   ```
   Critical Rules (top of CLAUDE.md):
     §0.1 [first rule]
     §0.2 [second rule]
     ...
   Tech stack:  [stack]
   Package mgr: [pm, if ts]
   ```
4. Print the full CLAUDE.md body inline (inside a fenced code block) so the
   engineer can review it.
5. Ask via `AskUserQuestion`:
   ```
   question: "Proceed with writing these files?"
   header: "Bootstrap confirmation"
   options:
     - label: "Yes, write all"
       description: "Commit the proposed files as shown"
     - label: "Yes, but skip CLAUDE.md"
       description: "Write rules files only — I'll author CLAUDE.md myself"
     - label: "Cancel"
       description: "Discard the proposed output"
   ```
6. On "Cancel", stop and leave the repo untouched.
7. On "skip CLAUDE.md", write everything except root CLAUDE.md.
8. On "Yes, write all", proceed to STEP 4.
