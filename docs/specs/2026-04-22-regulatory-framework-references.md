# Regulatory Framework References & Control Mapping

- **Date:** 2026-04-22
- **Slug:** regulatory-framework-references
- **Scope:** new-feature (references + one agent update)
- **Status:** draft

## Summary

Split the current generic `references/domain-finance.md` into **framework-specific reference files** with clause-level detail, and add a **control-mapping table** that ties each regulatory control to the MTK skill/agent that enforces it and the artifact that proves enforcement. Borrowed from Sushegaad GRC skills — the pattern is "one file per framework, clause numbers inline." Also updates `compliance-reviewer` agent to require inline rule-number citations in every finding.

Targets the audited/regulated subset of MTK users (Moberg's investment-banking clients). Non-regulated teams ignore the new references; nothing breaks.

## Success Criteria

| ID | Description | Verification |
|---|---|---|
| SC1 | `.claude/references/regulatory/` exists with one file per framework covered (DORA, SOX ITGC, PCI-DSS v4, MiFID II, GDPR). Each lists numbered articles/controls with a one-line plain-English summary. | `ls .claude/references/regulatory/` shows the 5 files; each file has ≥10 cited clauses. |
| SC2 | `references/compliance-mapping.md` exists as a table: `Control → MTK skill/agent → Proof artifact`. At least 20 rows spanning all 5 frameworks. | Manual read. |
| SC3 | `compliance-reviewer` agent prompt requires inline citations in bracket form (`[DORA Art. 28]`, `[SOX §404]`, `[PCI 6.4.3]`). Findings without a citation are rejected by the agent itself. | Adversarial pressure test `tests/pressure-tests/compliance-reviewer-citations.md` passes. |
| SC4 | `domain-finance.md` becomes a short index pointing to the per-framework files; no regressions for callers that cite it. | `grep -r domain-finance.md .claude/` still resolves; content unchanged above the new "see also" section. |
| SC5 | Each per-framework file ends with a "How MTK enforces this" section referencing 2-3 concrete skills. | Manual read. |
| SC6 | All new files listed in `.claude/manifest.json`; `bash scripts/validate-toolkit.sh` passes. | Validation green. |
| SC7 | Published micro-benchmark in `tests/benchmarks/regulatory-citations.md`: 20 scenarios × 3 assertions (correct framework ID, correct clause, correct MTK skill named). Score recorded. | Benchmark file exists with numeric score. |

## Architecture

### File layout

```
.claude/references/
  domain-finance.md                 # slim index + general finance guidance
  compliance-mapping.md             # NEW: control→skill→artifact table
  regulatory/                       # NEW directory
    dora.md                         # EU DORA — ICT risk, incidents, third-party
    sox-itgc.md                     # SOX 404 ITGC — change mgmt, access, ops
    pci-dss-v4.md                   # PCI-DSS v4.0.1 — cardholder data
    mifid-ii.md                     # MiFID II — record-keeping, best execution
    gdpr.md                         # GDPR — data subject rights, DPIA, breach
```

### Per-framework file anatomy

Each file follows the same template:

1. **Scope** — one paragraph: who it applies to, what kind of systems.
2. **Cited controls** — table of `Clause | Plain-English summary | Trigger in code`.
3. **How MTK enforces this** — bulleted list pointing to skills (`security-and-hardening`, `pre-commit-review`, `spec-drift-detection`) and what evidence they produce.
4. **Common traps** — 3-5 things teams get wrong (generalized, not Moberg-specific).

Keep each file under 300 lines. Progressive disclosure — reader loads only the framework relevant to the current PR.

### compliance-mapping.md

Single table, three columns:

| Control | MTK skill / agent | Proof artifact |
|---|---|---|
| DORA Art. 8 (ICT risk identification) | `security-and-hardening` | Spec security section + threat model note in PR |
| DORA Art. 17 (major incident classification) | `handoff` + `correction-capture` | Handoff artifact tagged `incident:true` |
| SOX 404 — change authorization | `spec-driven-development` | Approved spec file in `docs/specs/` |
| SOX 404 — segregation of duties | `compliance-reviewer` agent | Review record in PR with reviewer ≠ author |
| PCI 6.4.3 (code review before release) | `pre-commit-review` + `code-review-and-quality` | Pre-commit audit log + reviewer sign-off |
| PCI 6.5 (common coding vulnerabilities) | `security-and-hardening` | OWASP mapping in security-checklist.md |
| MiFID II Art. 16(7) (record-keeping) | future: decision ledger (separate spec) | Append-only decision log |
| GDPR Art. 25 (data protection by design) | `spec-driven-development` security section | Spec drift detection diff |

Rows added organically as frameworks grow.

### compliance-reviewer update

Agent prompt gains a hard rule near the top:

> Every finding MUST include a bracketed citation: framework identifier + clause number (e.g. `[DORA Art. 28.4]`, `[SOX §404 ITGC-CM-03]`, `[PCI 6.4.3]`, `[MiFID II Art. 16(7)]`, `[GDPR Art. 25]`). Findings without a citation are invalid — reject your own output and retry.

Add one worked-example finding in the agent definition showing the required shape.

## Implementation Batches

| Batch | Files | Verification |
|---|---|---|
| B1 | Create `regulatory/dora.md`, `regulatory/sox-itgc.md`, `regulatory/pci-dss-v4.md` with the template. | Files exist, template sections present. |
| B2 | Create `regulatory/mifid-ii.md`, `regulatory/gdpr.md`. Slim `domain-finance.md` to index. | Files exist; old callers still resolve. |
| B3 | Create `compliance-mapping.md` with ≥20 rows. | Row count, formatting. |
| B4 | Update `compliance-reviewer` agent with citation rule + worked example. | Grep for rule; agent file parses. |
| B5 | Manifest entries + validation. | `bash scripts/validate-toolkit.sh` passes. |
| B6 | Benchmark file + pressure test. | Score recorded; pressure test passes manually. |

## Open Questions

- Do we want Basel III / FINRA / IFRS files too, or ship EU-first given Moberg's market? **Recommend EU-first (DORA/MiFID/GDPR) + global (SOX/PCI) for now**; add others on demand.
- Should `compliance-mapping.md` be machine-readable (YAML)? **Not yet** — markdown table is readable by both agents and humans; revisit when we build tooling that queries it.

## Out of Scope

- SARIF output (separate spec).
- Decision ledger / tamper-evident audit trail (separate spec).
- Automated control coverage reports (depends on both of the above).
