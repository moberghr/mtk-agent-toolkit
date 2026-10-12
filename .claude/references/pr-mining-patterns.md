---
name: pr-mining-patterns
description: Heuristics, denylist, and output schema for mining recurring reviewer-feedback phrases from PRs
globs: ["scripts/pr-review-mine.sh", ".claude/skills/pr-review-mining/**", ".claude/skills/repo-health/**"]
alwaysApply: false
type: reference
---

# PR mining patterns

> Used by `scripts/pr-review-mine.sh` (called by `repo-health` and `setup-audit --mine-prs`).
> Pattern borrowed from `github.com/johnpapa/ai-ready` (PR review mining).

## What we mine

We mine **repeated reviewer-feedback phrases** from merged PR review threads — both PR-level review summaries and per-line review comments. We do not mine issue comments (status chatter, not actionable feedback).

A phrase becomes a candidate when:

1. It starts with an imperative-ish verb (see `IMPERATIVE_HINTS` in the script: add, remove, use, rename, prefer, avoid, …).
2. The 4-word prefix occurs in **≥2 distinct merged PRs** (not just twice in one ranty thread).
3. The phrase is not on the denylist below.

Output is always suggest-only and tagged `[MINED:feedback]`. Never auto-edits `architecture-principles.md`.

## Denylist

Common boilerplate that should never become a rule:

- `lgtm`
- `ship it`
- `thanks`
- `nit`
- `nice`
- `done`
- `fixed`
- `approved`
- `approve`
- `looks good`
- `good catch`
- `sgtm`
- `wfm`
- `same here`
- `+1`

Lines under this `## Denylist` heading are read by the mining script at runtime (until the next `## ` heading). Add words here to suppress them across the team.

## Output schema

**Markdown (default):**

```
## PR review mining

Scanned <N> merged PRs on '<default-branch>'.

Found <K> candidate `[MINED:feedback]` phrase(s). Suggest-only — review and edit before promoting into `architecture-principles.md`.

| Phrase | Occurrences | PRs |
|---|---:|---|
| <phrase> | <count> | #<n>, #<m> |
```

**JSON (`--json`):**

```json
{
  "status": "ok|skipped",
  "scanned_prs": 10,
  "phrases": [
    { "phrase": "add a regression test", "count": 4, "prs": [21, 22, 23] }
  ]
}
```

Status `skipped` is emitted with `phrases: []` when `gh` is missing or unauthenticated — mining is advisory and never blocks.

## Promotion workflow

1. Run `bash scripts/pr-review-mine.sh --prs 10` (default) or via `/mtk repo-health`.
2. Review each candidate phrase. Many will be too vague to become rules — discard them.
3. For phrases worth keeping, manually add a line to `.claude/references/architecture-principles.md` with the tag `[MINED:feedback]` and cite the PR numbers as evidence.
4. The mined principle is treated like any other audit principle for drift checks.

## Why suggest-only

Auto-promoting mined phrases would amplify reviewer biases and one-time disagreements into team-wide rules. Human review is the filter.
