---
description: Fast security-focused review of staged changes. Run before every commit — checks only the critical compliance rules, not the full review workflow.
allowed-tools: Read, Glob, Grep, Bash
---

# Pre-Commit Security Review

Run a fast, security-focused review on staged changes only. This is the lightweight
check engineers should run before every commit.

## Process

1. Get the staged diff: `git diff --cached`
2. If nothing staged, check unstaged: `git diff`
3. If nothing at all, tell the engineer there's nothing to review

## Check ONLY These (from CLAUDE.md §1):

- **Secrets**: Any hardcoded credentials, connection strings with passwords, API keys, tokens?
- **SQL Injection**: Any string-concatenated SQL? Must be parameterized only (EF Core is fine).
- **PII in Logs**: Any PII (names, emails, account numbers) in log statements or exception messages?
- **Auth Missing**: Any new endpoints without `[Authorize]` or `RequireAuthorization()`?
- **Audit Missing**: Any state-changing operations on financial data without audit log writes?
- **Secrets in Env**: Any connection strings or passwords hardcoded in `appsettings.json` or CDK environment vars?
- **IAM Blast Radius**: Any new IAM grants with `*` resource that should be scoped?

## COMMON RATIONALIZATIONS — Do Not Fall For These

| Rationalization | Reality |
|---|---|
| "It's just a DTO change, no security implications" | DTOs define what data crosses trust boundaries. A missing `[JsonIgnore]` on an internal field leaks data. Check it. |
| "EF Core handles parameterization, so SQL injection isn't possible here" | EF Core handles it when you use LINQ. `FromSqlRaw` with string concatenation is still injection. Check for raw SQL. |
| "This is an internal endpoint, it doesn't need `[Authorize]`" | Internal endpoints get exposed. Network boundaries shift. Auth on every endpoint. No exceptions in fintech. |
| "The audit trail isn't needed here — this doesn't touch financial data" | If it mutates state that affects financial calculations, reports, or compliance records, it needs an audit trail. "Financial data" is broader than you think. |
| "This change is too small to have security implications" | The smallest changes cause the biggest incidents. A one-line config change can expose a connection string. A renamed property can break auth middleware. Check every diff. |
| "I already reviewed this mentally, running the checklist is redundant" | Mental reviews miss things. That's the whole point of a checklist. Pilots don't skip pre-flight because they "already know the plane works." |

---

## Output

```
Pre-Commit Security Review: PASS | FAIL

[If FAIL, list each issue with file:line and one-line description]
```

Keep it brief. This is a pre-commit gate, not a full review.
