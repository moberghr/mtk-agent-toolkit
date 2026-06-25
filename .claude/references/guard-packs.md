---
description: How MTK linter "guard packs" are structured, discovered, and authored — shippable deterministic review units that catch AI failure modes before review
globs: ["hooks/linter-patterns/**"]
alwaysApply: false
---

# Guard Packs

A **guard pack** is a deterministic, shippable unit of review: a tab-separated file
of regex rules that `hooks/pre-commit-linters.sh` runs against staged changes. Packs
are MTK's cheap first pass — they catch the mechanical slice of the AI failure modes
catalogued in `ai-failure-modes.md` (the judgment slice still needs a reviewer agent).

Per-stack and per-domain quality gates, packaged as reusable units rather than only
prose checklists.

## Directory layout & activation order

```
hooks/linter-patterns/
  core/            always active            (secrets, slopwatch, docdrift)
  stack-<name>/    active when .claude/tech-stack matches <name>
  domain-<name>/   active when .claude/domains contains <name> (one per line)
  project/         project-local overrides  (gitignored)
```

`pre-commit-linters.sh` concatenates the active packs in that order and scans each
staged added line against every rule.

## File format

One rule per line, **tab-separated**, five fields; lines starting with `#` are comments:

```
RULE_ID<TAB>SEVERITY<TAB>ERE_REGEX<TAB>RATIONALE<TAB>SUGGESTED_FIX
```

- **RULE_ID** — stable, uppercase, hyphenated (e.g. `FIN-AUDITED-DELETE`). Used in findings and waivers.
- **SEVERITY** — `critical` | `warning` | `suggestion`. Only `critical` blocks a commit (`verdict=NEEDS_CHANGES`); `warning`/`suggestion` are advisory.
- **ERE_REGEX** — POSIX extended regex. Matched with `grep -Ei`, so matching is **case-insensitive** and **PCRE features (`(?i)`, lookahead `(?!…)`) do not work** — use plain ERE alternation. Avoid empty alternation branches (`(|a|b)`); use `([x]?|a|b)`.
- **RATIONALE** — one line: why the pattern is a smell.
- **SUGGESTED_FIX** — one line: the concrete remedy.

## Choosing severity

`critical` is reserved for things that are almost always wrong and cheap to confirm
(SQL injection via interpolation, float money). Heuristic smells that have legitimate
exceptions (absolute doc claims, anonymous endpoints) are `warning` — they inform, they
do not block. When in doubt, `warning`: a noisy `critical` that blocks commits gets the
whole pack disabled.

## Authoring & shipping a new pack

1. Write the `.txt` under the right directory (`core/`, `stack-<name>/`, or `domain-<name>/`).
2. Keep rules **conservative** — a false positive on every commit trains engineers to ignore the pack.
3. Add a manifest entry (`source`/`target`/`action: sync`/`description`); stack/domain packs may carry a `stack:` field.
4. Add a test under `tests/hooks/` asserting a seeded smell matches and a clean control line does not (see `test-docdrift-pack.sh`).
5. Run `bash scripts/validate-toolkit.sh`.

## Relationship to review

Packs are the deterministic floor; the reviewer agents (`compliance-reviewer`,
`silent-failure-hunter`, …) are the judgment ceiling. A pack rule that needs to "know"
whether a symbol exists or whether prose matches behavior is the wrong tool — leave that
to a reviewer and keep the pack to falsifiable text smells.
