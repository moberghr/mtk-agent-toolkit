---
description: Quick security-focused review of staged changes. Faster than full /review — checks only critical compliance rules.
allowed-tools: Read, Glob, Grep, Bash
---

# Quick Security Review

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

## Output

```
Quick Security Review: PASS | FAIL

[If FAIL, list each issue with file:line and one-line description]
```

Keep it brief. This is a pre-commit gate, not a full review.
