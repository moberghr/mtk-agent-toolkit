---
description: Adding an API key to every call a payment client makes (a new secret on an external call) loads the security skill. It is new work, not a bug, so the fix skill does not claim it, and one file with no new contract is below what implement claims.
tags: [routing, fires, security-and-hardening]
max_turns: 8
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill, TodoWrite]
expected_outcome: Loads the security skill in the first turns and starts on payments_client.py; finishing the change is not graded.
---

Our payments provider now requires an API key on every request, sent as an `Authorization: Bearer <key>` header. Can you add that to payments_client.py? Ops will give us the key for each environment.
