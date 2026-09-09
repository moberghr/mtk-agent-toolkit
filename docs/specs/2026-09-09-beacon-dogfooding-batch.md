# Batch: beacon dogfooding fixes (2026-09-09)

Source: field run of `/mtk implement` in the beacon repo (MCP SQL gates),
reported 2026-09-09. Scope note: **no new public contract; no architectural
change.** Findings are independent.

Approval: gate satisfied by the engineer's "all 5" in direct reply to this
exact five-item enumeration (same session, prior turn).

## Findings

| # | Finding | Files | Kind | Boundary |
|---|---|---|---|---|
| 1 | `constitution-digest.sh` matches only `- **C0.1**`-shaped rule ids, so a repo whose rules use `§0.x` (or any other id scheme) gets an empty Critical Rules section and no hint why | `scripts/constitution-digest.sh`, new `tests/hooks/test-constitution-digest.sh`, manifest | behavioral | — |
| 2 | `learnings.sh query` answers nothing forever in a repo whose lessons live only in `tasks/lessons.md` (seed runs only in setup-bootstrap). Lazy store-only seed on query; never rewrites the markdown from a read path | `scripts/learnings.sh`, `tests/hooks/test-learnings.sh`, `.claude/references/learnings-schema.md` | behavioral | — |
| 3 | `mtk-doctor` does not check that the files skills reference at runtime (security-checklist, testing-patterns, review-config, handoff schema, learnings/constitution scripts) resolve anywhere along the MTK resolution order; a run discovers them missing mid-phase instead | `scripts/mtk-doctor.sh`, new `tests/hooks/test-mtk-doctor-referenced-files.sh`, manifest | behavioral | — |
| 4 | No host-load signal anywhere: Phase 2.9 dispatches implementers onto an overloaded host, and killed-mid-batch recovery has no branch for a host-caused kill, so the respawn dies the same way. Add `scripts/host-load-probe.sh`, a pre-flight probe, and a host-overload branch in recovery | new `scripts/host-load-probe.sh`, new `tests/hooks/test-host-load-probe.sh`, `.claude/references/implement-preflight.md`, `.claude/skills/subagent-implementation/SKILL.md`, `CLAUDE.md` (env row), manifest | behavioral | — |
| 5 | Reviewer lanes each re-derive the call graph of touched symbols (~1/3 of reviewer tokens duplicated). Add a shared **Change map** section to the context pack and tell the lanes to read it | `scripts/build-context-pack.sh`, new `tests/hooks/test-build-context-pack.sh`, `.claude/references/implement-review-lanes.md`, manifest | behavioral | — |

| 6 | (carried over from the 2026-08-24 batch as F9; engineer said "fix it") `security-gate.sh` judged a segment by its first token, so a read-only grep behind `do`/`if`/`!`/`xargs`/`git`/`find -exec`/`bash -c`/`$(…)` was denied. Peel control words and wrappers, recurse into substitutions, treat read-only git subcommands and filter `sed`/`awk` as read-only | `hooks/security-gate.sh`, `tests/hooks/test-security-gate-falsepos.sh` | behavioral | security hook (read-only exemptions widened; every destructive check re-asserted) |

## Execution groups

- **A** — scripts with sandboxed tests (F1, F2, F5) — verified by their hook tests
- **B** — doctor + host-load probe (F3, F4) — verified by hook tests + validate-toolkit
- Post-batch: manifest entries, `validate-toolkit.sh`, pre-commit review
