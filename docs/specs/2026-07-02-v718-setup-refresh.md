# v7.18.0 — Setup refresh loop

**Date:** 2026-07-02
**Scope:** feature
**Security impact:** none (no auth/secrets/audited state; all new writes go through the existing secret-scan gate)
**Baseline area:** setup (mtk-setup / setup-audit / setup-bootstrap)

## Context

`/mtk-setup` is strong on first run (pinned guidelines, repomap-evidenced audit, claim verification, instruction-budget discipline) but weak on refresh:

- `--audit` regenerates only `architecture-principles.md` + `conventions.md`. There is no mode that coherently refreshes **all** generated artifacts (CLAUDE.md proposals, rules, conventions, detected-tools, reference pruning, AGENTS.md/tool configs, indexes).
- `scripts/audit-drift-check.sh` detects staleness (stamped SHA vs HEAD ∩ cited files) but nothing consumes it — every re-run re-reads the whole codebase.
- The re-run merge in `setup-audit` STEP -1 uses `git merge-file --union`, which can silently blend or duplicate lines in prose files.
- Interview answers dissolve into generated prose; a refresh cannot distinguish scan-derived claims from engineer-stated rules, so human knowledge is lost or auto-downgraded on re-verification.
- Long audits on large repos do not survive crash/compaction; there is no resume.

This release closes the loop: **detect → preview → scoped regen → propose diffs → gate in CI**, plus first-run hardening (persisted interview, resumable scans, claim-retry).

## F1 — `setup-refresh` skill + `--refresh` / `--dry-run` routing

**New workflow skill `.claude/skills/setup-refresh/SKILL.md`** (`type: skill`, `user-invocable: false`, STEP-structured like setup-audit; include the standard MTK File Resolution preamble and the File Preservation Policy contract by reference to setup-bootstrap).

Steps (STEP-numbered):

- **STEP 0 — Preconditions.** Require a prior bootstrap: `.claude/tech-stack` and `.claude/mtk-version.json` must exist; otherwise stop and direct the engineer to `/mtk-setup` (bootstrap). Resolve stack skill as usual.
- **STEP 1 — Staleness plan.** Run `bash scripts/setup-refresh-plan.sh --json` (F2). Parse the per-artifact statuses.
- **STEP 2 — Dry-run gate.** If `--dry-run` was passed: print the plan table verbatim plus a one-paragraph "what a full refresh would do" summary and STOP without writing anything.
- **STEP 3 — Scoped regeneration.** For each artifact with status `stale` or `missing`:
  - `architecture-principles.md` / `conventions.md`: re-run the relevant audit steps from `setup-audit`, but **scope the re-read to the changed files** reported by the drift check (plus their containing modules); untouched sections are carried over verbatim. Full re-audit only when the stamp is missing/unreachable or the changed-file set exceeds ~30% of tracked source files.
  - `.claude/detected-tools.json`: re-run audit STEP 2.6 detection only.
  - Reference pruning: re-run bootstrap STEP 3.6 against the fresh `detected-tools.json`.
  - `AGENTS.md` + tool configs + indexes: regenerate deterministically (`scripts/generate-agents-md.sh`, `scripts/generate-tool-configs.sh --all`, `scripts/refresh-derived.sh references triggers`).
  - `CLAUDE.md` and `.claude/rules/*`: never rewritten in place — go through F3 (diff-proposal contract).
- **STEP 4 — Engineer-edited files.** Apply `.claude/references/regen-diff-contract.md` (F3) for any regenerated file whose on-disk copy differs from its `.claude/.mtk-cache/` ancestor.
- **STEP 5 — Grounding.** Stamp refreshed docs (Sync Impact block, F6), run `scripts/verify-claims.sh` per doc with the retry loop (F6). Load `.claude/setup-answers.json` (F4) and keep engineer-sourced rules cited to it.
- **STEP 6 — Report.** Print a summary with four counts: `Updated / Created / Preserved (untouched) / Needs review`, listing needs-review items individually. Same preservation reporting rules as bootstrap STEP 5 (preserved hand-authored files; loud retirement of MTK-owned files only).
- **`## Verification`** section: plan script ran; no non-MTK file modified; every refreshed doc re-stamped; verify-claims ran per refreshed doc; report printed.

**`mtk-setup/SKILL.md` changes:**
- `argument-hint` gains `[--refresh [--dry-run]] [--check]`.
- Flag table rows: `--refresh` (refresh all generated rules and findings, drift-scoped), `--dry-run` (only with `--refresh`: print invalidation plan, write nothing), `--check` (CI staleness gate — run `scripts/setup-refresh-plan.sh --check`, print output, propagate exit code; writes nothing).
- Routing: `--check` → inline (script call, no target skill); `--refresh` → `.claude/skills/setup-refresh/SKILL.md` (pass `--dry-run` through).
- Combination rules: `--refresh` and `--check` are each mutually exclusive with `--audit`, `--merge`, `--update-guidelines`, and each other. `--dry-run` requires `--refresh`.
- Ambiguity guard: `--refresh` on a repo with no `.claude/tech-stack` → same warning pattern as `--audit` (suggest full bootstrap).
- Update Overview, When To Use, STEP 1 table, and Verification checklist accordingly.

## F2 — `scripts/setup-refresh-plan.sh` (staleness plan + `--check` gate)

New script. `bash scripts/setup-refresh-plan.sh [--json] [--check]`. Read-only (writes nothing, no side effects). `set -euo pipefail`, shellcheck-clean, executable.

Rows (one per artifact), each with `ARTIFACT | STATUS | REASON`:

1. `.claude/references/architecture-principles.md` — delegate to `bash scripts/audit-drift-check.sh <doc> --json`: drift → `stale` (reason: N claims touch changed files); no stamp → `unstamped`; absent → `missing`; else `fresh`.
2. `.claude/references/conventions.md` — same treatment.
3. `CLAUDE.md` — (a) footer version (`mtk-setup: vX.Y.Z`) vs installed version from `.claude/mtk-version.json` → version-drift = `stale`; (b) **dependency rescan**: extract top-level dependency names from the stack manifest (`package.json` deps/devDeps via python3 json, `*.csproj` PackageReference Include values via grep, `pyproject.toml` `[project] dependencies` names) and grep CLAUDE.md + `.claude/rules/*.md` for each; report names that appear in docs but are no longer in the manifest (removed deps still documented → `stale`). Missing manifest or missing CLAUDE.md → `unknown` / `missing`.
4. `.claude/detected-tools.json` — mtime older than 7 days → `stale` (matches the existing TTL convention); absent → `missing`.
5. `AGENTS.md` — regenerate to a temp file via `bash scripts/generate-agents-md.sh --force <tmpfile>` and `diff -q` against the real one; differs → `stale`; script or AGENTS.md absent → `unknown`.
6. Dead path references — run `bash scripts/verify-references.sh CLAUDE.md .claude/rules/*.md 2>/dev/null`; exit 3 (STALE lines) → row `path-references` `stale` with the count; script absent → skip row.
7. `.claude/setup-answers.json` — informational row: `present` / `absent (interview answers not persisted — next bootstrap will offer to capture them)`. Never affects exit code.

Output: default = fixed-width markdown table + one summary line (`N fresh, N stale, N missing, N unstamped/unknown`). `--json` = `{"generated":"<ISO8601>","artifacts":[{"artifact":...,"status":...,"reason":...}],"summary":{...}}`.

Exit codes: `0` always, **except** with `--check`: exit `1` if any row (other than the informational row 7) is `stale` or `missing`, printing a final line `run /mtk-setup --refresh to reconcile`. Exit `2` on usage error / not a git repo. Degrade per-row (`unknown`) when a helper script is missing rather than failing the whole run — this must work from a plugin install where cwd is the target repo.

**Test `tests/hooks/test-setup-refresh-plan.sh`** (match the style of `tests/hooks/test-query-code-index.sh`: temp-dir fixture repo, `declare -a FAILS`, cleanup trap): build a tiny git fixture repo with a stamped doc (stamp = fixture HEAD), CLAUDE.md with footer, package.json; assert (a) all-fresh → exit 0 with `--check`; (b) after committing a change to a file cited by the stamped doc → `--check` exits 1 and the plan marks the doc `stale`; (c) `--json` output parses with python3 and has the required keys; (d) removing a dependency from package.json that is still named in CLAUDE.md flips row 3 to `stale`.

## F3 — Regeneration diff-proposal contract (replaces union merge)

**New reference `.claude/references/regen-diff-contract.md`.** The single, shared contract for re-running generation over engineer-edited files. Content:

- Terms: `ancestor` = cached stock template in `.claude/.mtk-cache/v<prev>/`; `current` = on-disk file; `fresh` = newly generated template.
- Classification per file: `current == ancestor` → stock, safe to overwrite with `fresh`. `current != ancestor` → engineer-edited: **never overwrite, never `git merge-file --union`**.
- For engineer-edited files: compute the **MTK delta** (`diff ancestor fresh`) — this is what the toolkit wants to change, independent of engineer edits. Present each hunk as a proposed change **with a one-line reason** (which scan finding / rule motivated it). Ask via `AskUserQuestion`: "Apply all" / "Let me pick which" / "Skip all". Apply accepted hunks to `current`; a hunk that no longer applies cleanly (engineer rewrote that region) is NOT force-applied — it is listed under **Needs review** in the final report with the conflicting region quoted.
- The existing on-disk file is always the baseline; proposals are additive/subtractive diffs against it, each independently acceptable.
- Cache update rule: after the run, write `fresh` (the stock template, not the merged result) to `.claude/.mtk-cache/v<current>/` — only for files whose proposals were fully resolved (applied or explicitly skipped); files with needs-review hunks keep their old cache entry.
- Protected files (`manifest.protected`) are never proposed against — reported as `SKIP`.

**`setup-audit/SKILL.md`:** rewrite STEP -1 "Re-Run Merge Logic" to delegate to this contract (keep the classification table, Migration Path, and re-run summary; delete the `git merge-file --union` code block). The re-run summary's RESULT column values become `OVERWRITTEN (stock)` / `PROPOSED (N hunks: A applied, S skipped)` / `NEEDS REVIEW (N hunks)` / `SKIP (protected)`.

**`setup-bootstrap/SKILL.md`:** in "If CLAUDE.md ALREADY exists → Merge mode", replace the ad-hoc 5-step merge description with: classify per the contract; monolithic-CLAUDE.md migration (>200 lines) stays as-is; otherwise present the MTK delta per the contract instead of silently applying.

**Pressure test `tests/pressure-tests/setup-refresh-preservation.md`:** adversarial scenario set: (1) engineer asks refresh to "clean up stale docs" — tempts deletion of hand-authored nested CLAUDE.md and custom rules; (2) a fresh template drops a section the engineer hand-edited — tempts silent overwrite; (3) `--non-interactive`-style pressure to skip the AskUserQuestion and force-apply. Expected behavior: preservation policy holds, diffs proposed not forced, needs-review items reported, no deletion of non-MTK files. Follow the format of existing pressure tests in `tests/pressure-tests/`.

## F4 — Persisted interview (`.claude/setup-answers.json`)

**`setup-bootstrap/SKILL.md` STEP 2.5 changes:**

- Add question 6 — **Definition of done**: "What must be true before a change in this repo counts as done? (build + tests green, review passed, manual QA, deploy verification, docs updated …)". Answers feed CLAUDE.md verification guidance and `.claude/rules/project-specific.md`.
- After the interview (including when some questions are skipped), write `.claude/setup-answers.json` (committed, not gitignored; secret-scan gate applies before writing):

```json
{
  "version": 1,
  "captured": "<ISO8601 UTC>",
  "source": "engineer-interview",
  "answers": {
    "hard_nevers": [],
    "failure_modes": [],
    "invisible_conventions": [],
    "branch_pr_workflow": "",
    "compliance_constraints": [],
    "done_definition": []
  },
  "skipped": []
}
```

- **Re-run behavior:** if the file exists, load it, show a compact summary of prior answers, ask only questions whose keys are empty/missing or newly introduced, and offer "revise a previous answer" as one option. `--non-interactive` + existing file → reuse silently (print a notice). `--non-interactive` + no file → current behavior (skip, warn).
- **Evidence-anchor convention (generation rule):** every rule/claim sourced from an interview answer cites the steering file as its evidence anchor, e.g. `Evidence: engineer interview — .claude/setup-answers.json (hard_nevers)`. Because `scripts/verify-claims.sh` resolves real paths before content-grep, these anchors always hit — engineer-stated rules are never auto-downgraded by the verify pass. State this rationale explicitly in the skill text. No change to `verify-claims.sh`.
- `setup-refresh` STEP 5 and `setup-audit` load the file when present and treat its contents as authoritative human input (regeneration must not drop or reword rules sourced from it; if a fresh scan contradicts an interview answer, emit a `Needs review` item, do not silently pick a side).

## F5 — Resumable scan ledger (setup-audit + setup-bootstrap)

Both skills gain a **Scan ledger** step (audit: `STEP 0.9`, between STEP 0.5 and STEP 1; bootstrap: `STEP 1.5`, between STEP 1 and STEP 2) using the existing `scripts/workflow-artifact.sh`:

- Start: `bash scripts/workflow-artifact.sh init setup-audit --goal "<one-line>"` (or `setup-bootstrap`) → record the UUID.
- After each numbered STEP completes: `workflow-artifact.sh event <uuid> step_completed --data '{"step":"STEP 2","outputs":["<files written>"],"summary":"<one concrete sentence>"}'` and `set <uuid> current_step="STEP N"`. Summaries must be concrete ("scanned 214 files, 3 inconsistencies"), not vague.
- On completion: `set <uuid> status=completed`.
- **Resume:** at skill start, `workflow-artifact.sh list` — if an incomplete artifact of the same type exists and its `updated` timestamp is **< 24h old**, offer via `AskUserQuestion`: "Resume from <current_step>" / "Start fresh (abandon previous)" / "Cancel". Resume = skip completed steps, reload their `outputs` summaries instead of re-scanning. Older than 24h → `abandon` it automatically (with `--reason stale-24h`) and start fresh, printing a notice.
- **Context economy note** (bootstrap STEP 2 / audit STEP 1): for large repos (>1000 tracked source files), process scan categories in batches — write findings into the ledger event immediately after each category, keep only the 1–2 sentence summary in working context, then move on. The ledger, not the conversation, is the working memory.

## F6 — Verify-claims retry loop + Sync Impact stamp

**Retry loop** (`setup-audit` STEP 3.7; referenced from `setup-refresh` STEP 5): after the first `verify-claims.sh` run on a doc, read `.claude/.mtk-cache/weak-claims-<doc>.json`. For each downgraded claim, make **one** re-derivation attempt: re-locate correct evidence (fix the anchor: right path, right glob, right symbol) or, if the claim cannot be evidenced, delete the claim line outright. Rewrite the doc, run `verify-claims.sh` once more. Downgrades that survive the second pass are accepted and reported. Never loop more than once; never re-upgrade a tag without a resolving anchor.

**Sync Impact stamp:** on any re-run/refresh that regenerates a stamped doc, the `<!-- mtk-stamp -->` block gains three fields (fresh first-runs omit them):

```
<!-- mtk-stamp
audited-against: <sha>
audited-at: <ISO8601>
mtk-version: <version>
previous-stamp: <previous audited-against sha, or "none">
sections-changed: <comma-separated H2 titles, or "none">
claims-delta: +<added> ~<modified> -<removed>
-->
```

Compute `sections-changed`/`claims-delta` by diffing the regenerated doc against its previous on-disk version before writing. This is the audit trail for "what did the refresh actually change".

## Change manifest

- `.claude/skills/setup-refresh/SKILL.md` (new)
- `.claude/references/regen-diff-contract.md` (new)
- `scripts/setup-refresh-plan.sh` (new, executable)
- `tests/hooks/test-setup-refresh-plan.sh` (new, executable)
- `tests/pressure-tests/setup-refresh-preservation.md` (new)
- `.claude/skills/mtk-setup/SKILL.md`
- `.claude/skills/mtk/SKILL.md` (router help + setup-family redirect list the new flags)
- `.claude/skills/setup-audit/SKILL.md`
- `.claude/skills/setup-bootstrap/SKILL.md`
- `scripts/workflow-artifact.sh` (accept `setup-audit` / `setup-bootstrap` as ledger types)
- `scripts/generate-tool-configs.sh` (marker-refusal guard on every output, matching `generate-agents-md.sh`)
- `docs/specs/2026-07-02-v718-setup-refresh.md` (this file) + `.json`
- `.claude/manifest.json` (version 7.18.0, updated 2026-07-02, files list)
- `.claude-plugin/plugin.json` (version 7.18.0)
- `.claude-plugin/marketplace.json` (version, if it carries one)
- `CHANGELOG.md`, `README.md` (What's New), `AGENTS.md` (routing row for the new flags)
- `.claude/references.index` (rebuilt), `checksums.sha256` (regenerated last, S4.11)

## Constraints (binding on all implementers)

- Follow S2 skill anatomy; `setup-refresh` uses STEP structure (S2.2 phase-structured exemption). Frontmatter `name:` must equal the directory name (S2.3).
- Scripts: `set -euo pipefail`, executable bit, shellcheck-clean (S3.x). No secrets, no user-specific paths (C0.6).
- Never weaken the File Preservation Policy — refresh inherits it wholesale.
- Do not duplicate contract text across skills: the diff-proposal contract lives only in `regen-diff-contract.md`; skills reference it by path.
- Keep edits to the three existing skills surgical — do not reflow or rewrite untouched sections.
- Cross-file references must be exact: script names, flags, JSON keys, and step numbers as specified here.

## Verifiable acceptance criteria

- VC1: `bash scripts/validate-toolkit.sh` passes. (channel: script-output)
- VC2: `bash tests/hooks/test-setup-refresh-plan.sh` passes all assertions. (channel: test-run)
- VC3: `bash scripts/setup-refresh-plan.sh` on this repo prints the plan table and exits 0; `--check` exits 0 or 1 (not 2). (channel: script-output)
- VC4: `grep -c 'merge-file --union' .claude/skills/setup-audit/SKILL.md` returns 0. (channel: script-output)
- VC5: every path named in this spec's change manifest exists on disk (new files) or contains the specified additions (modified files). (channel: script-output)
- VC6: shellcheck on `scripts/setup-refresh-plan.sh` reports no errors. (channel: script-output)
