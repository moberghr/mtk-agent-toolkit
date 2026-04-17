---
name: security-and-hardening
description: Use when the change touches auth, secrets, audited state, audit trails, infrastructure, or external inputs — treat security as a design constraint, not final polish.
type: skill
license: MIT
compatibility:
  - claude-code
  - codex
trigger: auth-change|secrets-change|audited-state|audit-trail|infrastructure|external-input
skip_when: internal-refactoring|no-data-flow|no-boundary-change
effort: max
context: fork
user-invocable: false
---

# Security And Hardening

## Active Stack

```!
echo "--- Tech Stack ---"
cat .claude/tech-stack 2>/dev/null || echo "(not set)"
```

## Overview

Treat security and compliance as design constraints, not final review polish. Changes to serious software must preserve confidentiality, integrity, auditability, and least privilege.

## When To Use

- Auth or authorization changes
- Audited state mutations (e.g. financial state, patient records, legal documents — see domain supplement)
- Secrets/configuration changes
- New endpoints or external integrations
- Infrastructure or IAM changes

### When NOT To Use

- Purely internal non-sensitive refactors with no new data flow or boundary change

## Workflow

1. Read `CLAUDE.md` and `.claude/references/security-checklist.md` first.
2. If a domain supplement exists (e.g. `.claude/references/domain-finance.md`), load it for domain-specific rationalizations and review questions.
3. Identify trust boundaries:
   - user input
   - external service input
   - internal privileged operations
4. Check auth and authorization requirements.
5. Check PII, secrets, and logging behavior.
6. Check audit requirements for state changes that require an audit trail.
7. Check query safety, transaction boundaries, and error exposure.
8. For infra, check least privilege, blast radius, and secret access scope.
9. If a requirement is unclear, stop and ask rather than guessing.

## Rules

- No secrets in code or logs.
- No unaudited state mutation where the domain requires audit trails.
- No trust in external input without validation.
- No wildcard IAM/resource access without explicit justification.

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` for the shared table. Security-specific traps: "this is an internal endpoint" (internal boundaries move — security requirements don't disappear because something feels internal), and "this doesn't look like regulated data" (if it affects audited state, reporting, audit records, or downstream consumers, it is in scope — check the domain supplement).

## Red Flags

- New endpoint with no obvious auth path
- State mutation with no audit story
- PII or secrets appearing in logs or exception messages
- Broad IAM or secret access added casually

## Verification

- [ ] Trust boundaries were identified
- [ ] Auth/authz expectations were checked
- [ ] Audit requirements were checked (domain supplement consulted if present)
- [ ] No secrets or PII leakage is introduced
- [ ] Infra permissions remain least-privilege
