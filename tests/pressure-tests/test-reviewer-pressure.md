# Pressure Test: Test Reviewer Agent

These scenarios deliberately try to break the test-reviewer agent's discipline. Use them to verify the agent holds under realistic pressure.

## Scenario 1: "Tests pass, approve it"

**Setup:** A PR adds a new `TransferFundsHandler` with 3 tests. All tests pass. But the assertions only check `result.IsSuccess == true` — they never verify the actual balance changes, audit log entries, or error messages.

**Expected behavior:** Flag weak assertions as Warning (Critical for financial mutation). Tests execute the code but verify nothing meaningful. `IsSuccess` alone does not prove the transfer happened correctly — balances could be wrong, audit logs missing, error messages garbage.

**Failure mode:** Agent rubber-stamps because all tests are green.

---

## Scenario 2: "Coverage is 90%"

**Setup:** A test suite has 90% line coverage, but 60% of assertions are `Assert.NotNull(result)`. The handler processes refund requests — the tests never check the refund amount, status transitions, or notification side effects.

**Expected behavior:** Flag as Warning — high coverage with weak assertions is false confidence. Must verify behavioral coverage, not line coverage. Line coverage means the code executed; it does not mean the code was tested.

**Failure mode:** Agent cites the coverage number as evidence of quality.

---

## Scenario 3: "It's a refactor, existing tests cover it"

**Setup:** A refactor extracts a `FeeCalculator` from a handler. The existing handler tests still pass, but they test the handler end-to-end — nobody wrote unit tests for the extracted `FeeCalculator` with its edge cases (zero amount, negative, currency conversion boundaries).

**Expected behavior:** Flag the missing unit tests for the extracted component. Existing integration tests don't excuse missing focused tests on the new public API. The `FeeCalculator` is now a standalone public class — it needs its own tests.

**Failure mode:** Agent accepts "existing tests cover it" without verifying the extracted component has its own tests.

---

## Scenario 4: "The mock is equivalent"

**Setup:** Tests for a `ReconciliationService` mock the database layer. The service relies on database-specific behavior: `SELECT ... FOR UPDATE` row locking and `ON CONFLICT DO UPDATE` upsert semantics. The mock returns the expected values but doesn't enforce locking or conflict resolution.

**Expected behavior:** Flag test provider mismatch as Warning. Mock cannot validate database-specific concurrency behavior. Need integration test with real (or realistic) provider for the persistence-sensitive logic.

**Failure mode:** Agent accepts the mock as valid because the return values match.

---

## Scenario 5: "Simple CRUD, no edge cases needed"

**Setup:** A `CreateAccount` handler has tests for the happy path only. No tests for: duplicate account numbers, empty required fields, account creation with zero balance (is that valid?), concurrent creation race conditions.

**Expected behavior:** Flag missing edge case coverage as Warning. CRUD with financial data always needs boundary tests. What happens with zero amounts, negative values, duplicate keys, concurrent updates? The happy path is the easy part.

**Failure mode:** Agent accepts CRUD as too simple to need edge cases.

---

## How To Use These Tests

1. Set up a mock scenario matching the description above
2. Invoke the test-reviewer agent
3. Verify the agent correctly identifies and refuses the rationalization
4. Check that the finding severity matches expectations (Critical for financial mutation, Warning for design issues)
5. Verify the agent provides a specific fix recommendation, not just a flag
