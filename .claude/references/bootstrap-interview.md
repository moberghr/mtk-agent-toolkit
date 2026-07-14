---
name: bootstrap-interview
description: STEP 2.5 post-scan interview for setup-bootstrap — question set, adaptive-ambiguity protocol, answer routing, and the setup-answers.json schema. Read on-demand by setup-bootstrap STEP 2.5.
globs: [".claude/skills/setup-bootstrap/**"]
alwaysApply: false
---

# Setup Bootstrap — Post-Scan Interview (STEP 2.5)

Read this companion from `setup-bootstrap` STEP 2.5 ("Post-Scan Interview"). The `--non-interactive` skip/reuse gates and the re-run reuse rule stay in SKILL.md; the question set, adaptive-ambiguity protocol, answer routing, and `setup-answers.json` schema live here.

Auto-detection captures WHAT is in the codebase. It cannot capture the team's implicit knowledge — the things that make CLAUDE.md actually useful. Ask **3–7 focused questions** via `AskUserQuestion`. These answers feed directly into the Critical Rules and `project-specific.md`.

**Rules for the interview:**
- Keep it short. 7 static questions max, plus up to 3 adaptive questions from audit ambiguities (10 total ceiling). If the engineer pushes back or seems unsure, accept "skip" as a valid answer.
- Do NOT ask anything you can answer from the scan (e.g., "what's your test framework" — you already know).
- Frame for answers you can convert into trigger-action rules.
- Record answers; integrate into Step 3 output.

**Question set (adapt wording per stack):**

1. **Top failure modes** — "What are the 2–3 things AI assistants (or junior engineers) get wrong most often in this codebase?" Convert each answer into a `WHEN X, DO NOT Y` rule.

2. **Hard nevers** — "What should an AI **never** do in this repo without explicit approval?" Examples to prompt with: "touch migrations / modify financial state without audit trail / change auth middleware / drop caches / skip the review step". These become the top Critical Rules (§0.x).

3. **Invisible conventions** — "Is there an architectural or naming convention that isn't obvious from reading the code?" (e.g., "all money is `decimal` with 4-digit scale", "handlers must emit a domain event", "routes live in `Endpoints/` not `Controllers/` even though we use MVC").

4. **Branch + PR workflow** — only ask if recent `git log` / PR templates didn't make this obvious. "How do you name branches and what's the PR convention?"

5. **Compliance / regulatory constraints** (always ask for regulated domains) — "Are there compliance constraints that should surface in reviews? (e.g., PII handling, audit log requirements, SOC2 scope, PCI scope)"

6. **Definition of done** — "What must be true before a change in this repo counts as done? (build + tests green, review passed, manual QA, deploy verification, docs updated …)" Answers feed CLAUDE.md verification guidance and `.claude/rules/project-specific.md`.

7. **Product purpose** — "One sentence: what does this product do, and for whom?" Skippable like the rest. Feeds `.claude/references/product.md` (STEP 3.8).

**Adaptive questions (from audit ambiguities):** if `.claude/.mtk-cache/ambiguities.json` exists and its `ambiguities` array is non-empty, ask up to **3** additional `AskUserQuestion` items on top of the static set — total interview budget: static 7 + adaptive 3 max (10 total ceiling). Rank ambiguities by total hit count (sum of `competing_forms[].count`), highest first, and ask about the top ones only.

Phrasing pattern: "The codebase splits on `<claim>`: `<form A>` (N/M) vs `<form B>` (K/M). Which is the standard?" — options are the competing forms plus an explicit **"Leave ambiguous (document the split)"** option.

- **Persist:** write each answer under a new top-level `resolved_ambiguities` key in `.claude/setup-answers.json`, an object keyed by the ambiguity's `anchor`: `{"<anchor>": {"choice": "<form chosen, or \"leave-ambiguous\">", "decided": "<ISO8601 UTC>"}}`.
- **Doc upgrade:** where an ambiguity was resolved (not left ambiguous), upgrade that `[AMBIGUOUS]` line in the generated doc to a decided convention, citing `Evidence: engineer interview — .claude/setup-answers.json (resolved_ambiguities)`.
- **Re-run rule:** anchors already present in `resolved_ambiguities` are never re-asked. If a fresh scan contradicts a recorded resolution, emit a Needs review item instead of silently picking a side — same interview-conflict contract as setup-audit's "Interview answers are authoritative" rule (cited, not restated).

**What to do with answers:**
- Each `hard never` → top of Critical Rules, with `IMPORTANT:` prefix.
- Each `top failure mode` → rule in the relevant `.claude/rules/` file (e.g., failure about EF queries → `data-layer.md`).
- Each `invisible convention` → `project-specific.md`.
- Compliance answers → fold into `security.md` with `§1.x` numbering.
- Definition-of-done answers → CLAUDE.md's verification guidance (what "done" means for this repo) and `.claude/rules/project-specific.md`.
- Product purpose answer → persisted under answer key `product_purpose`; seeds `.claude/references/product.md` (STEP 3.8).
- **Evidence anchor (every rule sourced from an answer):** cite the steering file as the rule's evidence, e.g. `Evidence: engineer interview — .claude/setup-answers.json (hard_nevers)`. `scripts/verify-claims.sh` resolves real paths before content-grep, so these anchors always hit — engineer-stated rules are never auto-downgraded by the verify pass.

**Persist answers:**

After the interview (including when some questions are skipped), write `.claude/setup-answers.json` — committed, not gitignored. This write goes through the STEP 3.5c secret-scan gate like any other generated file.

```json
{
  "version": 1,
  "captured": "<ISO8601 UTC>",
  "source": "engineer-interview",
  "answers": {
    "hard_nevers": [],
    "failure_modes": [],
    "invisible_conventions": [],
    "branch_pr_workflow": "",
    "compliance_constraints": [],
    "done_definition": [],
    "product_purpose": ""
  },
  "skipped": [],
  "resolved_ambiguities": {}
}
```
