---
description: A test that passed at an old tag and fails now must be traced to the commit that broke it, and fixed.
tags: [procedures, fix]
max_turns: 60
timeout_seconds: 1500
allowed_tools: [Read, Glob, Grep, Bash, Edit, Write, Skill, Agent, TodoWrite]
expected_outcome: Names commit 64fe993 ("Extract percent_of helper for discounts and tax") as the one that broke the tests, restores rounding of the discounted unit price, leaves the test expectation alone, and ends with tests/run.sh passing.
---

/mtk fix tests/run.sh, it was green when we tagged v1.2.0 and the invoice total test fails now. Need it green before the 1.3.0 release, can you find what broke it and fix it?
