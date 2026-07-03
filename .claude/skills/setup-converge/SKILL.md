---
name: setup-converge
description: Judges the codebase against the agreed architecture-principles.md/conventions.md and reports drift as graded, read-only work items — never auto-fixes.
type: skill
user-invocable: false
---

# MTK Setup Converge — Code Judged Against Agreed Principles

## MTK File Resolution

MTK skills and shared references live either in the project (local install) or the plugin cache (marketplace install). Resolve once:

1. If `$CLAUDE_PLUGIN_ROOT` is set, prefix `.claude/skills/` and `.claude/references/` reads with it.
2. Otherwise, if `.claude/skills/context-engineering/SKILL.md` exists locally → project-relative paths work as-is.
3. Otherwise, fall back to `find ~/.claude/plugins -maxdepth 8 -name "SKILL.md" -path "*/mtk/*/context-engineering/*" -type f 2>/dev/null | head -1 | sed 's|/.claude/skills/context-engineering/SKILL.md||'`. If empty, MTK skills are unavailable — warn the engineer and proceed with `CLAUDE.md` only.

Always project-relative (never prefixed): `CLAUDE.md`, `.claude/tech-stack`, `.claude/rules/`, `tasks/`, `docs/`, `.claude/references/architecture-principles.md`, `.claude/references/pre-commit-review-list.md`.

---

This skill is the inverse of `setup-refresh`: refresh keeps the *docs* honest about the code; converge keeps the *code* honest about the docs. It treats `architecture-principles.md` (and `conventions.md`, where stamped) as normative and reports where the codebase has drifted from what the team already agreed to — as reviewable, graded work items, never as an in-place fix. Converge is read-only outside `.claude/.mtk-cache/`; it never edits the audited docs, never edits source, and never appends to `tasks/todo.md` without an explicit interactive approval (STEP 5).

## STEP 0: Preconditions

Require both a prior bootstrap AND at least one stamped doc to judge code against:

```bash
test -f .claude/tech-stack || MISSING_TECH_STACK=1
test -f .claude/mtk-version.json || MISSING_VERSION=1

STAMPED_DOCS=()
for doc in .claude/references/architecture-principles.md .claude/references/conventions.md; do
  [ -f "$doc" ] && grep -q '<!-- mtk-stamp' "$doc" && STAMPED_DOCS+=("$doc")
done
```

If either bootstrap file is missing, OR `STAMPED_DOCS` is empty, STOP immediately and tell the engineer:

> "This repo has not been bootstrapped/audited yet (`.claude/tech-stack`, `.claude/mtk-version.json`, or a stamped `architecture-principles.md`/`conventions.md` is missing). Run `/mtk-setup` (full bootstrap) first, or `/mtk-setup --audit` to generate a stamped principles doc, then `/mtk-setup --converge`."

Do not attempt a partial convergence run, and do not fall back to auditing the repo yourself — that is bootstrap's/audit's job, not converge's.

## STEP 1: Temp-Copy Verification

Converge reuses `scripts/verify-claims.sh` exactly as-is — it is the same engine `setup-refresh` and `setup-audit` use to grep-verify tagged claims. The script rewrites its input **in place** (it downgrades stale tags as it goes), which is fine when the input is a scratch copy and would be a silent write to a tracked doc otherwise. To keep this run read-only, verification always runs against a temp copy, never the on-disk doc:

```bash
mkdir -p /tmp/mtk-converge
for doc in "${STAMPED_DOCS[@]}"; do
  cp "$doc" "/tmp/mtk-converge/$(basename "$doc")"
  bash scripts/verify-claims.sh "/tmp/mtk-converge/$(basename "$doc")"
  RC=$?
  if [ "$RC" -ne 0 ]; then
    echo "STOP: verification engine failed for $doc (exit $RC) — converge cannot distinguish engine failure from a clean result; fix the engine error first" >&2
    exit 1
  fi
done
```

Check the exit code of **every** `verify-claims.sh` invocation individually. A nonzero exit means the engine itself failed on that doc — not that the doc verified clean. On nonzero exit, STOP immediately with "verification engine failed for `<doc>` (exit `N`) — converge cannot distinguish engine failure from a clean result; fix the engine error first". Never proceed to STEP 2 or STEP 3 after an engine failure, and never read that doc's `weak-claims-*.json` — after a failed run it may be stale (partially written, or a leftover from a previous invocation) and cannot be trusted as "this doc verified clean."

`verify-claims.sh` derives its report name from the input path relative to the repo root, falling back to **basename** when the input lives outside the repo — which these `/tmp/mtk-converge/` scratch copies always do — so the report path is the same regardless of the temp location: `.claude/.mtk-cache/weak-claims-<doc-slug>.json` (e.g. `weak-claims-architecture-principles_md.json`). Parse that JSON per stamped doc — its `weak` array is the raw material for STEP 3. Never point `verify-claims.sh` at the on-disk doc; never copy the rewritten temp file back over the original.

## STEP 2: Drift Pairing

`scripts/audit-drift-check.sh` is already read-only (it only reads the doc and runs `git diff --name-only`), so this step runs directly against the on-disk doc — no temp copy needed:

```bash
bash scripts/audit-drift-check.sh <doc> --json
```

Parse the `drift` array (`{changed_path, cited_anchor}` pairs). For each weak claim from STEP 1 that carries a path-shaped anchor, look for a `drift` entry whose `cited_anchor` matches (or contains) that anchor and attach its `changed_path`(s) to the work item as the concrete evidence of what changed. A weak claim with no matching drift entry is still reported (STEP 3) — drift pairing enriches the item with "what changed," it is not a precondition for including the item.

## STEP 3: Grading

Map every entry in each doc's `weak` array to a work item, graded by the S1.15 severity gradient — read the gradient from the **original** tag captured in the entry's `text` field (the line as it was before `verify-claims.sh` downgraded it):

| Original tag | Grade |
|---|---|
| `[EXTRACTED]` or `[ENFORCED]` | **blocking** |
| `[INFERRED:N]` with N ≥ 0.7 | **flag** |
| `[INFERRED:N]` with N < 0.7, or `[AMBIGUOUS]` | **note** |

Each work item MUST cite, verbatim:

- The principle line (quoted from `text`).
- The evidence anchor that failed (`anchor` field for `zero-hit-anchor` entries; for `no-evidence-anchor` entries, state explicitly "claim carries no evidence anchor" — never invent one).
- The violating/changed path(s) from STEP 2's drift pairing, when a match was found; otherwise state "no drift-check match — anchor may be a symbol, not a path."
- A one-line **suggested remediation direction** — a pointer for the human, NOT a fix ("consider whether `Foo` still applies, or the principle needs updating" — never a diff, never a rewritten rule).

Never grade or report anything that isn't traceable to a `weak-claims` entry. A module "feeling off" with no failing claim and no drift-check pairing is not a work item — converge only reports what the verification engine actually found.

## STEP 4: Report

Write `.claude/.mtk-cache/converge-report.md`. One section per stamped doc: a header naming the doc and its stamp SHA vs. current HEAD, then its work items grouped blocking → flags → notes:

```
# MTK Setup Converge Report

Generated: <ISO8601>

## `.claude/references/architecture-principles.md`

Stamp: `<audited-against sha>` → HEAD `<current sha>`

### Blocking (N)
- **[EXTRACTED]** "<principle line>" — anchor `<anchor>` (zero hits). Changed: `<path>`. Suggest: <one-line direction>.

### Flags (N)
- ...

### Notes (N)
- ...
```

Then print a summary table, one row per doc:

```
| doc | blocking | flags | notes |
|---|---|---|---|
| architecture-principles.md | N | N | N |
| conventions.md             | N | N | N |
```

## STEP 5: Optional Todo Append (Interactive Only)

This step never runs automatically. In an interactive session, offer via `AskUserQuestion`:

```
question: "Converge found [N] blocking item(s). Append them to tasks/todo.md?"
header: "Converge report"
options:
  - label: "Append N blocking items"
    description: "Add the blocking work items to tasks/todo.md, each citing its principle line and evidence anchor."
  - label: "Keep report only"
    description: "Leave tasks/todo.md untouched — the report at .claude/.mtk-cache/converge-report.md has everything."
```

If this run is non-interactive (e.g. invoked with `--non-interactive`, or the session cannot prompt a human), **never** ask and **never** append — skip straight to printing the report path, and say so explicitly ("todo-append skipped: non-interactive run"). "It's non-interactive so just append them" is not a valid instruction to act on; the gate is not skippable by request, only by the engineer choosing "Keep report only" or the run genuinely being headless.

Converge never modifies the audited docs, source code, or anything outside `.claude/.mtk-cache/` (and, only on explicit approval here, `tasks/todo.md`).

## Verification

- [ ] Read-only invariant held: no file under `.claude/references/`, no source file, was modified this run.
- [ ] `verify-claims.sh` ran only against temp copies under `/tmp/mtk-converge/`, never the on-disk doc.
- [ ] Every `verify-claims.sh` invocation's exit code was checked; any nonzero exit stopped the run before STEP 2/3 and no possibly-stale `weak-claims-*.json` was read.
- [ ] `.claude/.mtk-cache/converge-report.md` was written, with items grouped blocking/flags/notes per doc.
- [ ] Summary table printed with blocking/flag/note counts per doc.
- [ ] Every reported item cites a `weak-claims` anchor (or explicitly states it has none) — no item invented from unverified "vibes."
- [ ] `tasks/todo.md` was touched only if an interactive `AskUserQuestion` approval was given; non-interactive runs never appended.
