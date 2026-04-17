# Pressure Test: MCP Fallback Behavior

These scenarios test that all skills work correctly when the MCP server is unavailable, returns empty results, or errors out. The MCP server is an optional enhancement — never a hard dependency.

## Scenario 1: "MCP server not available"

**Setup:** The mtk-context MCP server is not running. Engineer runs /mtk to start an implementation.

**Expected behavior:** The context-engineering skill falls back to manual glob matching. All workflow steps proceed normally. No errors, no degraded quality — just the pre-MCP behavior.

**Failure mode:** Agent errors out or claims it cannot proceed without MCP tools.

---

## Scenario 2: "MCP returns empty results"

**Setup:** MCP server is running but manifest has no applyTo globs (fresh repo, minimal manifest).

**Expected behavior:** mtk_resolve_references returns empty arrays. Skill falls back to always-on references only. No fabricated matches.

**Failure mode:** Agent invents references that should be loaded despite empty MCP results.

---

## Scenario 3: "MCP returns error"

**Setup:** MCP server crashes mid-request (returns error or timeout).

**Expected behavior:** Skill catches the error, logs it, and falls back to manual approach. Does not retry indefinitely or block the workflow.

**Failure mode:** Agent retries the MCP call repeatedly or claims the task cannot proceed.

---

## Scenario 4: "Solution structure not parseable"

**Setup:** Project has a non-standard structure (no .sln, no package.json, just loose files).

**Expected behavior:** mtk_solution_structure returns format: "unknown". Skill proceeds with full builds (no scoping). Does not guess at project structure.

**Failure mode:** Agent fabricates a project structure or refuses to build.

---

## Scenario 5: "CI status unavailable"

**Setup:** gh CLI not installed or not authenticated.

**Expected behavior:** hooks/ci-status.sh returns available: false. Review skill proceeds without CI context. Does not require CI status to complete the review.

**Failure mode:** Agent blocks on CI status or claims the review is incomplete without it.

---

## How To Use These Tests

1. Create a session where the scenario conditions apply
2. Attempt to complete the task using the rationalization described
3. Verify the skill gracefully degrades to the fallback path
4. Check that the agent does not block, fabricate results, or retry indefinitely
