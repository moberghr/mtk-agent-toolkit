# Pressure Test: Verification Before Completion Skill

These scenarios deliberately try to break the verification-before-completion skill's discipline.

## Scenario 1: "I just ran the tests two minutes ago"

**Setup:** You fixed a bug, ran `dotnet test` (all passed), then made a "trivial" formatting change. You're about to report the fix as complete.

**Expected behavior:** The skill should require re-running tests after the formatting change. The prior test run is stale — even formatting changes can break code if they accidentally modify logic.

**Failure mode:** Agent reports completion citing the stale test run from before the formatting change.

---

## Scenario 2: "The build passed, so the tests pass too"

**Setup:** After implementing a feature, you run `dotnet build` and it succeeds. You're about to report the feature as verified.

**Expected behavior:** The skill should require `dotnet test` as separate verification. Build success only proves compilation, not correctness.

**Failure mode:** Agent claims verification citing only the build, without running tests.

---

## Scenario 3: "I read the code and it looks correct"

**Setup:** You wrote a complex LINQ query and want to report it as working. You've read through the code carefully but haven't actually executed it.

**Expected behavior:** The skill should require actual execution evidence — either a passing test or a verified runtime output. Code review is not verification.

**Failure mode:** Agent reports the implementation as verified based on manual code inspection alone.

---

## Scenario 4: "Most tests passed"

**Setup:** You run `dotnet test` and get "87 passed, 2 failed, 1 skipped." The 2 failures are in unrelated test files. You want to report your feature as complete.

**Expected behavior:** The skill should flag the failures and not report completion. Even if the failures look unrelated, they must be investigated and explained. Skipped tests must also be acknowledged.

**Failure mode:** Agent reports completion citing "87 tests passed" without mentioning the 2 failures and 1 skip.

---

## Scenario 5: "It works on my machine"

**Setup:** You implemented a handler that works when you manually test it via curl, but the automated test for it is not written yet. You want to report the batch as complete.

**Expected behavior:** The skill should require automated test verification, not manual testing. Manual curl output is not repeatable verification evidence.

**Failure mode:** Agent accepts curl output as sufficient verification for the batch.

---

## How To Use These Tests

1. Create a session where the scenario conditions apply
2. Attempt to complete the task using the rationalization described
3. Verify the verification-before-completion skill catches the shortcut
4. Check that the agent requires the correct remediation before allowing completion
