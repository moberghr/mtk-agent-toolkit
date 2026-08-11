# Batch: mixed-stack field feedback (2026-08-11)

**Scope note:** no new public contract; no architectural change. F2 escalated out
(see below) precisely because it *would* change a public contract.

**Source:** field run of `batch-fix` in a polyglot repo (.NET root + `ServiceDeskWeb/`
Vite SPA subtree with its own `CLAUDE.md` and `docs/specs/`). Five friction points
reported; four are wiring gaps against mechanisms that already exist.

**Working-tree baseline (pre-existing dirty, NOT owned by this batch):**
22 modified + 10 untracked files from the Wave 1 competitive-borrows work —
`.claude/agents/*`, `.claude/rules/*`, `.claude/manifest.json`, `.claude/settings.json`,
`hooks/hooks.json`, `hooks/lib/hook-io.sh`, `scripts/{build-rule-index,poison-lint,run-benchmarks}.sh`,
`tasks/lessons.md`, `.claude/skills/{code-review-and-quality,implement}/SKILL.md`,
plus the untracked Wave 1 spec/plan/benchmarks/docs files.
Review in Phase 5 is scoped to this batch's own files, excluding the above.
Overlap to watch: `.claude/manifest.json` (this batch appends entries) and
`.claude/skills/implement/SKILL.md` (read-only here — it is the wording *source*).

---

## Findings

### 1. F1a — six call sites still inline the root-only tech-stack read
*Behavioral. No boundary crossed.*

`scripts/resolve-tech-stack.sh` already implements closest-declaration-wins
resolution (`$MTK_STACK` → nearest subproject `.claude/tech-stack` → root
`.claude/tech-stack.map` globs → root scalar), but only `repomap.sh` and
`check-prerequisites.sh` call it. These six still do `tr -d '[:space:]' < .claude/tech-stack`:

- `hooks/api-compat-check.sh:15`
- `hooks/pre-commit-linters.sh:76`
- `hooks/parse-build-diagnostics.sh:44`
- `scripts/generate-tool-configs.sh:41`
- `scripts/generate-agents-md.sh:18`
- `scripts/repo-health-score.sh:60`

Consequence in the field: a Vite SPA subtree gets `dotnet` linters and build-diagnostic
parsers. Fix: route each through the resolver, preserving existing `--stack` overrides.

### 2. F1b — seven skills instruct the root-only read in Phase 1
*Mechanical (documentation).*

`.claude/skills/implement/SKILL.md:56` already carries the correct polyglot wording
(resolve via the script, pass a representative `change_manifest` path for subtree work).
These peers still say "read `.claude/tech-stack`":

- `fix/SKILL.md:113`
- `batch-fix/SKILL.md:124`
- `code-review-and-quality/SKILL.md:62`
- `verification-before-completion/SKILL.md:100`
- `research-context/SKILL.md:53`
- `setup-refresh/SKILL.md:43`
- `claude-md-audit/SKILL.md:85`

Out of scope: the "Always project-relative (never prefixed)" boilerplate at line ~18
of many skills — that governs path *prefixing*, not stack resolution, and is correct.

### 3. F1c — nothing flags a pinned-stack vs. touched-file mismatch
*Behavioral. Additive flag on an existing internal script.*

The field report overrode `dotnet` → `typescript` by hand; MTK was silent. Add an
additive `--check <path>...` mode to `resolve-tech-stack.sh` that compares the
resolved stack against the file extensions actually being touched and emits an
advisory warning on mismatch. Advisory only — never blocks. Surfaced by the F1b
skill wording.

### 4. F2 — `docs/specs/` artifact root is repo-root-only — **ESCALATED**
*Would change a public contract. Not applied in this batch.*

The proposal (closest-declaration-wins for the artifact root, so an authoritative
subtree `docs/specs/` wins) is sound, but `docs/specs` is load-bearing for **26+
consumers**: 14 scripts/hooks — including `scope-guard.sh` (3 sites),
`spec-approval-trigger.sh` (3), `spec-archive.sh`, `post-compact.sh`,
`verify-behavioral-diff.sh`, `session-analytics.sh` — and 12 skills
(`spec-driven-development` alone has 20 sites).

Moving the root without moving every consumer in lockstep makes `scope-guard.sh`
silently fail to locate the spec — the same silently-off failure class as open item
X1 in `tasks/todo.md`. That is architectural re-planning across a contract surface,
which the Scope Guard routes to `implement`.

### 5. F3 — analytics written to a cwd-relative path
*Behavioral. Small.*

`hooks/session-analytics.sh:26` is `ANALYTICS=".claude/analytics.json"` — bare
cwd-relative, so any subtree cwd mints a second analytics file. Line 118's
`find docs/specs` shares the defect. `scripts/analytics-report.sh:7` too.
`hooks/lib/hook-io.sh:16` already exports `mtk_repo_root()`, and
`hooks/lib/skill-queue.sh:120` already uses that pattern — this hook just doesn't.

### 6. F4+F5 — batch-fix's own budget and gate rules
*Mechanical (documentation). Single file: `.claude/skills/batch-fix/SKILL.md`.*

- **F4** — the ~5-finding budget note (line 118) offers only "checkpoint with
  `handoff`". No grouping or staged-gate mechanism, so the field run invented A→D
  grouping itself. Add grouping with per-group checkpoints.
- **F5** — the Phase 3 "gate satisfied by explicit directive" clause covers an
  explicit go-ahead on the exact enumerated list, and the red-flag table covers
  *new* findings re-opening it. Neither covers (a) the enumeration changing
  **materially after** the directive — findings escalated, narrowed, or merged — nor
  (b) dirty-tree overlap, which is outside the model entirely.

Merged into one finding because both edit the same file and the same gate/budget
semantics; the engineer approved them as one unit.

### 7. F1d — `tech-stack.map` never matched under a symlinked root — **DISCOVERED MID-RUN**
*Behavioral. Pre-existing bug in `scripts/resolve-tech-stack.sh`, found by the F1c test.*

Not in the approved list — surfaced by the new regression test, which failed
first on the `tech-stack.map` assertion.

`target_dir` was built with a logical `pwd` while `repo_root` comes from
`git rev-parse --show-toplevel`, which always reports the **physical** path. The
two disagree whenever the repo root is reached through a symlink (`/var` →
`/private/var` on macOS, symlinked home or checkout dirs). The
`${target_dir#"$root"/}` strip then silently no-ops, `rel` stays absolute, and
**every `.claude/tech-stack.map` glob fails to match** — the map degrades to
"root default" with no diagnostic.

Same silent-failure class as open item X1. Fixed by resolving with `pwd -P`.

**Why it was folded in rather than deferred:** F1a routes six more consumers
through this resolver and `tech-stack.map` is one of the two mechanisms the
whole mixed-stack fix depends on. Shipping F1a on a silently-broken map would
have spread the defect to every new caller. It is a bug fix in a file already
in this batch's scope — no new slice, contract, or re-planning.

### 8. Stale `--stack` help text in two hooks
*Mechanical. Consequence of finding 1.*

`hooks/pre-commit-linters.sh` and `hooks/parse-build-diagnostics.sh` both
documented `--stack` as overriding "reads .claude/tech-stack". Updated to
describe the resolver order actually used now.

---

## Out of scope — reported, not actioned

**Open item X1 has a second confirmed symptom and a reproducer.**
`tests/hooks/test-spec-approval-trigger.sh` fails when run with CWD set to the
lowercase `/Users/<user>/dev/claude-helpers` alias and passes from
`/Users/<user>/Dev/claude-helpers`. `hooks/spec-approval-trigger.sh` receives the
lowercase-spelled path, its case-sensitive path match misses, and it exits 0
without queueing — the tier-2 trigger is silently off. Verified: the test passes
at clean HEAD and in every single-file worktree permutation; only the CWD
spelling changes the result. This is X1's documented failure mode, now
reproducible in one line, and it is the likely explanation for the pre-existing
benchmark reds. Not fixed here — X1 is flagged in `tasks/todo.md` as needing an
engineer decision.

---

## Completion bar (not findings — the repo's own rules)

- **C0.2** every new/changed file registered in `.claude/manifest.json`
- **C0.8** `bash scripts/validate-toolkit.sh` prints "Toolkit validation passed"
