---
description: Normative contract for re-running generation over engineer-edited files — classification, MTK-delta diff proposals, needs-review handling, cache update rule. Replaces union merge everywhere.
globs: [".claude/skills/setup-refresh/**", ".claude/skills/setup-audit/**", ".claude/skills/setup-bootstrap/**"]
alwaysApply: false
---

# Regeneration Diff-Proposal Contract

> The single, shared contract for what happens when an MTK generator re-runs over a file that already exists on disk. `setup-refresh`, `setup-audit` (re-run merge), and `setup-bootstrap` (CLAUDE.md merge mode) all delegate here. Skills reference this file by path; they do not restate its rules. **`git merge-file --union` is banned** — it silently blends and duplicates lines in prose files, which is exactly the failure this contract exists to prevent.

---

## 1. Terms

| Term | Definition |
|---|---|
| `ancestor` | The cached **stock template** from the previous generation run, at `.claude/.mtk-cache/v<prev>/<file>` — what MTK generated last time, before any engineer edits. Resolve `<prev>` from the target doc's own stamp (`mtk-version:` field, or the CLAUDE.md `mtk-setup: vX` footer); only if the doc is unstamped, fall back to the highest-versioned cache dir present. |
| `current` | The on-disk file — what the repo actually contains right now, including any engineer edits. |
| `fresh` | The newly generated template output of this run — what MTK would write on a clean bootstrap today. |

`current` is always the baseline. Proposals are additive/subtractive diffs **against `current`**, each independently acceptable. The contract never replaces `current` wholesale except in the stock case below.

## 2. Classification (per file)

Run classification before any write, for every file the generator would produce:

| Condition | Classification | Action |
|---|---|---|
| Listed in `manifest.protected` **and not a declared output of the invoking generator** | **protected** | Never proposed against. No diff, no prompt, no write. Report `SKIP (protected)`. |
| `current` does not exist | **new** | Write `fresh` directly. Report as Created. |
| `current == ancestor` (byte-compare, `cmp -s`) | **stock** | No engineer edits since last generation — safe to overwrite `current` with `fresh`. Report `OVERWRITTEN (stock)`. |
| `current != ancestor` | **engineer-edited** | **Never overwrite. Never `git merge-file --union`.** Go to §3. |
| `ancestor` missing (no cache entry for this file) | **no-ancestor** (conservative) | A missing ancestor is never a license to overwrite — and **never synthesize a delta against `current`**: `diff current fresh` contains a removal hunk for every engineer edit, which is exactly the loss §3 exists to prevent. Go to §3a. |

**Scope of "protected":** `manifest.protected` guards files against *distribution/update sync*, not against their own generator. `CLAUDE.md` is protected from plugin updates yet is `setup-bootstrap`'s declared output; `architecture-principles.md` is protected yet is `setup-audit`'s. A generator's **own declared outputs** always classify via the new/stock/engineer-edited rows above — for them, the never-overwrite guarantee is the diff-proposal mechanism itself, not a SKIP. The protected row exists for files a generator would incidentally touch but does not own (e.g. `setup-audit` encountering `CLAUDE.md`).

## 3. Engineer-edited files: propose, don't apply

1. **Compute the MTK delta:** `diff ancestor fresh`. This isolates what the *toolkit* wants to change — independent of whatever the engineer edited. Engineer edits that the template didn't touch never appear in the delta, so they are never at risk.
2. **Present each hunk as a proposed change with a one-line reason** stating which scan finding, rule, or template change motivated it (e.g., "detected-tools now includes `playwright` — adds test-stack row" or "S4.11 checksum step added to release checklist template"). A hunk without an articulable reason should not be proposed.
3. **Ask via `AskUserQuestion`:**
   ```
   question: "MTK wants to make <N> change(s) to <file>. How should I proceed?"
   header: "Regen diff proposal"
   options:
     - label: "Apply all"
       description: "Apply every proposed hunk to the on-disk file"
     - label: "Let me pick which"
       description: "Walk through the hunks one by one — approve or skip each"
     - label: "Skip all"
       description: "Keep the on-disk file exactly as it is"
   ```
4. **Apply accepted hunks to `current`** — patch the on-disk file, hunk by hunk. Skipped hunks leave `current` untouched in that region.
5. **A hunk that no longer applies cleanly** (the engineer rewrote the region the hunk targets) is **NOT force-applied** — no fuzz, no conflict markers, no "closest match" placement. It is listed under **Needs review** in the invoking skill's final report, with the conflicting on-disk region quoted so the engineer can reconcile by hand.

## 3a. No-ancestor files: additive proposals only

This is the common case away from the bootstrap machine — `.claude/.mtk-cache/` is gitignored, so a teammate's clone has no ancestors at all. Because the MTK delta cannot be computed honestly:

1. **Interactive:** ask the migration question first (same shape as `setup-audit`'s Migration Path): were the current generated files hand-edited since the last generation, or are they stock?
   - **"stock"** → treat `current` as the pseudo-ancestor: `current == ancestor` by construction, so overwrite with `fresh` per §2 and report `OVERWRITTEN (stock)`.
   - **"hand-edited"** (or unsure) → propose **only additive hunks** from `diff current fresh` (content `fresh` adds that `current` lacks). Removal hunks are never proposed; instead print an informational list — "the current template no longer emits: <section titles>" — for the engineer to act on manually, and record it under **Needs review**.
2. **Non-interactive:** defer the whole file — report `NEEDS REVIEW (no ancestor)`, write nothing.
3. **Either way,** after the run seed the cache with `fresh` (per §4) only when the file's proposals were fully resolved, so the next run has a true ancestor.

## 4. Cache update rule

After the run, write **`fresh`** — the stock template output, NOT the merged/patched result — to `.claude/.mtk-cache/v<current>/<file>`, but **only for files whose proposals were fully resolved** (every hunk either applied or explicitly skipped, or the file was classified stock/new).

Files with needs-review hunks **keep their old cache entry**. Updating the cache past an unresolved hunk would make the next run treat the unreconciled state as the ancestor — silently converting a pending decision into permanent data loss.

## 5. Result reporting

Every file the generator considered appears in the invoking skill's run summary with exactly one RESULT value:

| RESULT | Meaning |
|---|---|
| `OVERWRITTEN (stock)` | `current == ancestor`; `fresh` written directly. |
| `PROPOSED (N hunks: A applied, S skipped)` | Engineer-edited; MTK delta proposed; engineer's choices applied. |
| `NEEDS REVIEW (N hunks)` | One or more hunks did not apply cleanly; listed with quoted conflicting regions; cache NOT updated for this file. |
| `NEEDS REVIEW (no ancestor)` | §3a non-interactive deferral — no cache entry existed and no engineer was available to answer the migration question; nothing written. |
| `SKIP (protected)` | Listed in `manifest.protected`; never proposed against. |

## 6. Invariants (non-negotiable)

- The engineer's on-disk content is never destroyed by this contract. The only wholesale overwrite is the stock case, where byte-equality proves there is nothing of the engineer's to lose.
- No union merges, no conflict markers written to disk, no "latest wins."
- The `AskUserQuestion` gate is not skippable. A non-interactive invocation cannot force-apply proposals — it may auto-resolve only the stock and new classifications; engineer-edited files are reported as `NEEDS REVIEW` (deferred) rather than decided unilaterally.
- Deletion is never a proposal outcome. This contract modifies file bodies; it never deletes files. File retirement is governed separately by the File Preservation Policy in `.claude/skills/setup-bootstrap/SKILL.md`.
