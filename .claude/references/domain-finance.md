---
paths:
  - "**/payments/**"
  - "**/transactions/**"
  - "**/billing/**"
  - "**/ledger/**"
  - "**/settlements/**"
  - "**/accounting/**"
  - "**/reconciliation/**"
  - "**/fees/**"
---

# Domain Supplement — Finance

Finance-specific examples for the universal review and security skills. The core toolkit is written for any team building serious software; this file captures what "serious" means concretely in fintech, investment banking, and trading systems. Teams in other regulated domains (healthcare, legal, regulated SaaS) can author analogous supplements and wire them into the skills the same way.

When a skill says "audited state mutation" or "regulated data," read this file for the concrete shape those concepts take in finance.

## What counts as regulated state

- Account balances (cash, position, margin, collateral)
- Money movement (transfers, payments, settlements, FX conversions)
- Trade lifecycle events (order placement, execution, allocation, confirmation, settlement)
- Fee, commission, and interest calculations
- Reconciliation records and breaks
- Reporting inputs (regulatory, tax, client statements)
- Audit trail entries themselves — tampering with the audit is its own violation

If a change touches any of the above, it is in scope for the full security and review workflow. "It's just a calculation" or "it's an internal service" does not remove it from scope.

## What counts as sensitive data

- **PII** — names, addresses, national IDs, dates of birth, beneficial ownership records
- **Financial identifiers** — account numbers, card numbers (PCI scope), IBANs, SWIFT codes
- **Credentials and keys** — API tokens for exchanges, custody keys, signing keys
- **Trade and position data** — can be market-moving, insider-adjacent, or client-confidential
- **Reporting artifacts** — regulatory submissions, audit reports, fee disclosures

Never log any of the above. Never include them in error messages or exception payloads. Never ship them to third-party observability tools without explicit data-handling review.

## Audit requirements

- Every mutation to regulated state must produce an audit record in the same transaction as the mutation. A commit without an audit row is a bug.
- Audit records must capture: who, what, when, from-value, to-value, correlation ID, source system.
- Audit records are append-only. No update, no soft-delete.
- Retention is regulator-driven, not engineer-driven. Don't shorten retention to save storage.
- Time is authoritative — use server time, UTC, with a trusted clock source. Client-provided timestamps are input, not truth.

## Common rationalizations

| Rationalization | Reality |
|---|---|
| "This isn't money movement, it's just a calculation" | If the calculation feeds a balance, fee, P&L, or regulatory number, it is in scope. |
| "This endpoint is internal / service-to-service" | Trust boundaries shift. Internal does not mean unauthenticated. Service identity and scope still apply. |
| "We're just reading, not writing" | Unauthorized reads of position, PII, or trade data are a violation on their own. |
| "The audit happens downstream in the data warehouse" | Downstream audit is observability, not the primary audit trail. Write the audit row at the source. |
| "This is a test / sandbox env" | Sandbox that touches real client data or real keys is production for compliance purposes. |
| "The amount is tiny" | Materiality is set by regulators, not by feel. Rounding, fee leakage, and dust bugs are still violations. |
| "We already reconcile nightly, so a small drift is fine" | Reconciliation catches errors; it does not license them. |

## Review questions for finance changes

- Does this change mutate regulated state? If yes, is there an audit write in the same transaction?
- Does any field contain PII or financial identifiers that could leak into logs, metrics, exceptions, or upstream observability?
- Is rounding, currency conversion, or time-zone handling explicit and tested, or inherited implicitly from a framework default?
- Are idempotency keys present on anything that could be retried (money movement, order placement, webhooks)?
- Do error paths preserve the audit write? A rolled-back transaction that loses the audit row is a bug.
- If this path is bypassed or fails open, what is the blast radius — stale data, duplicate trades, duplicate payments, wrong report numbers?
- Does this introduce a new trust boundary with the market, a custodian, an exchange, a bank, or a regulator? If yes, is authentication, signing, and replay protection explicit?

## Worked examples

### "Just a helper"

A new helper method `CalculateAdjustedFee(order)` is added to a utility class. It multiplies a fee rate by an order amount.

Even though the method does no I/O, it is in scope because its output flows into a billed fee. The review must check: precision/rounding mode, currency handling, whether the fee rate source is auditable, and whether the caller writes an audit row when the adjusted fee differs from the base fee.

### "Internal reporting endpoint"

A new endpoint `/internal/positions/snapshot` returns position data for an internal dashboard, "not exposed externally."

In scope for full security review. Internal network boundaries are not a security control — authn, authz, scope, rate limit, and audit of who viewed what still apply, because position data is market-sensitive and client-confidential.

### "Just adding a log line"

A debug log is added that includes a full request body on error, to aid support.

Hard stop if the request body carries PII, account numbers, or position data. The log is now a regulated data store. Either scrub the payload at the log-site or remove the log.

## Using this file

- `security-and-hardening` cites this file when the change touches audited state mutation or regulated data in a finance codebase.
- `code-review-and-quality` cites this file's rationalizations table in addition to its own universal table when reviewing finance-domain code.
- `compliance-reviewer` loads this file alongside the universal security checklist.

If your team works in a different regulated domain, copy this file to `domain-<yours>.md`, replace the examples and rationalizations, and update the skill references.
