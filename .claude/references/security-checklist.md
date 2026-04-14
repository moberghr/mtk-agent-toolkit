---
paths:
  - "**/auth/**"
  - "**/authentication/**"
  - "**/authorization/**"
  - "**/security/**"
  - "**/secrets/**"
  - "**/middleware/**"
---

# Security Checklist

Fast security and compliance reference for serious software.

## Input And Auth

- Validate external input at the API boundary.
- Require authentication and authorization on every protected endpoint.
- Do not trust client-side validation.

## Secrets And PII

- Never hardcode credentials, tokens, or connection strings with secrets.
- Do not log PII, tokens, secrets, or raw financial payloads.
- Use approved secrets storage patterns from `CLAUDE.md`.

## Data Integrity

- State-changing financial operations need an audit trail.
- Use parameterized queries only.
- Ensure transactional boundaries cover audit writes when required.

## Infrastructure

- IAM permissions should be least-privilege.
- Do not introduce wildcard resource access without strong justification.
- Review VPC and security group changes for blast radius.

## Review Questions

- Could this change expose data or weaken access control?
- Could this change mutate financial state without audit coverage?
- Is any secret, token, or credential now committed or logged?
