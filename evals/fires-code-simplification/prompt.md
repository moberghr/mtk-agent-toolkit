---
description: Asking to tidy a working, tested function without changing behaviour loads the simplification skill.
tags: [routing, fires, code-simplification]
max_turns: 8
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill, TodoWrite]
expected_outcome: Loads the simplification skill and starts on report.py; finishing the change is not graded.
---

My last commit added summarize_orders to report.py. It works and the tests pass, but it is a tangle of nested ifs. Can you tidy it up without changing what it does?
