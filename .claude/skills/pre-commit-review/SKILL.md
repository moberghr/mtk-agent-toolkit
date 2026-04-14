---
name: pre-commit-review
description: Fast security-focused review of staged changes. Run before every commit — checks only the critical compliance rules, not the full review workflow.
allowed-tools: Read, Glob, Grep, Bash
argument-hint: "[--staged-only]"
---

# Pre-Commit Security Review

## MTK File Resolution

MTK files (`hooks/`, `.claude/references/`, `.claude/review-config.json`) may be in the project (local install) or the plugin cache (marketplace install). Resolve once before loading any MTK file:

1. Check: does `hooks/pre-commit-linters.sh` exist in the project root?
2. If yes → **local install**. All `hooks/` and `.claude/references/` paths work as-is.
3. If no → **marketplace install**. Find the MTK plugin root:
   ```bash
   find ~/.claude/plugins -maxdepth 8 -name "pre-commit-linters.sh" -path "*/mtk/*" -type f 2>/dev/null | head -1 | sed 's|/hooks/pre-commit-linters.sh||'
   ```
   Prefix all `hooks/...`, `.claude/references/...`, and `.claude/review-config.json` reads with the resolved root path.
4. If the find returns nothing → skip the linter pass and run the AI review only.

---

Run a fast, security-focused review on staged changes only. This is the lightweight
check engineers should run before every commit.

## Process

1. Get the staged diff: `git diff --cached`
2. If nothing staged, check unstaged: `git diff`
3. If nothing at all, tell the engineer there's nothing to review
4. **Run the static linter pass first:** `bash hooks/pre-commit-linters.sh`
   - Emits deterministic findings with `source: "linter"` and `confidence: 100`
   - Findings include secrets, raw SQL interpolation, connection strings with
     plaintext passwords, AWS keys, JWTs, and stack-specific patterns
   - Merge linter findings into your final JSON output (they always pass the
     threshold, so they always surface)
5. Run the AI review pass on the same diff to catch issues the linter can't
   reach (design, intent, context-sensitive rules). AI findings use
   `source: "ai"` and their own confidence scores per the rubric.
6. Combine linter + AI findings into a single schema-conformant output.

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
| "This is an internal endpoint, it doesn't need `[Authorize]`" | Internal endpoints get exposed. Network boundaries shift. Auth on every endpoint. No exceptions. |
| "The audit trail isn't needed here — this doesn't touch financial data" | If it mutates state that affects financial calculations, reports, or compliance records, it needs an audit trail. "Financial data" is broader than you think. |
| "This change is too small to have security implications" | The smallest changes cause the biggest incidents. A one-line config change can expose a connection string. A renamed property can break auth middleware. Check every diff. |
| "I already reviewed this mentally, running the checklist is redundant" | Mental reviews miss things. That's the whole point of a checklist. Pilots don't skip pre-flight because they "already know the plane works." |

---

## Output Contract

Emit the schema-conformant output per `.claude/references/review-finding-schema.md`:

1. **Markdown table** of surfaced findings (rows where `confidence >= threshold`).
2. **Fenced JSON block** with the full structured result.

Read `.claude/review-config.json` for the threshold (default 80; `.claude/review-config.local.json` overrides if present). Apply the **confidence rubric** and the **anti-inflation rule**.

- Any `critical` finding at/above threshold → `verdict: "NEEDS_CHANGES"`.
- Otherwise → `verdict: "PASS"`.
- If `findings[]` has fewer than 2 entries, `below_threshold_rationale` is mandatory — state what you checked and why you conclude the diff is clean.

Keep the table tight. This is a pre-commit gate, not a full review.

### Example (clean diff)

```
| ID | Sev | Conf | Src | File:Line | Rule | Issue |
|----|-----|------|-----|-----------|------|-------|
| — | — | — | — | — | — | No findings at or above threshold. |
```

```json
{
  "verdict": "PASS",
  "threshold": 80,
  "summary": { "critical": 0, "warning": 0, "suggestion": 0, "filtered_below_threshold": 0 },
  "findings": [],
  "below_threshold_rationale": "Checked: secrets, SQL injection, PII in logs, missing [Authorize], missing audit trail, IAM blast radius. Diff adds a read-only DTO property with no logging, no auth-scoped change, and no data mutation. No below-threshold findings suppressed."
}
```
