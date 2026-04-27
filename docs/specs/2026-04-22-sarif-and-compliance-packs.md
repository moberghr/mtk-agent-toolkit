# SARIF Output & Compliance Packs

- **Date:** 2026-04-22
- **Slug:** sarif-and-compliance-packs
- **Scope:** new-feature (extend existing security/review skills)
- **Status:** draft

## Summary

Add two capabilities to MTK's security workflow, borrowed from `afiqiqmal/claude-security-audit`:

1. **`--pack <name>` flag** on the security-audit flow to load a framework-specific checklist overlay (e.g. `--pack dora`, `--pack pci`, `--pack sox-itgc`). Packs compose on top of the base OWASP checklist.
2. **SARIF 2.1.0 output** from security and pre-commit review runs, written to `.claude/audit/<timestamp>-<pack>.sarif.json`. This makes findings consumable by GitHub Advanced Security, Azure DevOps code scanning, and any SARIF-aware dashboard.

Highest concrete-win borrow from the research: one-afternoon build, unlocks enterprise audit pipelines Moberg clients already run.

## Success Criteria

| ID | Description | Verification |
|---|---|---|
| SC1 | `/mtk security-audit --pack dora` loads `references/packs/dora.md` as an overlay on top of `security-checklist.md`. Findings reference pack rules inline. | Integration test `tests/sarif/test-pack-load.sh`. |
| SC2 | Running any security audit skill emits a SARIF 2.1.0 JSON file under `.claude/audit/` alongside the markdown report. File validates against the SARIF schema. | `jq` schema check + `.claude/audit/*.sarif.json` exists after test run. |
| SC3 | SARIF `runs[].tool.driver.name` is `mtk-security-audit`; `rules[]` populated from the active pack + base checklist; each `results[]` entry has `ruleId`, `level`, `message`, `locations[]` with file/line. | Schema-validated sample inspected manually. |
| SC4 | At least 4 packs ship: `owasp-base`, `dora`, `pci-dss-v4`, `sox-itgc`. Each pack file follows a fixed template: intro + rule table (`ID | Severity | Description | Detection hint | Remediation`). | `ls references/packs/` + manual read. |
| SC5 | `--pack` accepts multiple: `--pack dora --pack pci`. Rules deduplicate by ID; merge preserves highest severity. | Test `tests/sarif/test-multi-pack.sh`. |
| SC6 | Without `--pack`, the default behavior is unchanged (OWASP base only, markdown output). SARIF generation is additive, never breaks existing callers. | Regression test — run without flag, compare to baseline output. |
| SC7 | `.claude/audit/` is gitignored; sample SARIF committed under `tests/sarif/fixtures/`. | `grep audit .gitignore` + fixture present. |
| SC8 | `scripts/validate-toolkit.sh` passes; manifest updated. | Validation green. |

## Architecture

### Pack file layout

```
.claude/references/packs/
  owasp-base.md          # always loaded; current security-checklist.md lifted here
  dora.md                # maps to regulatory/dora.md clauses + detection hints
  pci-dss-v4.md          # PCI rules expressed as code-level checks
  sox-itgc.md            # change-mgmt / access-control checks
  # future: hipaa.md, gdpr-data.md, mifid-records.md
```

Each pack is markdown with a rule table at the top. Pack rules have stable IDs (`DORA-ART-28-4`, `PCI-6-4-3`, `SOX-ITGC-CM-03`) so SARIF output is stable across runs and diffable in audit pipelines.

### Pack rule schema

```markdown
## Rules

| ID | Severity | Description | Detection hint | Remediation |
|---|---|---|---|---|
| PCI-6-4-3 | error | Code review required before release | PR merged without reviewer approval | Require ≥1 approving review before merge |
| PCI-6-5-1 | error | Injection flaws | String concatenation in SQL, shell, LDAP calls | Parameterize queries; use ORM bind params |
```

Severity maps to SARIF levels: `error` → `error`, `warn` → `warning`, `info` → `note`.

### `--pack` flag dispatch

In `/mtk` router skill:

1. Parse `--pack <name>` (repeatable).
2. Resolve each to `references/packs/<name>.md`. Error on unknown pack with list of available packs.
3. Load `owasp-base.md` + all requested packs; build merged rule set (dedupe by ID, keep highest severity).
4. Pass merged rule set as context to `security-and-hardening` or `pre-commit-review` skill.
5. After skill runs, invoke SARIF emitter.

### SARIF emitter

New script: `scripts/emit-sarif.sh`. Takes a findings JSON (structured output from the skill) + active rule set, writes SARIF 2.1.0 to `.claude/audit/<ISO-date>-<pack-slug>.sarif.json`.

Minimal SARIF shape:

```json
{
  "version": "2.1.0",
  "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
  "runs": [{
    "tool": { "driver": {
      "name": "mtk-security-audit",
      "version": "<plugin version>",
      "rules": [ { "id": "PCI-6-4-3", "name": "CodeReviewRequired", "shortDescription": {"text": "..."}, "defaultConfiguration": {"level": "error"} } ]
    }},
    "results": [ {
      "ruleId": "PCI-6-4-3",
      "level": "error",
      "message": {"text": "Merged without reviewer"},
      "locations": [{ "physicalLocation": {
        "artifactLocation": {"uri": "src/foo.cs"},
        "region": {"startLine": 42}
      }}]
    }]
  }]
}
```

### Findings JSON contract between skill and emitter

The security skills must emit a structured findings block (JSON fenced code) at end of their run so the emitter can transform to SARIF. Define schema in `references/packs/findings-schema.md`:

```json
{
  "findings": [
    {"rule_id": "PCI-6-4-3", "file": "src/foo.cs", "line": 42, "message": "...", "severity": "error"}
  ]
}
```

If no structured block is present, emitter falls back to empty SARIF run (still valid) and logs a warning.

## Implementation Batches

| Batch | Files | Verification |
|---|---|---|
| B1 | Lift current `security-checklist.md` into `references/packs/owasp-base.md` with stable rule IDs. Preserve old path as pointer. | Old callers resolve; IDs stable. |
| B2 | Author `dora.md`, `pci-dss-v4.md`, `sox-itgc.md` packs with ≥8 rules each. | Files exist; rule table validates. |
| B3 | Update `/mtk` router to parse `--pack` (repeatable). Update `security-and-hardening` and `pre-commit-review` skills to accept merged rule set. | `test-pack-load.sh`, `test-multi-pack.sh`. |
| B4 | Require findings JSON block in security skill outputs. Document schema in `findings-schema.md`. | Schema doc exists; skill outputs conform. |
| B5 | Build `scripts/emit-sarif.sh`. Gitignore `.claude/audit/`. Add fixture. | `.sarif.json` validates; SC2/SC3 pass. |
| B6 | End-to-end test: run security-audit with `--pack dora --pack pci`, inspect SARIF. | Manual + test script. |
| B7 | Manifest + validation. | `validate-toolkit.sh` passes. |

## Open Questions

- Should packs be plugin-contributed (teams ship their own)? **Not in v1** — start with in-repo packs, add discovery later once the shape stabilizes.
- Do we emit CodeQL-style `help` URIs pointing back to our regulatory references? **Yes, cheap win** — `helpUri` field set to `https://github.com/<org>/claude-helpers/blob/main/.claude/references/regulatory/<framework>.md#<anchor>`.
- GitHub Advanced Security ingests SARIF via workflow upload — ship an example GH Actions workflow snippet in docs? **Yes, one short example in the pack README.**

## Dependencies

- Best consumed *after* `regulatory-framework-references` spec lands — SARIF `helpUri` links back to the per-framework files, and pack rule IDs cross-reference clauses. Not a hard dep; can be built in parallel with placeholder links.

## Out of Scope

- Auto-fix (`--fix`) mode.
- Uploading SARIF to remote services (that's CI's job, not MTK's).
- GitLab / Bitbucket code-scanning integrations (SARIF is standard; they consume it natively).
