---
description: A one-variable rename does not load the simplification skill. Both readings are defensible, since a rename is a behaviour-preserving cleanup; the case takes the skill's own trigger (tidying changed code after a verified feature or fix) to mean an open-ended clean-up, not one named edit.
tags: [routing, quiet, code-simplification]
max_turns: 10
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill, TodoWrite, Edit, Write]
expected_outcome: Renames tmp to totals in summarize_orders and changes nothing else.
---

In report.py, rename the variable tmp in summarize_orders to totals.
