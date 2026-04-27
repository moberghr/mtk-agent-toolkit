# Graphify Borrow — Implementation Plan

- **Date:** 2026-04-27
- **Slug:** graphify-borrow
- **Source:** comparative analysis of `safishamsi/graphify` vs MTK
- **Version target:** 7.2.0
- **Scope:** 5 independent improvements (skills + bash + JSON + new MCP server)

> **Non-goals.** No LLM-powered graph extraction, no multimedia ingest, no new
> per-assistant install matrix. MTK stays a workflow toolkit; graphify stays
> a knowledge-graph builder. We borrow patterns, not architecture.

---

## Scope

| # | Feature | Borrowed pattern | Where it lands |
|---|---------|------------------|----------------|
| 1 | `.mtkignore` for scan inputs | `.graphifyignore` | `scripts/repomap.sh`, `scripts/build-references-index.sh`, audit skills |
| 2 | EXTRACTED / INFERRED / AMBIGUOUS tagging | edge confidence tags | `setup-audit` skill, `architecture-principles.md` template, `spec-drift-detection` |
| 3 | Shrink-guard on protected artifacts | `to_json()` shrink refusal | new `hooks/lib/shrink-guard.sh`, wired into audit + lessons + references-index writes |
| 4 | MCP tools over MTK state | `python -m graphify.serve` | extend existing `mcp/` server (`mtk-context`) with read-only state tools |
| 5 | Post-commit auto-refresh | post-commit graph rebuild | new `hooks/git-hooks/post-commit-refresh.sh` + `scripts/refresh-derived.sh` |

## Success Criteria

| ID | Description | Verification |
|----|-------------|--------------|
| **F1 — `.mtkignore`** | | |
| SC1 | `.mtkignore` (gitignore syntax) at repo root, single source for all MTK scans | Manual: file exists with documented header |
| SC2 | `scripts/repomap.sh` and `scripts/build-references-index.sh` honor `.mtkignore` patterns; precedence is `.mtkignore` > `.gitignore` > built-in defaults | Run both with a fixture pattern; assert excluded paths absent from output |
| SC3 | `setup-audit` skill reads `.mtkignore` before walking the tree | Read skill body; trace the load step |
| SC4 | Missing `.mtkignore` is non-fatal; falls back to `.gitignore` + defaults | Delete file, re-run scripts; both succeed |
| **F2 — Confidence Tagging** | | |
| SC5 | `setup-audit` emits each principle tagged `[EXTRACTED]`, `[INFERRED:0.0–1.0]`, or `[AMBIGUOUS]` with one-line evidence pointer (file:line or commit) | Run audit on this repo; inspect output |
| SC6 | `.claude/references/architecture-principles.md` template documents the schema and includes a legend | Read file |
| SC7 | `spec-drift-detection` skill reads tags and treats `[INFERRED:<0.7]` and `[AMBIGUOUS]` as low-trust — flagged but not blocking | Pressure test in `tests/pressure-tests/spec-drift-tags.md` |
| SC8 | `setup-audit --merge` preserves tags across repos and downgrades confidence when sources disagree (`min(source_confidences)`) | Manual merge with conflicting fixtures |
| **F3 — Shrink-Guard** | | |
| SC9 | `hooks/lib/shrink-guard.sh` exposes `mtk_guarded_write <target> <new_content_path>` — refuses if new size < 50% of existing OR new line count < (existing - 20%) | Unit test in `tests/hooks/test-shrink-guard.sh` |
| SC10 | Override via `MTK_SHRINK_GUARD_OVERRIDE=1` (single write) with a stderr warning | Test asserts override path |
| SC11 | Wired into: `setup-audit` writing `architecture-principles.md`, `correction-capture` appending `tasks/lessons.md`, `scripts/build-references-index.sh` writing the index | Force a truncated input for each; assert refusal |
| SC12 | Refusal message names the target, old/new sizes, and the override env var | Inspect stderr in test |
| **F4 — MCP Tools** | | |
| SC13 | Existing `mcp/` server (`mtk-context`) gains 5 new read-only tools: `mtk_manifest`, `mtk_analytics`, `mtk_audit`, `mtk_references_index`, `mtk_active_stack` | `node dist/mtk-mcp-server.cjs` lists all 7 tools (2 existing + 5 new) |
| SC14 | Each new tool has a vitest test in `mcp/src/tools/__tests__/` covering happy path + missing-file fallback | `cd mcp && npm test` green |
| SC15 | New tools are read-only — no `fs.write*`, no `child_process`, no shell exec — enforced by lint rule in `mcp/src/tools/` | Grep gate added to `scripts/validate-toolkit.sh` |
| SC16 | `docs/integrations/mtk-mcp.md` updated with new tool reference (or created if absent); manifest unchanged for the server entry, validator passes | `bash scripts/validate-toolkit.sh` |
| SC16a | Each new tool has a documented one-line bash fallback (S3.12) so skills don't hard-depend on the MCP server | Read `docs/integrations/mtk-mcp.md`; each tool row has a `Bash fallback` column |
| SC16b | `hooks/session-start` triggers a rebuild when `mcp/src/**` is newer than `dist/mtk-mcp-server.cjs`, not only when `dist/` is missing | Touch a `mcp/src/tools/*.ts` file; start a new session; observe rebuild |
| **F5 — Post-commit Refresh** | | |
| SC17 | `hooks/git-hooks/post-commit-refresh.sh` reads changed files from `git diff-tree HEAD`; if any reference under `.claude/references/` changed, rebuild references index; if `.claude/manifest.json` changed, run validator | Commit a reference change; observe index rebuild |
| SC18 | `scripts/refresh-derived.sh <reason>` — single entry point that other hooks/skills call | Read script; trace callers |
| SC19 | Hook is opt-in via `git config core.hooksPath hooks/git-hooks` (documented in CLAUDE.md, not forced) | Manual: doc exists |
| SC20 | Refresh is silent on no-op, prints one-line summary on actual rebuild | Inspect output |
| **F6 — Release** | | |
| SC21 | Manifest + plugin.json bumped to 7.2.0 in same commit; CHANGELOG entry; validator passes | Validator |

---

## Batch 1 — F1: `.mtkignore` (scripts + skills)

**Files:** `.mtkignore` (new, root), `scripts/repomap.sh`, `scripts/build-references-index.sh`, `.claude/skills/setup-audit/SKILL.md`, `.claude/skills/setup-bootstrap/SKILL.md`, `.gitignore`

**Work:**

1.1 Create `.mtkignore` at repo root with header explaining purpose, gitignore-syntax note, precedence rule, and starter contents:
```
# .mtkignore — paths excluded from all MTK scans (audit, repomap, references index)
# Same syntax as .gitignore. This file IS committed.
# Precedence: .mtkignore > .gitignore > built-in defaults.

# Generated artifacts
graphify-out/
.playwright-mcp/
docs/translations/

# Skill invocation files (don't ingest our own instructions)
AGENTS.md
CLAUDE.md
GEMINI.md
```

1.2 `scripts/repomap.sh` — Add `mtk_load_ignore_patterns()` helper near top:
- Read `.mtkignore` if present, then `.gitignore`, then hardcoded defaults (`node_modules/`, `dist/`, `.git/`).
- Convert to a single `--exclude-from` temp file passed to the existing `find` / tree-sitter walk.
- Cache the temp file path in `$MTK_IGNORE_FILE`; clean up on `trap EXIT`.

1.3 `scripts/build-references-index.sh` — Same loader, same exclude wiring. Add a one-line "Excluded N patterns from .mtkignore" output when `.mtkignore` was used.

1.4 `setup-audit/SKILL.md` — Add a "Read ignore patterns" sub-step at the start of the corpus walk phase. Reference the precedence rule.

1.5 `setup-bootstrap/SKILL.md` — Add a "Generate `.mtkignore` if missing" step (uses the starter content above). Idempotent — never overwrite.

1.6 `.gitignore` — verify `.mtkignore` is NOT listed (it is committed). Add a comment near top documenting that `.mtkignore` is intentionally tracked.

**Checkpoint:**
- Run `bash scripts/repomap.sh` and `bash scripts/build-references-index.sh` on this repo.
- Add a fixture path to `.mtkignore`, re-run, confirm exclusion.
- Delete `.mtkignore`, re-run, confirm fallback to `.gitignore` works.

**SC covered:** SC1, SC2, SC3, SC4

---

## Batch 2 — F2: Confidence Tagging (skills + reference template)

**Files:** `.claude/skills/setup-audit/SKILL.md`, `.claude/skills/spec-drift-detection/SKILL.md`, `.claude/references/architecture-principles.md` (or template if not yet present), `tests/pressure-tests/spec-drift-tags.md` (new)

**Work:**

2.1 `setup-audit/SKILL.md` — In the principle-emission step, replace flat bullets with the tagged form:
```
- [EXTRACTED] All MediatR handlers live in `Application/<Slice>/`. Evidence: src/Application/Auth/LoginHandler.cs:1.
- [INFERRED:0.85] Vertical slices end at `Application` boundary. Evidence: 14 of 15 handlers follow this; one outlier in `Shared/`.
- [AMBIGUOUS] Whether DTOs belong to slice or shared kernel. Evidence: split conventions across slices.
```
Define the 0.0–1.0 confidence range: `>=0.9` strong, `0.7–0.89` reasonable, `<0.7` weak. Audit must include at least one evidence pointer per principle.

2.2 `architecture-principles.md` — Add a legend block near top documenting the three tags and confidence bands. If file is per-target-repo, update the template embedded in `setup-audit`.

2.3 `spec-drift-detection/SKILL.md` — Add a "Read tagged principles" step:
- Parse principles file; bucket by tag.
- When a spec or implementation contradicts an `[EXTRACTED]` principle → block with high severity.
- Contradicts `[INFERRED:>=0.7]` → flag at medium severity.
- Contradicts `[INFERRED:<0.7]` or `[AMBIGUOUS]` → note at low severity, do not block.

2.4 `setup-audit --merge` (multi-repo) — When merging principles from N repos:
- If all sources tag the same principle `[EXTRACTED]`, keep `[EXTRACTED]`.
- If sources disagree on tag, downgrade to `[INFERRED:min(confidences)]`.
- If sources contradict the principle itself, emit `[AMBIGUOUS]` with both source pointers.

2.5 `tests/pressure-tests/spec-drift-tags.md` — adversarial scenarios:
- Spec violates `[EXTRACTED]` rule → expect block.
- Spec violates `[INFERRED:0.6]` rule → expect note, no block.
- Spec violates `[AMBIGUOUS]` rule → expect surfacing without verdict.

**Checkpoint:**
- Re-run `setup-audit` on this repo; spot-check that emitted principles use tags with evidence pointers.
- Walk the pressure test scenarios manually; confirm severity gradation.

**SC covered:** SC5, SC6, SC7, SC8

---

## Batch 3 — F3: Shrink-Guard (hooks lib + integrations)

**Files:** `hooks/lib/shrink-guard.sh` (new), `hooks/lib/hook-io.sh` (helper export), `tests/hooks/test-shrink-guard.sh` (new), `scripts/build-references-index.sh`, `.claude/skills/setup-audit/SKILL.md`, `.claude/skills/correction-capture/SKILL.md`

**Work:**

3.1 `hooks/lib/shrink-guard.sh` — Implement `mtk_guarded_write target_path new_content_path`:
- If target does not exist → write through, return 0.
- Compare `wc -c` and `wc -l` of target vs new content.
- Refuse if new bytes < 50% existing OR new lines < (existing_lines * 0.8).
- On refusal: print to stderr `mtk-shrink-guard: refusing to shrink <target> from <X> to <Y> bytes / <A> to <B> lines. Set MTK_SHRINK_GUARD_OVERRIDE=1 to bypass.` and exit 1.
- If `MTK_SHRINK_GUARD_OVERRIDE=1` is set, write through and emit a stderr warning naming the target.

3.2 `hooks/lib/hook-io.sh` — `source` shrink-guard.sh so all hooks have access to `mtk_guarded_write`.

3.3 `tests/hooks/test-shrink-guard.sh` — fixture-based test:
- Create target file with 100 lines / 5000 bytes; attempt write of 30 lines → refused, exit 1, stderr matches pattern.
- Same with override env var → succeeds, warning printed.
- Write of 90 lines / 4900 bytes → allowed (within tolerance).
- New target (does not exist) → allowed.

3.4 Wire into call sites:
- `scripts/build-references-index.sh` — final write goes through `mtk_guarded_write`.
- `setup-audit/SKILL.md` — instruct skill to use `mtk_guarded_write` when writing `architecture-principles.md` (skill calls Bash with the helper).
- `correction-capture/SKILL.md` — append-only writes to `tasks/lessons.md` are immune (append never shrinks), but document the contract: lesson edits in place must use `mtk_guarded_write`.

**Checkpoint:** `bash tests/hooks/test-shrink-guard.sh` green. Manually corrupt a fixture audit input and re-run audit; confirm refusal.

**SC covered:** SC9, SC10, SC11, SC12

---

## Batch 4 — F4: Extend existing `mtk-context` MCP server

**Pre-existing context:** `mcp/` already ships a TypeScript stdio MCP server (`mtk-context` v0.1.0) bundled to `dist/mtk-mcp-server.cjs` via `scripts/build-mcp.sh`. Two tools exist today: `mtk_resolve_references`, `mtk_solution_structure`. We add 5 more — no new server, no new package.

**Files:** `mcp/src/tools/manifest.ts` (new), `mcp/src/tools/analytics.ts` (new), `mcp/src/tools/audit.ts` (new), `mcp/src/tools/references-index.ts` (new), `mcp/src/tools/active-stack.ts` (new), `mcp/src/tools/__tests__/state-tools.test.ts` (new), `mcp/src/index.ts` (register tools), `docs/integrations/mtk-mcp.md` (new or updated), `scripts/validate-toolkit.sh` (add lint gate), `hooks/session-start` (freshness check)

**Work:**

4.1 Create one tool module per state surface, each exporting `{name, description, inputSchema, handler}` matching the shape used by `solution-structure.ts`:
- `manifest.ts` → reads `.claude/manifest.json`, returns parsed JSON. Empty/missing → `{error: "manifest not found", path}`.
- `analytics.ts` → reads `.claude/analytics.json`. Same fallback shape.
- `audit.ts` → reads `.claude/references/architecture-principles.md`, parses tagged principles (depends on F2 schema) into `{principles: [{tag, confidence, statement, evidence}], raw}`. If F2 not landed yet, return `{raw, principles: []}`.
- `references-index.ts` → reads the JSON index produced by `scripts/build-references-index.sh`. Fallback shape on missing.
- `active-stack.ts` → reads `.claude/tech-stack` (one-line file). Returns `{stack: "<name>"}` or `{stack: null}`.

4.2 `mcp/src/index.ts` — import and register the 5 new tool definitions in the existing tools array. Bump server `version` from `0.1.0` to `0.2.0`.

4.3 `mcp/src/tools/__tests__/state-tools.test.ts` — vitest cases for each tool: file-present happy path against fixtures, file-missing fallback shape, malformed JSON for the JSON-shaped tools.

4.4 Read-only enforcement — add grep gate to `scripts/validate-toolkit.sh`:
```bash
if grep -rE "(fs\.(write|append|unlink|rm|mkdir)|child_process|execSync)" mcp/src/tools/ ; then
  echo "FAIL: write API or shell exec detected in mcp/src/tools/" >&2
  exit 1
fi
```

4.5 `docs/integrations/mtk-mcp.md` — create or update with the full tool list (2 existing + 5 new), example `.mcp.json` snippet, and the read-only contract.

4.6 Rebuild check: `bash scripts/build-mcp.sh` succeeds, `dist/mtk-mcp-server.cjs` updated, `node dist/mtk-mcp-server.cjs` answers `tools/list` with 7 entries. `dist/` stays gitignored — Batch 6 does not commit the binary.

4.7 `hooks/session-start` — extend the existing rebuild trigger (currently fires only when `dist/` is missing) to also fire when any `mcp/src/**` file is newer than `dist/mtk-mcp-server.cjs`. Stay silent + non-blocking on failure (existing convention). Concretely:
```bash
needs_build=0
if [ ! -f "$PLUGIN_ROOT/dist/mtk-mcp-server.cjs" ]; then
  needs_build=1
elif [ -n "$(find "$PLUGIN_ROOT/mcp/src" -newer "$PLUGIN_ROOT/dist/mtk-mcp-server.cjs" -print -quit 2>/dev/null)" ]; then
  needs_build=1
fi
if [ "$needs_build" = "1" ] && [ -d "$PLUGIN_ROOT/mcp" ] && command -v node >/dev/null 2>&1; then
  bash "$PLUGIN_ROOT/scripts/build-mcp.sh" --quiet 2>/dev/null || true
fi
```

4.8 Bash fallbacks (S3.12 compliance) — document one-line shell equivalent for each new tool in `docs/integrations/mtk-mcp.md`:
- `mtk_manifest` → `cat .claude/manifest.json`
- `mtk_analytics` → `cat .claude/analytics.json`
- `mtk_audit` → `cat .claude/references/architecture-principles.md`
- `mtk_references_index` → `cat .claude/references/_index.json` (or whichever path Batch 1 defines)
- `mtk_active_stack` → `cat .claude/tech-stack`

Skills that consume these surfaces should call the MCP tool when available and fall through to the cat command otherwise. Document the pattern, do not enforce in code.

**Checkpoint:** `cd mcp && npm test` green. `bash scripts/build-mcp.sh` rebuilds cleanly. `bash scripts/validate-toolkit.sh` passes including the new grep gate. Touch a `mcp/src/tools/*.ts` file, run `hooks/session-start`, confirm rebuild fires.

**SC covered:** SC13, SC14, SC15, SC16

---

## Batch 5 — F5: Post-commit Auto-refresh (git hook + script)

**Files:** `hooks/git-hooks/post-commit-refresh.sh` (new), `scripts/refresh-derived.sh` (new), `CLAUDE.md` (one-line opt-in note)

**Work:**

5.1 `scripts/refresh-derived.sh <reason>` — single entry:
- Re-run `scripts/build-references-index.sh` if reason matches `references`.
- Re-run `bash scripts/validate-toolkit.sh --quick` if reason matches `manifest`.
- Print a one-line summary `mtk-refresh: rebuilt <artifact> (<reason>)`.
- No-op silent path if no matches.

5.2 `hooks/git-hooks/post-commit-refresh.sh`:
- `git diff-tree --no-commit-id --name-only -r HEAD` to list changed files in last commit.
- If any path under `.claude/references/` → call `scripts/refresh-derived.sh references`.
- If `.claude/manifest.json` changed → call `scripts/refresh-derived.sh manifest`.
- Exit 0 always — never block a commit.

5.3 `chmod +x` on both files. Verify `set -euo pipefail` headers.

5.4 `CLAUDE.md` — append a one-paragraph "Optional: enable post-commit refresh" section pointing to `git config core.hooksPath hooks/git-hooks`. Honor C0.7: append-only, do not rewrite.

**Checkpoint:**
- Enable the hook locally (`git config core.hooksPath hooks/git-hooks`).
- Touch a reference file, commit, observe rebuild output.
- Touch unrelated file, commit, observe silent no-op.

**SC covered:** SC17, SC18, SC19, SC20

---

## Batch 6 — Manifest + Version Bump

**Files:** `.claude/manifest.json`, `.claude-plugin/plugin.json`, `CHANGELOG.md`

**Work:**

6.1 `manifest.json` — entries for: `.mtkignore`, `hooks/lib/shrink-guard.sh`, `tests/hooks/test-shrink-guard.sh`, the 5 new `mcp/src/tools/*.ts` files + their test, `docs/integrations/mtk-mcp.md`, `hooks/git-hooks/post-commit-refresh.sh`, `scripts/refresh-derived.sh`, `tests/pressure-tests/spec-drift-tags.md`. Bump `version` to `7.2.0`, `updated` to `2026-04-27`.

6.2 `plugin.json` — bump to `7.2.0` (C0.1 sync).

6.3 `CHANGELOG.md` — `## [7.2.0] - 2026-04-27` with five bullets, one per feature, each linking the SC range.

**Checkpoint:** `bash scripts/validate-toolkit.sh` → "Toolkit validation passed".

**SC covered:** SC21

---

## Batch Sequence Rationale

Batches 1–5 are independent (different files, no shared contracts). Suggested order:
1. F3 shrink-guard first (it's a primitive other batches use defensively).
2. F1 `.mtkignore` next (touches scripts also used by F2 audit).
3. F2 confidence tagging (depends on a stable audit walker from F1).
4. F5 post-commit refresh (depends on stable scripts from F1).
5. F4 MCP server last (fully isolated; can ship independently).
6. Batch 6 release.

## Behavioral Diff

**Before**
- Audit emits flat principles with no evidence or confidence — drift detection treats all as equal.
- Reference index, lessons, audit can be silently truncated by a buggy regenerator.
- No machine-readable view of MTK state — agents must read markdown.
- Reference index goes stale until next manual run.
- Each scan re-rolls its own ignore logic.

**After**
- Principles carry tags + evidence; drift detection grades severity by tag.
- Critical artifacts refuse to shrink without explicit override.
- Read-only MCP server exposes manifest, analytics, audit, references, active stack.
- Post-commit hook keeps derived artifacts in sync (opt-in).
- Single `.mtkignore` controls all scan inputs.

## Post-Implementation Review

- [ ] Phase 4 Stage 1 — compliance-reviewer
- [ ] Phase 4 Stage 2 — architecture-reviewer + test-reviewer (parallel, focused on F3 + F4)
- [ ] Phase 6 — code-simplification (especially `scripts/mtk-mcp/server.js`)
- [ ] Phase 7 — capture learnings; update `tasks/lessons.md`

## Open Questions

- **F2 evidence format** — file:line is precise for code, but architecture principles often emerge from patterns across many files. Allow `pattern: "**/Application/*Handler.cs (14 hits)"` as alternate evidence form?
- **F4 server version bump** — bumping `mcp/package.json` from `0.1.0` to `0.2.0` is a tool-set change, not a breaking one. `dist/` is gitignored (verified) and rebuilt just-in-time by `hooks/session-start`. The 4.7 freshness check (mtime against `mcp/src/**`) covers existing users with stale bundles. Resolved.
- **F5 opt-in vs opt-out** — currently opt-in via `core.hooksPath`. If team adoption is the goal, consider auto-enabling via `setup-bootstrap` with a confirmation prompt.
