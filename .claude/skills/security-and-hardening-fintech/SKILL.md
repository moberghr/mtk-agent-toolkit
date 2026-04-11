---
name: security-and-hardening-fintech
description: Use when the change touches auth, secrets, financial state, audit trails, infrastructure, or external inputs — treat security as a design constraint, not final polish.
license: MIT
compatibility:
  - claude-code
  - codex
trigger: auth-change|secrets-change|financial-state|audit-trail|infrastructure|external-input
skip_when: internal-refactoring|no-data-flow|no-boundary-change
---

# Security And Hardening for Fintech

## Overview

Treat security and compliance as design constraints, not final review polish. Fintech changes must preserve confidentiality, integrity, auditability, and least privilege.

## When To Use

- Auth or authorization changes
- Financial state mutations
- Secrets/configuration changes
- New endpoints or external integrations
- Infrastructure or IAM changes

### When NOT To Use

- Purely internal non-sensitive refactors with no new data flow or boundary change

## Workflow

1. Read `CLAUDE.md` and `.claude/references/security-checklist.md` first.
2. Identify trust boundaries:
   - user input
   - external service input
   - internal privileged operations
3. Check auth and authorization requirements.
4. Check PII, secrets, and logging behavior.
5. Check audit requirements for financial state changes.
6. Check query safety, transaction boundaries, and error exposure.
7. For infra, check least privilege, blast radius, and secret access scope.
8. If a requirement is unclear, stop and ask rather than guessing.

## Rules

- No secrets in code or logs.
- No unaudited financial state mutation.
- No trust in external input without validation.
- No wildcard IAM/resource access without explicit justification.

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "This is an internal endpoint" | Internal boundaries move. Security requirements do not disappear because something feels internal. |
| "This doesn't look like financial data" | If it affects balances, reporting, audit records, or reconciliation, it is in scope. |
| "The framework probably handles that for us" | Probably is not a security control. Verify the behavior. |

## Red Flags

- New endpoint with no obvious auth path
- State mutation with no audit story
- PII or secrets appearing in logs or exception messages
- Broad IAM or secret access added casually

## Verification

- [ ] Trust boundaries were identified
- [ ] Auth/authz expectations were checked
- [ ] Audit requirements were checked
- [ ] No secrets or PII leakage is introduced
- [ ] Infra permissions remain least-privilege
