---
name: repo-health-assets
description: Canonical 9-asset checklist with the pass/partial/fail/na rubric for the repo-health scorecard
globs: ["scripts/repo-health-score.sh", ".claude/skills/repo-health/**"]
alwaysApply: false
type: reference
---

# Repo health — 9 assets

> Used by `scripts/repo-health-score.sh` and the `repo-health` skill. Each asset returns `pass` / `partial` / `fail` / `na`. There is no medal and no aggregate score: the output is the per-asset table plus `action_needed`, the assets at `partial` or `fail`. Counting specs, plans or rule files is deliberately not an asset — it rewards MTK paperwork, not readiness.

| # | Asset | Bucket |
|---|---|---|
| 1 | Instructions file (the resolved constitution) present and non-empty | AI Context |
| 2 | `architecture-principles.md` with ≥5 tagged principles | AI Context |
| 3 | Tech stack resolves to a known `tech-stack-*` skill | AI Context |
| 4 | `tasks/lessons.md` with ≥1 `## ` entry | AI Context |
| 5 | `manifest.json`, `plugin.json` and the marketplace entry carry one version | Toolkit (MTK repo only) |
| 6 | `bash scripts/validate-toolkit.sh` exits 0 | Toolkit (MTK repo only) |
| 7 | `README.md` present and non-empty | Onboarding |
| 8 | Build & test commands documented | Onboarding |
| 9 | `.gitignore` excludes `.claude/settings.local.json` (and `analytics.json` if present) | Onboarding |

## Rubric

1. **Instructions file.** Resolved by `scripts/resolve-constitution.sh`. pass: non-empty · partial: empty · fail: missing.
2. **Principles tagged.** Lines matching `[EXTRACTED|INFERRED:N.N|AMBIGUOUS|MINED:<kind>]`. pass: ≥5 · partial: 1–4 · fail: file missing or untagged (action: `/mtk-setup --audit`).
3. **Tech stack.** Resolved by `scripts/resolve-tech-stack.sh` (root file, subproject file or `tech-stack.map`). pass: resolves and `.claude/skills/tech-stack-<stack>/` exists · partial: resolves, no skill · fail: nothing resolves in a repo with `.claude/skills/` · na: no `.claude/skills/`.
4. **Lessons.** pass: ≥1 `## ` heading · partial: file without entries · fail: missing.
5. **Versions in sync** (C0.1). Scored only inside the toolkit checkout — `.claude/manifest.json`, `.claude-plugin/plugin.json` and `scripts/validate-toolkit.sh` all present. pass: all versions equal · fail: any differ · na: outside the toolkit.
6. **Validator passes.** Same toolkit detection. pass: exit 0 · fail: non-zero · na: outside the toolkit.
7. **README.** pass: non-empty · partial: empty · fail: missing.
8. **Build & test commands.** One of `dotnet build|test`, `npm test`, `npm run build`, `pytest`, `cargo test|build`, `go test|build`, `bash scripts/*.sh` in the resolved constitution, `AGENTS.md`, `CLAUDE.md`, `README.md` or a `tech-stack-*` skill. pass: found · fail: none.
9. **Gitignore.** pass: `.claude/settings.local.json` excluded, plus `.claude/analytics.json` when that file exists · fail: an exclusion or `.gitignore` missing.

Audit drift (`scripts/audit-drift-check.sh`) annotates asset 2 in the report; it never changes the asset's status.
