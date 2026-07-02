---
description: Capture procedure for the `browser` evidence channel — persist screenshot/console/network artifacts via Playwright MCP, with an explicit degraded fallback when MCP is unavailable
globs: ["**/*"]
alwaysApply: false
---

# Evidence Capture — `browser` Channel

The `browser` evidence channel in `verification-before-completion` verifies a visual or functional check in a browser. Unlike `test-run` (test output) or `script-output` (captured stdout), a browser check has no artifact by default — it is just a claim. This reference defines how to persist what was actually observed so the criterion is backed by evidence, not assertion.

## Capture procedure (Playwright MCP available)

When Playwright MCP tools are available in-session, capture around the observable behavior being verified:

1. Drive the browser to the state under test (`browser_navigate`, then the interaction steps the criterion describes).
2. Call the three capture tools around that observable behavior:
   - `browser_take_screenshot` → the visual proof of the state.
   - `browser_console_messages` → console output (errors/warnings that would otherwise be invisible).
   - `browser_network_requests` → the network activity behind the behavior.
3. Persist all three under `docs/specs/<slug>.evidence/<criterion-id>/`:

   ```
   docs/specs/<slug>.evidence/<criterion-id>/
     screenshot.png     # from browser_take_screenshot
     console.log        # text dump from browser_console_messages
     network.json       # JSON dump from browser_network_requests
   ```

   `<slug>` matches the spec sidecar slug; `<criterion-id>` is the `success_criteria[]` id (e.g. `SC3`).
4. Cite the evidence directory path in the completion evidence table alongside the criterion.

## Sensitive content — scrub before persisting

Evidence artifacts are committed alongside the spec, so treat them as repo content, not scratch output (see `security-checklist.md`; for regulated data, `domain-finance.md`):

- **`network.json`**: strip `Authorization`/`Cookie`/`Set-Cookie` headers, session tokens, and API keys before writing. Redact request/response bodies containing account numbers, personal data, or other regulated state — keep URL, method, and status; replace redacted values with `"<redacted>"`.
- **`screenshot.png`**: capture only the state the criterion asserts. If the screen shows real customer or account data, reproduce against test data or crop/mask before persisting.
- **`console.log`**: scan for leaked tokens or connection strings before committing.

If an artifact cannot be scrubbed, do not commit it — keep it local, cite the path with a note that it is untracked, and gitignore `docs/specs/*.evidence/` in that repo.

## Degraded path (Playwright MCP unavailable)

When Playwright MCP is **not** available in-session, the `browser` channel falls back to a plain textual description of what was observed. This is a genuine limitation, not an equivalent:

- State the fallback **explicitly** in the completion table — e.g. `browser (no MCP): described only, no artifact captured`.
- **Never** silently claim `browser` evidence without either an artifact directory or an explicit fallback note. A `browser` row with neither is not verified.

## Completion table examples

| criterion | verdict | evidence |
|---|---|---|
| SC3 | verified | `browser → docs/specs/2026-07-01-checkout.evidence/SC3/ (screenshot.png, console.log, network.json)` |
| SC4 | verified | `browser (no MCP): described only — cart badge updated to "2" after add; no artifact captured` |

## Rule

- Any `browser` criterion cites either its `docs/specs/<slug>.evidence/<criterion-id>/` artifact directory or an explicit no-MCP fallback note. There is no third option.
