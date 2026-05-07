# Worclaude Borrow — 4 Spec Drafts

> Source: analysis of github.com/sefaertunc/Worclaude on 2026-04-29.
> Each spec stands alone — pick any subset to implement.

---

## Spec 1 — PreCompact Git Snapshot Hook

### Problem
Claude Code's auto-compaction can fire mid-edit. If uncommitted work is in a fragile state (half-applied refactor, generated files, unresolved merge), context loss + no checkpoint = recoverable only via reflog spelunking. MTK currently has zero defensive hooks against this.

### Proposal
Add `hooks/pre-compact-snapshot.sh` registered on the `PreCompact` event. On fire:
1. If `git rev-parse --is-inside-work-tree` fails → exit 0 silently.
2. If working tree is clean (`git diff --quiet && git diff --cached --quiet`) → exit 0.
3. Create a stash with message `mtk-precompact-<ISO8601>` using `git stash push --include-untracked --keep-index --quiet`.
4. Immediately `git stash apply --quiet` so the working tree is unchanged.
5. Append one line to `.claude/observability/precompact-snapshots.log`: timestamp + stash ref + branch.
6. Print one short stderr line: `[mtk] precompact snapshot saved → stash@{0}`.

### Recovery UX
Add `scripts/mtk-recover.sh` that lists snapshots from the log, lets the user pick one, runs `git stash apply <ref>`. Documented in CLAUDE.md gotchas section.

### Files touched
- `hooks/pre-compact-snapshot.sh` (new, ~40 lines)
- `hooks/hooks.json` (register hook)
- `scripts/mtk-recover.sh` (new, ~30 lines)
- `.claude/manifest.json` (add entries)
- `tests/pressure-tests/precompact-snapshot.md` (new)

### Non-goals
- Not a replacement for committing. Stash-only — no auto-branches, no auto-pushes.
- Does not run on manual `/compact` (only auto-compaction). Manual compaction is user-initiated; they own the choice.

### Edge cases
- Detached HEAD: still stash, log notes branch=DETACHED.
- Inside a rebase/merge: skip — refuse to interfere with in-flight git ops. Log "skipped: rebase/merge in progress".
- No git repo: silent exit.
- Stash command fails: log error, exit 0 (never block compaction).

### Verification
- Pressure test: dirty tree → trigger PreCompact → assert stash exists, working tree unchanged.
- Pressure test: clean tree → trigger PreCompact → assert no stash created.
- Pressure test: rebase in progress → trigger PreCompact → assert skipped, no error.

### Effort
**~2 hours.** One hook, one recovery script, one manifest update.

---

## Spec 2 — Personal vs Team Lessons Split

### Problem
`correction-capture` writes every captured rule to `tasks/lessons.md`, which is committed. This creates social friction:
- Personal preferences ("I like 4-space indents in this file") leak to the team.
- Engineers self-censor and skip capture rather than commit a personal nit.
- Team-wide rules that *should* be enforced get diluted by personal noise.

Worclaude solves this by splitting: `.claude/learnings/` (gitignored, personal) replayed on SessionStart; CLAUDE.md (committed, team).

### Proposal
Two-tier capture in `correction-capture`:

1. **`.claude/lessons/personal.md`** — gitignored. Default destination for new captures. Loaded on `SessionStart` via existing context hook.
2. **`tasks/lessons.md`** — committed. Existing file. New captures only go here when the engineer explicitly promotes a personal lesson.

Promotion flow: new entry-point skill `/promote-lesson` lists entries from `personal.md`, lets engineer pick one, moves it to `tasks/lessons.md` with optional rewording. Removes from personal.

`correction-capture` skill workflow updates:
- Step "where to write" → default personal, ask only if rule is clearly team-wide ("the team's auth pattern is X" → team; "I prefer Y" → personal).
- Heuristic: if the captured rule references "I", "my", "me" → personal. If it references "we", "the team", a specific architecture rule → ask.

### Files touched
- `.claude/skills/correction-capture/SKILL.md` (update workflow)
- `.claude/skills/promote-lesson/SKILL.md` (new entry-point skill)
- `hooks/session-start-context.sh` or equivalent (load `personal.md` if exists)
- `.gitignore` template (add `.claude/lessons/personal.md`)
- `.claude/manifest.json`
- `tests/pressure-tests/lessons-split.md` (new)

### Migration
Existing `tasks/lessons.md` content is untouched. New rule: new captures default to personal. Existing team lessons stay where they are. No breaking change for current users.

### Non-goals
- Not adding multi-user namespacing (one personal file per repo per machine, not per user).
- Not auto-promoting based on usage frequency. Promotion is always explicit.

### Verification
- Pressure test: ask Claude to capture a personal preference → assert it lands in `personal.md`, not `tasks/lessons.md`.
- Pressure test: ask Claude to capture an architectural rule → assert it asks before writing to team file.
- Pressure test: SessionStart with `personal.md` populated → assert content is in active context.

### Effort
**~4 hours.** Skill rewrite + new promote skill + hook update + tests. Lowest-risk change since it's additive.

---

## Spec 3 — `mtk doctor` Health Check

### Problem
`scripts/validate-toolkit.sh` checks structural integrity (manifest matches files, frontmatter present, hooks executable). It does not catch:
- Deprecated model IDs in agent frontmatter (e.g. `claude-3-opus` after deprecation).
- CLAUDE.md exceeding the 200-line budget that hurts session-start performance.
- Hook event names that aren't in Claude Code's current event list.
- Stale file hashes (manifest drift vs disk).
- Missing `.claude/lessons/personal.md` from `.gitignore`.
- Settings.json referencing non-existent hooks.

These rot silently. Engineers discover them when something breaks mid-session.

### Proposal
New script `scripts/mtk-doctor.sh` (or extend validate-toolkit). Categorized output:

```
CORE FILES
  ✓ .claude/manifest.json present
  ✓ CLAUDE.md present (142 lines, under 200 budget)
  ⚠ AGENTS.md missing — generate via /mtk-setup

COMPONENTS
  ✓ 35 skills registered, 35 found on disk
  ✗ Agent compliance-reviewer references deprecated model claude-3-opus

HOOKS
  ✓ All hooks executable
  ✓ All hook events valid for current Claude Code version
  ⚠ hooks.json registers Stop hook but script missing

INTEGRITY
  ✓ Manifest paths all exist
  ✗ .gitignore missing entry for .claude/lessons/personal.md
  ⚠ analytics.json older than 30 days — toolkit may be unused

Summary: 18 PASS, 3 WARN, 2 FAIL
```

Flags:
- `--json` → machine-readable output for CI dashboards.
- `--fix` → auto-fix safe items (gitignore additions, chmod +x).
- `--strict` → exit non-zero on WARN.

### Checks (initial set)
1. Core files present (manifest, plugin.json, CLAUDE.md, AGENTS.md, validate-toolkit.sh).
2. Manifest version matches plugin.json version (existing C0.1).
3. Every manifest path exists on disk (existing).
4. CLAUDE.md ≤ 200 lines.
5. No agent frontmatter references model IDs in deprecated list (hardcoded list, updated by maintainer).
6. All hook scripts in `hooks/hooks.json` exist and are executable.
7. All hook event names are in known event list.
8. `.gitignore` covers `.claude/settings.local.json`, `.claude/lessons/personal.md` (if spec 2 lands), `.claude/observability/` (if spec 1 lands).
9. `analytics.json` mtime — warn if >30 days old.
10. No skill directory missing required frontmatter fields (`name`, `description`).
11. Skill directory name matches frontmatter `name:` (existing C0.3).

### Files touched
- `scripts/mtk-doctor.sh` (new, ~250 lines)
- `.claude/skills/mtk-doctor/SKILL.md` (entry-point skill wrapping the script)
- `.claude/manifest.json`
- `tests/pressure-tests/mtk-doctor.md` (new)
- README.md update — add to skill routing table
- CI workflow — add `mtk doctor --strict` step

### Non-goals
- Not replacing `validate-toolkit.sh` — that runs faster and stays focused on structure. Doctor calls it as one of its checks.
- Not auto-fixing FAILs (only WARNs with `--fix`). Don't mask real problems.

### Verification
- Pressure test: corrupt manifest → doctor reports specific FAIL.
- Pressure test: deprecated model in agent → doctor flags it with the agent name.
- Pressure test: `--json` output is valid JSON parseable by `jq`.
- Pressure test: clean repo → all PASS, exit 0.

### Effort
**~1 day.** Script is the bulk; pressure tests + skill wrapper + README update.

---

## Spec 4 — Tiered Hook Profiles

### Problem
Current hook control is binary: `MTK_HOOKS_TIER2=0` disables skill-invoking hooks, on otherwise. Real usage has at least three modes:
- **CI** wants minimal noise, no interactive skill hints, no analytics writes.
- **Local daily work** wants standard MTK behavior.
- **Type-heavy or compliance-critical projects** want stricter checks (post-edit type check, post-edit security lint, etc.) that would be too noisy by default.

Today engineers either accept the default tier-2 behavior or disable it entirely. No middle ground for "more strict."

### Proposal
Single env var `MTK_HOOK_PROFILE` with three values:
- `minimal` — only essential context hooks (SessionStart context load). No skill hints, no analytics, no tier-2 invocations.
- `standard` (default) — current behavior. Tier-2 skill-invoking hooks active. Analytics writes active.
- `strict` — standard + extra PostToolUse checks. Initial set: TS/dotnet/python type check (auto-detected from tech stack) on every edit, with results surfaced to Claude.

Existing `MTK_HOOKS_TIER2=0` continues to work as a synonym for `minimal` (back-compat, deprecated note in docs).

Implementation: each hook script reads `MTK_HOOK_PROFILE` (default `standard`) at top and early-exits or adjusts behavior. Profile resolution lives in `hooks/lib/profile.sh`:
```bash
mtk_profile() {
  echo "${MTK_HOOK_PROFILE:-${MTK_HOOKS_TIER2:+standard}}"  # back-compat shim
}
mtk_profile_at_least() {  # usage: mtk_profile_at_least standard
  ...
}
```

Strict-mode type checks are auto-detected:
- `tech-stack` file says `dotnet` → run `dotnet build --no-restore -nologo` on the project containing the edited file.
- `python` → `mypy <file>` or `ruff check <file>` based on what's available.
- `typescript` → `tsc --noEmit` on the project.

Output goes to stderr in a parseable format Claude can react to.

### Files touched
- `hooks/lib/profile.sh` (new, ~50 lines)
- All existing tier-2 hooks — add profile gate (3-line change each, ~5 hooks)
- New strict-mode hook `hooks/post-edit-typecheck.sh`
- `hooks/hooks.json` — register strict hook conditionally? (Or always register, hook itself early-exits unless strict.)
- `.claude/manifest.json`
- README.md — document profiles
- CLAUDE.md template — note env var
- `tests/pressure-tests/hook-profiles.md` (new)

### Non-goals
- Not adding per-hook overrides (e.g. `MTK_DISABLE_SKILL_HINTS=1`). Coarse profiles only — finer control invites complexity that nobody asked for.
- Not running tests on every edit in strict mode. Type check only — fast feedback. Tests are too slow.

### Edge cases
- Profile name typo: log warning to stderr, default to `standard`.
- Strict mode but no recognized stack: skip type check, log "no type checker for stack", exit 0.
- Type check times out (>10s): kill, log timeout, exit 0 — never block edits.

### Verification
- Pressure test: `MTK_HOOK_PROFILE=minimal` + edit a file → no skill hints, no analytics write.
- Pressure test: `MTK_HOOK_PROFILE=strict` + edit a `.cs` file with type error → stderr contains build error.
- Pressure test: legacy `MTK_HOOKS_TIER2=0` still disables tier-2.
- Pressure test: invalid profile name → falls back to standard, warns once.

### Effort
**~6 hours.** Profile lib + hook gate retrofits + one new strict hook + tests.

---

## Effort summary

| Spec | Effort | Risk | Dependencies |
|---|---|---|---|
| 1. PreCompact snapshot | 2h | Low | None |
| 2. Personal/team lessons | 4h | Low (additive) | None |
| 3. mtk doctor | 1d | Low | Spec 1, 2 if landed (adds checks for them) |
| 4. Hook profiles | 6h | Medium (touches existing hooks) | None, but Spec 3 doctor would test profile detection |

**Suggested order if doing all four:** 1 → 2 → 4 → 3 (doctor last, picks up new checks from prior specs).
