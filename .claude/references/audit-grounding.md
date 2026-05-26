---
name: audit-grounding
description: Rules generators must follow when emitting CLAUDE.md and architecture-principles.md — rule tags, transient ban, partial-list policy, terminology denylist, SHA stamp
globs: [".claude/skills/setup-audit/**", ".claude/skills/setup-bootstrap/**", "scripts/verify-claims.sh", "scripts/audit-drift-check.sh"]
alwaysApply: false
---

# Audit Grounding — rules generators must follow

> Canonical rules for `setup-audit` and `setup-bootstrap` when emitting `CLAUDE.md`, `architecture-principles.md`, and `conventions.md`. Spec: `docs/specs/2026-05-25-grounded-audit.md`.
>
> These rules exist because a real client run produced ~20 factual errors that a single grep would have falsified. Each rule below maps to a failure mode observed in that run.

---

## 1. Rule confidence tags

Every prescriptive rule line in generated CLAUDE.md and architecture-principles.md MUST carry exactly one tag:

- `[ENFORCED]` — the rule is observed in **every** sampled file (zero exceptions). Reviewers refuse PRs that violate it.
- `[CONVENTION]` — the rule is observed in the **majority** of sampled files (≥80%) but has exceptions. Reviewers match the rule when writing new code; existing exceptions are not bugs.
- `[ASPIRATIONAL]` — the rule represents the team's stated intent but is **not** consistently reflected in code. Reviewers do not block on this; they suggest.

**Why three tags:** without them, AI cannot tell whether to refuse a `../../` import or match the existing pattern. The audur run committed "Never write `../../`" as a rule despite the codebase doing it everywhere — the result is an AI that pretends to enforce a rule the team has implicitly abandoned.

**Evidence requirement.** Every tagged line MUST cite at least one evidence anchor — a backticked path, path:line, glob with hit count, or symbol name. Untagged or unevidenced rules are quarantined into a `## Untagged (review)` section rather than left in the main body.

Distinct from principle-level S1.15 tags (`[EXTRACTED]/[INFERRED:N]/[AMBIGUOUS]`), which describe *what the codebase does*. Rule tags describe *what reviewers should do about it*.

## 2. Transient state ban

Generators MUST NOT bake transient state into rules. Specifically:

| Transient | Example to reject | Why |
|---|---|---|
| Branch name | `Active branch: fix/ltv-slider-bounds-and-typo` | Stale the day it merges |
| PR number | `See PR #1290 for context` | PR numbers shift; the rule outlives the PR |
| Date other than audit date | `As of 2026-04-15, prefer X` | Reader can't tell if still current |
| Author email / username | `Mirko prefers Result<T>` | Personal preference ≠ team rule |
| Sprint / milestone label | `For Q2 2026, freeze X` | Rolls off; the rule lives longer |

Detection pattern (verify-claims lint pass):

```
branches:  ^(feat|fix|chore|docs|refactor)/
PRs:       #\d+
dates:     \b(20[2-9][0-9])-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])\b   # except audit date
emails:    [A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}
```

Detected lines are dropped from the main body with a warning printed; engineer reviews and re-adds with a stable phrasing if needed.

## 3. No partial lists

When a rule cites an enumeration, the generator MUST either:

- **Enumerate fully** — list every item, or
- **Link the source** — emit `see <path>` with no inline list at all.

Partial lists steer downstream AI to the wrong subset. The audur run listed 6 of 12 localStorage keys; downstream code generation then treated those 6 as the canonical surface and missed the other 6.

Detection pattern (heuristic):

```
(e\.g\.,? \w+(, \w+){2,})           # "e.g., a, b, c, d" without closer
(including [A-Z]\w+(, [A-Z]\w+){2,}) # "including Foo, Bar, Baz" without closer
```

When detected AND the line lacks `etc. — see <path>` AND lacks a known full-list marker (`(all N)`, `(complete list)`), the rule is downgraded to `[ASPIRATIONAL]` and a footnote requests human review.

## 4. Terminology denylist

Common confusions in generated audits. Generators flag these for review; they are NOT auto-rewritten because the right term depends on context.

| Wrong | Right | Disambiguation |
|---|---|---|
| "path alias" | "TypeScript `baseUrl` + `paths`" or "path mapping" | Path aliases are a Webpack/Vite/Next concept; TS `paths` configures the compiler. Don't conflate. |
| "HTML" (in React context) | "JSX" | A `.tsx` file contains JSX, not HTML. They look similar; they aren't. |
| "enum" (in TS for object literals) | "typed object" or "const assertion" | `const X = { ... } as const` is not a TS `enum`. |
| "interface" (when describing a class) | "class" or "abstract class" | TS interfaces have no runtime; classes do. |
| "type alias" (for branded type) | "branded type" or "nominal type" | A plain `type X = string` is not branded. |
| "Sentry integration enabled" (when `CaptureConsoleIntegration` is configured) | "Sentry's CaptureConsoleIntegration enabled" | Naming the specific integration matters; "enabled" alone is too coarse. |
| "Link" (in React Router context) | "`Link` component" or "route link" | The unqualified word matches dozens of unrelated things. |
| "store" (without scope) | "`localStorage`", "Redux store", "MobX store", "React context" | The audit must name *which* store. |

When `verify-claims.sh` finds a denylisted term in a tagged line, it adds an entry to `weak-claims.json` with `reason: "terminology-needs-review"`. Engineers see this in the weak-claims report and can fix or accept.

## 5. Weak-claims surfacing

After every generation, `verify-claims.sh` writes:

- `.claude/.mtk-cache/weak-claims.json` (machine-readable, full list)
- `.claude/.mtk-cache/weak-claims-report.md` (paste-ready, top 5)

The report ranks weak claims by:

1. **Zero-hit evidence anchor** — cited path/symbol doesn't exist (highest priority — likely fabricated).
2. **Terminology-needs-review** — denylisted term used (likely imprecise).
3. **Partial list** — enumeration not closed (likely incomplete).
4. **No evidence anchor** — tagged but no `path:line` or backticked cite (lowest priority — unverifiable but not necessarily wrong).

The bootstrap/audit summary prints the report path so the engineer can paste it into a PR body, review note, or follow-up issue.

## 6. SHA stamp

Every generated doc carries an `audited-against: <sha>` stamp at generation time:

- **`architecture-principles.md`, `conventions.md`** — frontmatter or top-of-file `<!-- mtk-stamp -->` block.
- **`CLAUDE.md`** — footer comment block (the file is human-edited; footer placement avoids merge conflicts with STEP -1 re-runs).

Stamp format:

```
<!-- mtk-stamp
audited-against: 6a501df9c1b2e3f4a5b6c7d8e9f0a1b2c3d4e5f6
audited-at: 2026-05-25T14:32:11Z
mtk-version: 7.8.0
-->
```

`scripts/audit-drift-check.sh` reads the stamp and reports cited paths that have changed since.

## 7. Eat our own dogfood

`setup-audit` MUST run `scripts/verify-claims.sh` on the doc it just wrote. A passing audit is not "no weak claims" — it's "weak claims surfaced and reported." Refusing to surface them is the failure mode this whole reference exists to prevent.
