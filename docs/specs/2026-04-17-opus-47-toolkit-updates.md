# Spec — Opus 4.7 Toolkit Modernization (v6.3.0)

Date: 2026-04-17
Slug: opus-47-toolkit-updates
Scope: **new-feature + internal-refactoring** (no breaking changes)

## Summary

Modernize MTK to exploit Opus 4.7 capabilities that were unavailable when earlier skills were written: parallel tool calls, isolated subagent contexts, deferred-tool loading, and prompt-caching friendliness. Ship alongside the 6.3.0 consolidation already in CHANGELOG.

## Success criteria

- Parallel ref loading documented and invoked in `implement` Phase 0 and `fix` load-context.
- Stage 2 review in `implement` runs `test-reviewer` and `architecture-reviewer` in parallel, not sequentially.
- Shared `ToolSearch` fallback snippet used by entry skills for deferred tools (`AskUserQuestion`, etc.).
- `fix` self-promotes to `/mtk implement` on scope escalation rather than stopping.
- `/mtk` route table sharpened; overlapping skill descriptions narrowed to unambiguous triggers.
- Cache-stable prefix convention documented in `writing-skills`; `setup-bootstrap` CLAUDE.md template reordered to match; three reviewer agents gain an invariant-first preface.
- New `toolkit-health` skill reads `.claude/analytics.json` and produces a usage-pulse report with actionable anomalies.
- `.claude/manifest.json` version bumped 6.2.0 → 6.3.0 (matches `plugin.json` and `marketplace.json`).
- `scripts/validate-toolkit.sh` passes.

## Architecture and design

Five logical batches, all additive to existing skills + one new skill. No file renames, no deletions, no changed public-skill contracts. Opus 4.7-specific frontmatter (`context: fork`, `effort: high/max`) already in use on some reviewer skills; extended to the three reviewer agents for consistency.

## Security and compliance impact

None. Additions are documentation, routing, and a read-only diagnostic skill. No change to auth, secrets handling, financial state surfaces, or audit trails. Security checklist is not touched.

## Change manifest

| Path | Action | Batch |
|---|---|---|
| `docs/parallelism-patterns.md` | create | A |
| `.claude/skills/implement/SKILL.md` | edit (Phase 0 parallel load, Phase 4 Stage 2 parallel) | A |
| `.claude/skills/fix/SKILL.md` | edit (parallel refs, self-escalation to /mtk implement) | A, B |
| `.claude/skills/context-engineering/SKILL.md` | edit (add "Parallel Loading" subsection; trim stale "~150 instructions" note) | A |
| `.claude/skills/mtk/SKILL.md` | edit (route table priority + ambiguity rules) | B |
| `.claude/skills/debugging-and-error-recovery/SKILL.md` | edit (description sharpen) | B |
| `.claude/skills/planning-and-task-breakdown/SKILL.md` | edit (description sharpen) | B |
| `.claude/skills/spec-driven-development/SKILL.md` | edit (description sharpen) | B |
| `.claude/skills/incremental-implementation/SKILL.md` | edit (description sharpen) | B |
| `.claude/skills/writing-skills/SKILL.md` | edit (add "Cache-Stable Prefix" section) | C |
| `.claude/skills/setup-bootstrap/SKILL.md` | edit (CLAUDE.md template ordering note) | C |
| `.claude/agents/compliance-reviewer.md` | edit (stable preface; add context: fork) | C |
| `.claude/agents/test-reviewer.md` | edit (stable preface; add context: fork) | C |
| `.claude/agents/architecture-reviewer.md` | edit (stable preface; add context: fork) | C |
| `.claude/skills/toolkit-health/SKILL.md` | create | D |
| `tests/pressure-tests/toolkit-health-pressure.md` | create | D |
| `.claude/manifest.json` | edit (version 6.2.0→6.3.0, date, register new files) | E |
| `CHANGELOG.md` | edit (append Opus 4.7 modernization subsection under 6.3.0) | E |
| `README.md` | edit only if skill count or command list in README changes | E |

## Test manifest

Toolkit has no unit tests. Verification is structural + behavioral:

- `bash scripts/validate-toolkit.sh` — must print "Toolkit validation passed."
- `tests/pressure-tests/toolkit-health-pressure.md` — three adversarial scenarios (stale analytics, corrupted JSON, empty first session).
- Manual behavior check: read the four modified entry skills cold and confirm parallel load / self-escalation / ToolSearch fallback guidance is explicit.

## Implementation batches

1. **Batch A** — parallelism patterns (parallelism-patterns.md, implement, fix, context-engineering).
2. **Batch B** — route & description sharpening + fix→implement self-escalation (mtk, fix, 4 workflow skills).
3. **Batch C** — cache-stable prefix convention (writing-skills, setup-bootstrap template, 3 reviewer agents).
4. **Batch D** — toolkit-health skill + pressure test + manifest entry.
5. **Batch E** — manifest version bump, CHANGELOG, README (if needed), validation.

## Risks and assumptions

- **Description sharpening in Batch B** can regress auto-routing. Mitigation: no description change to `/mtk` entry-point skills themselves; only to workflow skills (which are loaded, not routed-to by name).
- **Adding `context: fork` to reviewer agents** may duplicate isolation they already get when spawned from a skill with `context: fork`. Mitigation: explicit frontmatter is idempotent and makes behavior consistent whether called from skill or directly.
- **`toolkit-health` needs `.claude/analytics.json`** to be useful. Mitigation: skill gracefully reports "no data yet" when file missing or session count < 3.
- **Version bump** — `plugin.json` and `marketplace.json` are already at 6.3.0; `manifest.json` at 6.2.0 fails `validate-toolkit.sh`. This is a pre-existing drift we are fixing opportunistically.

## Open questions

None blocking. Engineer pre-approved autonomous execution.

## Out of scope (explicit)

- Removing "Common Rationalizations" tables from skills (separate cleanup, user asked only for additions).
- Softening `hooks/verify-completion` keyword-grep (separate cleanup).
- New analytics fields (skill-level invocation counts) — requires hook changes; deferred.
- Removing duplicated "MTK File Resolution" blocks — deferred (touches many files; want to land cleanly first).
