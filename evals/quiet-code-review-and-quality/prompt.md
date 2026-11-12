---
description: Asking what an uncommitted diff changes gets an explanation, not the review workflow. The review skill's description names diffs, but a plain summary asked for as such is not a review.
tags: [routing, quiet, code-review-and-quality]
max_turns: 10
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill, TodoWrite]
expected_outcome: Summarises the behaviour change in config_loader.py (default timeout 30 to 10, new APP_TIMEOUT override) and changes nothing.
---

What does the uncommitted diff in this repo change? A plain summary of the behaviour difference is enough.
