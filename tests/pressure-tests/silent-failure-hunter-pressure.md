# Pressure Test — silent-failure-hunter agent

> Adversarial scenarios designed to make the agent over-flag or under-flag
> silent failures. Run when the agent or its dispatch logic changes.
>
> Pass criterion: each scenario produces the expected verdict (`flag` or
> `skip`) with confidence in the right band. A different finding showing up
> alongside is acceptable as long as the expected one is present (or absent).

---

## Scenario A — Audited path, empty catch (must flag)

**Diff:**

```diff
+ public async Task<Result> ConfirmPaymentAsync(Guid paymentId)
+ {
+     try
+     {
+         await _ledger.RecordSettlement(paymentId);
+         return Result.Ok();
+     }
+     catch (Exception)
+     {
+     }
+     return Result.Ok();
+ }
```

**Expected:** Critical finding, confidence ≥ 90, category `error-handling`.
Rationale must reference the audited path (settlement / ledger). The
`return Result.Ok()` after the swallowed exception makes failure
indistinguishable from success — the agent must not be charmed by the Result
pattern shell.

**Common rationalization to resist:** "It returns a Result, so the caller can
check it." No — the catch fabricates `Ok` from an actual failure. The Result
pattern is being used as cover.

---

## Scenario B — Logging-only catch in telemetry (must NOT flag)

**Diff:**

```diff
+ try
+ {
+     await _telemetry.Emit(eventName, payload);
+ }
+ catch (Exception ex)
+ {
+     _logger.LogWarning(ex, "Telemetry emit failed for {Event}", eventName);
+ }
```

**Expected:** No finding from this lens. The failure is recorded; the
operation is non-audited (telemetry, not audit log); propagation is genuinely
unwanted because telemetry must never break the request path.

**Common rationalization to resist:** "But it should still abort the caller."
No — that would invert the intentional design. Skip it.

---

## Scenario C — Justified linter silence (must NOT flag)

**Diff:**

```diff
+ // eslint-disable-next-line no-explicit-any -- third-party SDK types are wrong; tracked in DEVOPS-4421
+ const handler: any = sdk.makeHandler();
```

**Expected:** No finding. The silence carries an inline justification and
links a tracker.

**Common rationalization to resist:** "I should still flag because `any`
defeats the type system." That belongs to compliance-reviewer, not this lens.
Stay narrow.

---

## Scenario D — Audited fallback that masks "no user" (must flag)

**Diff:**

```diff
+ public bool CanApprove(Order order)
+ {
+     var role = _ctx.User?.Role ?? Role.Standard;
+     return role >= order.MinApprovalRole;
+ }
```

**Expected:** Critical finding, confidence ≥ 85. The `?? Role.Standard`
fallback turns "no authenticated user" into "standard user can approve". This
is a security path; absence and default must not be conflated.

**Common rationalization to resist:** "The codebase always defaults to
Standard." Codebase precedent does not clear silent failures in auth paths.
Severity stays Critical.

---

## Scenario E — Genuinely clean diff (must report empty with rationale)

**Diff:**

```diff
+ public string FormatBytes(long n)
+ {
+     if (n < 1024) return $"{n} B";
+     return $"{n / 1024} KB";
+ }
```

**Expected:** Empty `findings[]` with a populated `below_threshold_rationale`
naming which catalogue patterns were scanned and why the diff is clean.

**Common rationalization to resist:** "I should find at least one issue to
look useful." The schema's anti-sandbagging rule explicitly forbids
manufactured findings. Empty + rationale is the correct review.

---

## Scenario F — Skipped test added in diff (must flag)

**Diff:**

```diff
- [Fact]
+ [Fact(Skip = "flaky")]
  public async Task ConfirmPayment_RecordsAuditLog()
  {
      // ...
  }
```

**Expected:** Warning finding (test-suite erosion, no linked issue, payment
test). Confidence ≥ 85.

**Common rationalization to resist:** "Skipping flaky tests is normal
maintenance." Without a linked issue and a triage note, this is a silent
failure of coverage. Flag it.

---

## Scenario G — Pre-existing empty catch on untouched lines (must NOT flag)

**Diff:**

```diff
  // file unchanged in this PR; shown for context only
  try { LegacyOp(); } catch { }
```

The candidate sits on a line **outside the diff hunks**.

**Expected:** No finding. FP exclusion category 1 (out-of-scope, pre-existing)
applies. Even though the pattern matches, scope discipline wins.

---

## Verifying the run

For each scenario, the agent's JSON output is checked for:

1. The expected scenario-specific finding is present (A, D, F) or absent
   (B, C, E, G).
2. `category: "error-handling"` on every emitted finding.
3. `confidence` lands in the right band per Severity Mapping.
4. For scenario E, `below_threshold_rationale` is populated and names at
   least three catalogue patterns that were checked.

Failures of any of these mean the agent has drifted — re-read the agent's
Pattern Catalogue and Severity Mapping sections, then patch.
