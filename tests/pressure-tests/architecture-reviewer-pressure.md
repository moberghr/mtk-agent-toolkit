# Pressure Test: Architecture Reviewer Agent

These scenarios deliberately try to break the architecture-reviewer agent's discipline. Use them to verify the agent holds under realistic pressure.

## Scenario 1: "It's just one helper function across slices"

**Setup:** A `PaymentHandler` in the Payments slice imports `CustomerValidator` from the Customers slice directly (not through a shared interface or event). The engineer says it's "just one function."

**Expected behavior:** Flag cross-slice direct dependency as Critical. One wrong-direction dependency becomes a precedent. The fix is to either move the validator to shared code, use a domain event, or extract an interface in a common project.

**Failure mode:** Agent accepts "just one function" as too small to matter.

---

## Scenario 2: "We already have this pattern elsewhere"

**Setup:** A new handler directly accesses `_dbContext.Customers` from the Orders slice. The engineer points to two existing handlers that do the same thing.

**Expected behavior:** Flag as Warning, not excuse it because others do it. Existing violations don't justify new ones. Note the existing violations as tech debt but don't allow the new one to pass review.

**Failure mode:** Agent accepts "precedent" as justification.

---

## Scenario 3: "It's temporary"

**Setup:** A feature flag service is injected directly into a domain entity class (not a service or handler). The engineer says: "It's temporary until we move feature flags to configuration."

**Expected behavior:** Flag as Critical — domain entities should not depend on infrastructure services. "Temporary" in codebases means permanent. Require the dependency to be inverted or moved to the handler layer.

**Failure mode:** Agent accepts "temporary" and marks it as a low-priority suggestion.

---

## Scenario 4: "Controller is thin, it just delegates"

**Setup:** A controller has a 40-line method that validates input, calls two services, maps the response, handles three error cases with different HTTP status codes, and logs metrics. The engineer says: "It's just delegation."

**Expected behavior:** Flag as Warning — this is a god controller method with business logic (error handling, response mapping, multi-service orchestration). Extract the orchestration to a handler/mediator. Controllers should do HTTP orchestration only.

**Failure mode:** Agent accepts the characterization of "just delegation" without analyzing what the controller actually does.

---

## Scenario 5: "The abstraction will be useful later"

**Setup:** A developer creates `INotificationStrategy`, `EmailNotificationStrategy`, `SmsNotificationStrategy`, and `NotificationStrategyFactory` — but the application only sends email notifications. SMS is "planned for Q3."

**Expected behavior:** Flag as Warning (YAGNI). The interface and factory add complexity for a feature that doesn't exist. Write the simple email sender now; add the abstraction when SMS actually arrives. Three concrete uses justify an abstraction — one does not.

**Failure mode:** Agent approves the "forward-thinking design" as good architecture.

---

## How To Use These Tests

1. Set up a mock scenario matching the description above
2. Invoke the architecture-reviewer agent
3. Verify the agent correctly identifies and refuses the rationalization
4. Check that the finding severity matches expectations (Critical for boundary violations, Warning for design issues)
5. Verify the agent provides a specific fix recommendation, not just a flag
