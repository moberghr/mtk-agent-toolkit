# Spec: mtk-setup hardening — reproducibility, output quality, versioned re-runs, deterministic audit

**Date:** 2026-04-23
**Target version:** v7.0.0 (breaking — changes `--audit` re-run contract and reference file layout)
**Owner:** Mirko
**Motivation:** Competitive analysis (2026-04-22) identified four high-value gaps in `mtk-setup` vs. Copier / Aider / Repomix / AGENTS.md ecosystem. Bundled into one major release to avoid multiple breaking-change cycles.

---

## Goals

1. **Reproducibility** — bootstrap output is deterministically re-derivable from a pinned `moberghr/coding-guidelines` revision.
2. **Safety** — no generated file is written until it passes a secret scan.
3. **Output quality** — generated `CLAUDE.md` is ≤200 lines / ~2000 tokens; engineers see line/token counts before writing.
4. **Versioned re-runs** — `--audit` and future `mtk-setup` upgrades do a 3-way merge against the previous template output instead of clobbering.
5. **Deterministic audit** — architecture audit is fed a ranked symbol graph (tree-sitter / csharp-lsp), not a raw "read the codebase" pass.

## Non-goals

- Changing the skill anatomy or the user-invocable command surface (still `/mtk-setup [flags]`).
- Re-organizing `.claude/references/` content — only metadata additions.
- Replacing the LLM in the audit — the LLM still writes the principles doc; we change its input.

---

## Scope — files touched

### New files

| Path | Purpose |
|---|---|
| `scripts/secret-scan.sh` | grep-based secret detector, exits non-zero on match |
| `scripts/count-tokens.sh` | approximate token count (`wc -w × 1.3`) |
| `scripts/build-references-index.sh` | generate `.claude/references.index` from reference frontmatter |
| `scripts/repomap.sh` | emit ranked symbol graph (.NET via csharp-lsp, Python/TS via tree-sitter) |
| `.claude/references.index` | generated index (gitignored; rebuilt on setup) |
| `.claude/.mtk-cache/` | gitignored; stores previous-version template outputs for 3-way diff |
| `docs/specs/2026-04-23-mtk-setup-hardening.md` | this spec |
| `tests/pressure-tests/mtk-setup-rerun.md` | adversarial re-run scenarios |
| `tests/pressure-tests/mtk-setup-secret-scan.md` | known-secret payloads must block write |

### Modified files

| Path | Change |
|---|---|
| `.claude/manifest.json` | bump to `7.0.0`; add `coding-guidelines-sha` field; add new scripts + references.index + cache dir to `files` |
| `.claude-plugin/plugin.json` | bump to `7.0.0` |
| `.claude/skills/mtk-setup/SKILL.md` | document `--update-guidelines` flag; document new re-run semantics |
| `.claude/skills/setup-bootstrap/SKILL.md` | pin fetch to SHA; call secret-scan before write; enforce 200-line ceiling; preview shows token/line count; emit frontmatter on references; write template copy to `.mtk-cache/` |
| `.claude/skills/setup-audit/SKILL.md` | call `repomap.sh`; feed ranked symbols into prompt; include provenance section; 3-way merge on re-run |
| `.claude/references/**/*.md` (~10 files) | add `description` + `globs` + `alwaysApply` frontmatter |
| `scripts/validate-toolkit.sh` | assert CLAUDE.md ≤200 lines; assert references.index in sync; assert every reference has valid frontmatter |
| `.gitignore` | add `.claude/.mtk-cache/` and `.claude/references.index` |
| `CHANGELOG.md` | v7.0.0 entry, BREAKING section |

### Protected files (unchanged — existing protection honored)

`CLAUDE.md`, `AGENTS.md`, `.claude/references/architecture-principles.md`, `tasks/lessons.md`, `settings.local.json`, etc.

---

## Design — per goal

### G1. Reproducibility: pinned coding-guidelines SHA

**Manifest field:**
```json
{
  "version": "7.0.0",
  "coding-guidelines": {
    "repo": "moberghr/coding-guidelines",
    "sha": "<40-char-commit-sha>",
    "files": {
      "dotnet/CodingStyle.md": "sha256:<hash>"
    }
  }
}
```

**Fetch:** `setup-bootstrap` uses the pinned SHA:
```bash
curl -sL "https://raw.githubusercontent.com/moberghr/coding-guidelines/${SHA}/CodingStyle.md" -o "$OUT"
echo "$EXPECTED_SHA256  $OUT" | sha256sum -c -   # fail if mismatch
```

**Generated CLAUDE.md footer (as HTML comment):**
```html
<!-- mtk-setup: v7.0.0
     coding-guidelines: moberghr/coding-guidelines@<sha>
     generated: 2026-04-23T14:00Z -->
```

**New flag `/mtk-setup --update-guidelines`:**
1. `git ls-remote https://github.com/moberghr/coding-guidelines HEAD` → resolve current SHA.
2. Diff current vs. pinned SHA's file list.
3. Write new `manifest.json` + new `manifest.json.sha256` entries.
4. Show engineer a summary; do NOT auto-rerun bootstrap.

### G2. Secret scan before write

**Patterns (first cut, extendable):**
- AWS: `AKIA[0-9A-Z]{16}`
- Azure: `DefaultEndpointsProtocol=.*AccountKey=`
- GitHub: `gh[pousr]_[0-9a-zA-Z]{36,}`
- Slack: `xox[baprs]-[0-9a-zA-Z-]{10,}`
- Anthropic: `sk-ant-[a-zA-Z0-9-]{20,}`
- Generic: `-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----`
- Password-ish: `(?i)(password|passwd|pwd|secret|token|api[_-]?key)\s*[:=]\s*['\"]?[^'\"\s]{8,}`
- IBAN: `[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}`

**Contract:**
```
secret-scan.sh <file>
  exit 0 + empty stderr  → clean, may proceed
  exit 1 + stderr with "<file>:<line>: <pattern-name>" lines → BLOCK write
```

Bootstrap calls it on every file before `Write`. On match: print findings, abort the entire run, instruct engineer to investigate.

**Self-test mode:** `secret-scan.sh --self-test` feeds canned fixtures and asserts each pattern fires.

### G3. Output quality guards

**Ceiling:**
- CLAUDE.md generated by bootstrap: **max 200 lines, max ~2000 tokens** (`wc -w × 1.3`).
- Enforced at generation time — skill fails with explicit message "CLAUDE.md exceeds 200 lines; move <section> to .claude/rules/<name>.md."
- `validate-toolkit.sh` enforces same limit on the committed `CLAUDE.md`.

**Preview table:** `--preview` mode prints before any write:
```
FILE                                       LINES   TOKENS   STATUS
CLAUDE.md                                    178     1843    NEW
.claude/rules/toolkit-structure.md            47      512    NEW
.claude/references/architecture-principles    92     1201    UPDATE
AGENTS.md                                     23      287    NEW
```

Ask confirm via `AskUserQuestion` before writing.

### G4. Reference frontmatter + index

**Every file in `.claude/references/` gains:**
```yaml
---
description: <one-line CSO>
globs: ["**/*.cs", "**/Money*.cs"]          # patterns where this ref is relevant
alwaysApply: false                           # true = load into every session
---
```

**Index format (`.claude/references.index`):**
```
# path	alwaysApply	description	globs
.claude/references/domain-finance.md	false	Finance domain supplement	**/Money*.cs,**/*Payment*.cs
.claude/references/security-checklist.md	true	Baseline security checks	**/*
...
```

Built by `scripts/build-references-index.sh`. Validator asserts index is in sync with frontmatter.

### G5. Versioned 3-way merge for re-runs

**Cache layout:**
```
.claude/.mtk-cache/
  v6.5.0/
    CLAUDE.md
    AGENTS.md
    rules/*.md
    references/*.md
  v7.0.0/
    ...
```

Bootstrap writes the clean template output to `.mtk-cache/<current-version>/` at generation time, **before** applying any engineer edits.

**On re-run (any flag):**
1. Resolve `<previous-version>` from the footer of existing CLAUDE.md (or fall back to "no previous template — ask engineer").
2. For each would-be-generated file:
   - `previous_template = .mtk-cache/<previous-version>/<file>`
   - `new_template` = freshly generated
   - `current` = what's on disk
3. Run `git merge-file --union` (bash-available) with `previous_template` as the ancestor.
4. Classify outcome:
   - **No engineer edits** → write new template (auto).
   - **Engineer edits, no conflict** → 3-way merge result (auto, shown in preview).
   - **Conflict** → leave on disk with conflict markers, report, do not proceed until resolved.
   - **Protected file** → untouched, log "skipped (protected)".
5. `--preview` shows each file's classification before asking to proceed.

**Fallback when no previous template exists** (first upgrade from pre-v7.0.0):
- Prompt engineer: "No previous template cache. Treat current files as hand-edited (safer) or as stock template (overwrite)? [hand-edited/stock]"
- Default: hand-edited — show diff against new template, require engineer to merge manually.

### G6. Deterministic audit input

**`scripts/repomap.sh <repo-path> <stack> <token-budget>`:**
- Emits `.claude/.mtk-cache/repomap.json`:
  ```json
  {
    "symbols": [
      {"name": "InvoiceService", "kind": "class", "file": "src/...", "refs": 47, "rank": 0.91},
      {"name": "IMoney", "kind": "interface", "file": "src/...", "refs": 23, "rank": 0.72}
    ],
    "edges": [{"from": "InvoiceService", "to": "IMoney", "kind": "uses"}],
    "token_estimate": 3892
  }
  ```
- .NET: call `mcp__csharp-lsp__csharp_symbols` + `csharp_references` to build graph; PageRank approximation via in-edge count (simple first pass).
- Python/TS: shell out to a small tree-sitter script (bundled in `scripts/tree-sitter/`).
- Binary-search to fit under `<token-budget>` (default 4000).

**Audit prompt change:** instead of "read the codebase and extract principles," the prompt becomes:
> "Given the ranked symbol graph below and the coding-guidelines reference, identify the architectural patterns this codebase actually uses. For each principle, cite the symbols that evidence it."

**Output gains a provenance section:**
```markdown
## Provenance
Principles derived from ranked symbol graph:
- InvoiceService (rank 0.91) — evidences CQRS handler pattern
- IMoney, Money (ranks 0.72, 0.68) — evidences value-object domain modeling
- ...
```

---

## Rollout / release

### v7.0.0 — single release, breaking

**Breaking changes:**
1. `--audit` re-run now 3-way merges instead of regenerating → engineers who script around clobbering must update.
2. Reference files gain frontmatter → any tooling that reads raw reference files needs to strip it.
3. `manifest.json` schema adds `coding-guidelines` object → consumers of manifest need to handle it.

**Migration path documented in CHANGELOG.md:**
- Auto-migration on first v7.0.0 `/mtk-setup` run: detect missing footer, prompt engineer, seed `.mtk-cache/` from current files.
- Reference frontmatter added automatically by setup-bootstrap `--audit` on first v7.0.0 run.

**No feature flags.** The architecture is "one big cutover, well-tested" — consistent with MTK's past major bumps.

---

## Batching — suggested execution order

| Batch | Scope | Verifiable by |
|---|---|---|
| **B1** | G1 (SHA pinning) + G2 (secret scan) + new scripts + manifest schema bump | `scripts/validate-toolkit.sh`, `secret-scan.sh --self-test`, manual bootstrap on a throwaway repo |
| **B2** | G3 (ceiling + preview) + G4 (reference frontmatter + index) | validator asserts ceiling; index rebuild is a no-op after first run |
| **B3** | G5 (versioned 3-way merge) + migration path | pressure test: `mtk-setup-rerun.md` with engineer edits, no edits, conflicting edits |
| **B4** | G6 (deterministic repomap) + audit workflow change | pressure test: known .NET repo with expected principles must be detected; provenance section present |
| **B5** | docs + CHANGELOG.md + version bumps | `validate-toolkit.sh` passes; all pressure tests pass |

Each batch commits independently on `feat/mtk-setup-hardening` with `validate-toolkit.sh` green.

---

## Risks

| Risk | Mitigation |
|---|---|
| 3-way merge produces unreadable conflicts on large files | Split CLAUDE.md writes by section; merge per-section |
| `.mtk-cache/` grows unbounded | Keep only last 2 versions; `--update-guidelines` prunes older |
| `csharp-lsp` MCP not available in every engineer's environment | Fall back to tree-sitter-c-sharp; if neither available, warn and use current LLM-only audit |
| Secret scan false positives block legit bootstraps | `--force-secret-scan` escape hatch, logged prominently |
| Breaking change annoys the team mid-rollout | Only roll out after v6.x has >1 week of stable use; CHANGELOG is explicit |

---

## Out of scope (intentional)

- AGENTS.md emission — already implemented in v6.x.
- Community starter-pack catalog — belongs in `moberghr/coding-guidelines`, not here.
- Windsurf-style three-tier rule overrides — existing references + CLAUDE.md + settings.local.json cover this.

---

## Approval checklist

- [ ] Scope accurate (no missing files)
- [ ] Breaking changes acceptable for v7.0.0 cutover
- [ ] Batch order makes sense
- [ ] Risks mitigated appropriately
- [ ] No feature-flag half-states (per CLAUDE.md: "don't use feature flags when you can change the code")
