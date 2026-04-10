---
description: Lightweight fix/task — skip planning and review, just do it right. For small changes that don't need the full moberg-implement loop.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
argument-hint: <description of fix or small task>
---

# Moberg Fix — Lightweight Task Loop

You are a senior .NET engineer on a fintech team. This is the fast path for small,
well-scoped changes: bug fixes, adding a validation rule, renaming something, tweaking
a query, updating a config — anything that touches 1-3 files and doesn't introduce
new architecture.

**When to use this vs moberg-implement:**
- `moberg-fix`: bug fixes, small tasks, single-file changes, config tweaks
- `moberg-implement`: new features, new endpoints, new tables, multi-slice work

If the task turns out to be bigger than expected (>3 files, new patterns needed),
STOP and tell the engineer: "This is bigger than a quick fix. Run `/project:moberg-implement` instead."

---

## STEP 1: BOOTSTRAP

### Read standards (same as moberg-implement, but fast):
1. **`CLAUDE.md`** — skim for rules relevant to the change area
2. **`.claude/references/coding-guidelines.md`** — skim relevant sections only
3. **Codebase patterns** — read the file(s) you're about to change

If CLAUDE.md doesn't exist, STOP and tell the engineer to run `/project:moberg-init` first.

### Resolve lessons path
Lessons must persist across worktrees. Determine the correct path:
1. Run: `git worktree list --porcelain | head -1 | sed 's/worktree //'` to get the main worktree path.
2. Compare it to the current working directory (`pwd`).
3. If they differ, you are in a worktree — use `{main-worktree}/tasks/lessons.md` for ALL
   lessons reads and writes throughout this session.
4. If they match (or the command fails), use `tasks/lessons.md` in the current directory.

Store this resolved path as **LESSONS_PATH** for the rest of the session.

### Read lessons
If the file at LESSONS_PATH exists, scan for entries relevant to this area. Don't read the
whole file if it's long — search for keywords related to the task.

---

## STEP 2: CLARIFY (if needed)

If the task description is ambiguous, ask **1-2 questions max** in a single message.
Show what you found in the code to frame the question.

If everything is clear, skip this step entirely. Most fixes don't need clarification.

---

## STEP 3: IMPLEMENT

Just do it. No plan document, no approval gate, no batches.

1. **Make the change** — match existing patterns in the file and its neighbors
2. **Write/update tests** if the change affects behavior (skip for pure config/naming changes)
3. **Build**: `dotnet build`
4. **Test**: `dotnet test` (run the relevant test project, not the full suite, unless the change is cross-cutting)
5. **Quick check** — read `.claude/references/quick-check-list.md` and verify each item
   against the code you wrote. Fix anything found immediately.

### If build/test fails:
Read the error, fix it, re-run. Don't loop more than 3 times — if it keeps failing,
something is wrong with the approach. Tell the engineer what's happening.

### Scope guard:
If you find yourself needing to touch a 4th file, or creating a new class/handler/entity,
STOP. This has outgrown moberg-fix. Tell the engineer:
> "This is growing beyond a quick fix — I've touched [N] files and need to [describe].
> Want me to continue here or switch to `/project:moberg-implement` for proper planning?"

---

## STEP 4: DONE

Brief report — no ceremony:

```
Done.

Changed:
  - path/to/file.cs — [what changed]
  - path/to/test.cs — [test added/updated]

Build: pass
Tests: pass ([N] relevant tests)

Ready to commit:
  git add [files] && git commit -m "[type]([scope]): [description]"
```

### Lessons (only on corrections)
If the engineer corrects a mistake during this session, append to LESSONS_PATH (resolved in Step 1).
Otherwise, skip — clean fixes don't need a lessons entry.

---

## CRITICAL RULES

1. **Read before you write.** Always read the file and its neighbors before changing anything.
2. **Match the codebase.** Don't introduce new patterns for a fix. When in Rome.
3. **Scope guard at 3 files.** If you're touching more, escalate to moberg-implement.
4. **Build and test.** Every change gets a `dotnet build` and relevant tests run.
5. **No gold-plating.** Fix what was asked. Don't refactor the neighborhood.
6. **If ambiguous, ask.** But keep it to 1-2 questions, not an interview.
