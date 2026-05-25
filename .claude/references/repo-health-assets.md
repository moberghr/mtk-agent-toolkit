---
name: repo-health-assets
description: Canonical 12-asset checklist with pass/partial/fail rubric and medal thresholds for the repo-health scorecard
globs: ["scripts/repo-health-score.sh", ".claude/skills/repo-health/**"]
alwaysApply: false
type: reference
---

# Repo health — 12 assets

> Used by `scripts/repo-health-score.sh` and the `repo-health` skill. Pattern borrowed from `github.com/johnpapa/ai-ready` (bounded scorecard + medal).
>
> Every asset returns one of `pass` / `partial` / `fail` / `na`. The medal is computed against `pass` count over `12 − na`.

## Buckets

| # | Asset | Bucket |
|---|---|---|
| 1 | CLAUDE.md present and non-empty | AI Context |
| 2 | Architecture principles file with ≥5 tagged principles | AI Context |
| 3 | `.claude/tech-stack` pinned to a known tech-stack-* skill | AI Context |
| 4 | `tasks/lessons.md` with ≥1 `## ` lesson entry | AI Context |
| 5 | `docs/specs/` with ≥1 spec in the last 90 days | Dev Workflow |
| 6 | `docs/plans/` with ≥1 plan in the last 90 days | Dev Workflow |
| 7 | `.claude/manifest.json` and `.claude-plugin/plugin.json` versions in sync | Dev Workflow |
| 8 | `bash scripts/validate-toolkit.sh` exits 0 | Dev Workflow |
| 9 | `README.md` present and non-empty | Onboarding |
| 10 | Build & test commands documented (CLAUDE.md / README / tech-stack skill) | Onboarding |
| 11 | `.claude/rules/` with ≥2 rule files | Onboarding |
| 12 | `.gitignore` excludes `.claude/settings.local.json` (and analytics.json if present) | Onboarding |

## Rubric

### 1. CLAUDE.md present

- **pass** — file exists and has any content.
- **partial** — file exists but is empty.
- **fail** — file missing.

### 2. Architecture principles tagged

Pattern `[EXTRACTED|INFERRED:N.N|AMBIGUOUS|MINED:feedback]` per line.

- **pass** — ≥5 tagged principles.
- **partial** — 1–4 tagged principles.
- **fail** — file missing OR no tags.

### 3. Tech stack pinned

- **pass** — `.claude/tech-stack` exists and contains a single word matching `.claude/skills/tech-stack-<word>/`.
- **partial** — file exists with a value but no matching skill.
- **fail** — file empty OR missing in an MTK repo.
- **na** — repo has no `.claude/skills/` at all.

### 4. Lessons captured

- **pass** — ≥1 `## ` heading in `tasks/lessons.md`.
- **partial** — file exists but no `## ` headings.
- **fail** — file missing.

### 5. Recent specs

`docs/specs/*.md` modified within 90 days.

- **pass** — ≥1 recent spec.
- **partial** — directory has specs but none recent.
- **fail** — directory missing or empty.

### 6. Recent plans

Same as 5, against `docs/plans/`.

### 7. Manifest versions in sync

- **pass** — `manifest.json.version == plugin.json.version`.
- **fail** — versions differ.
- **na** — neither file exists (non-MTK repo).

### 8. Toolkit validator passes

- **pass** — `bash scripts/validate-toolkit.sh` exits 0.
- **partial** — file exists but not executable.
- **fail** — validator exits non-zero.
- **na** — validator script missing (non-MTK repo).

### 9. README present

- **pass** — `README.md` exists and non-empty.
- **partial** — file exists but empty.
- **fail** — missing.

### 10. Build & test commands documented

Greps for one of: `dotnet build`, `dotnet test`, `npm test`, `npm run build`, `pytest`, `cargo test`, `cargo build`, `go test`, `go build`, `bash scripts/*.sh`.

- **pass** — found in any of `CLAUDE.md`, `README.md`, `.claude/skills/tech-stack-*/SKILL.md`.
- **fail** — no matches anywhere.

### 11. Rules documented

- **pass** — `.claude/rules/` with ≥2 markdown files.
- **partial** — directory exists with 1 file.
- **fail** — directory empty.
- **na** — directory missing in non-MTK repo.

### 12. Sensitive files gitignored

- **pass** — `.gitignore` excludes `.claude/settings.local.json` AND (`.claude/analytics.json` if the file exists).
- **fail** — any missing exclusion OR `.gitignore` missing.

## Medal thresholds

Based on the count of `pass` assets:

| Threshold | Medal |
|---|---|
| ≥10 pass | 🏆 platinum |
| ≥8 pass | 🥇 gold |
| ≥6 pass | 🥈 silver |
| ≥4 pass | 🥉 bronze |
| <4 pass | (no medal) |

`partial` does not count toward the medal — it is a warning signal only. `na` assets are excluded from the denominator (shown as `12 − na`).

## When to re-run

- Weekly / on demand via `/mtk repo-health`.
- After a release (manifest version bump → asset 7).
- After `/mtk-setup --audit` re-runs (asset 2 should jump).
- Before promoting a `[MINED:feedback]` candidate to a real principle (sanity-check asset 2 first).
