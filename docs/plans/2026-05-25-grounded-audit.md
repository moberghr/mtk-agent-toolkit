# Plan — grounded-audit (v7.8.0)

Spec: `docs/specs/2026-05-25-grounded-audit.md`.

## Sequence

Single incremental batch — no subagents, no multi-stage. ~10 files, tightly coupled, one verification gate at the end.

### Batch 1 — Primitives + content rules (DONE in this PR)

1. `scripts/verify-claims.sh` — grep-verify cited evidence; rewrite tags in place; emit weak-claims report.
2. `scripts/audit-drift-check.sh` — read `audited-against:` stamp; intersect changed × cited; report drift.
3. `.claude/references/audit-grounding.md` — rule tags, transient ban, partial-list policy, terminology denylist.
4. `.claude/skills/setup-audit/SKILL.md` — new STEP 3.6.5 (stamp + verify), updated STEP 4 summary.
5. `.claude/skills/setup-bootstrap/SKILL.md` — extended STEP 3.5a (verify pass + stamp + transient lint), CLAUDE.md footer stamp.
6. `.claude/skills/repo-health/SKILL.md` — new step 2b runs drift check across stamped docs.
7. `tests/pressure-tests/audit-grounding.md` — 8 adversarial scenarios.
8. `docs/specs/2026-05-25-grounded-audit.md` + `docs/plans/2026-05-25-grounded-audit.md`.

### Batch 2 — Manifest + validation

9. `.claude/manifest.json` — register the 5 new files (verify-claims.sh, audit-drift-check.sh, audit-grounding.md, pressure test, plan).
10. `bash scripts/validate-toolkit.sh` — must pass clean.

## Verification gate

- `bash scripts/validate-toolkit.sh` exits 0.
- `bash scripts/verify-claims.sh /tmp/test.md` on a synthetic doc with one fabricated path correctly downgrades the tag and emits the report (smoke-tested during dev).
- `bash scripts/audit-drift-check.sh` on a doc stamped with a 10-commit-old SHA correctly identifies modified files (smoke-tested during dev).

## Risks / unknowns

- **Bash 3.2 / macOS compat.** `mapfile` does not exist in bash 3.2; both scripts use `while read` loops instead. Smoke-tested on the dev machine; confirm in CI.
- **`python3` dependency.** `verify-claims.sh` uses `python3 -c 'import json'` for safe JSON encoding. Python 3 is on every supported dev box, but if the toolkit ever targets bare BusyBox, this would need replacing with `jq` or hand-rolled escaping.
- **False positives on `git grep`.** Bare-token grep across tracked files can hit unrelated content (a symbol name mentioned in a comment counts as a "hit"). Acceptable for v1 — the goal is "no claim without *some* hit", not perfect semantic verification. Tree-sitter symbol lookup (via existing repomap.json) is the v2 upgrade path.

## Out of scope (v7.9 candidates)

- Cross-doc consistency: CLAUDE.md says React 18, tech-stack file says React 19.
- AST-level claim verification beyond current repomap usage.
- Auto-fixing claims (we only downgrade — never rewrite for the engineer).
- A `/mtk doctor --audit` standalone command. For now, drift check rides inside `/mtk repo-health`.
