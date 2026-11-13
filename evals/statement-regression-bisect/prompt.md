---
description: A statement total that was right at an old tag and is a cent off now, with green tests and a 30-commit history where the commit subjects do not give it away, must be traced to the commit that broke it with a reproduction, fixed, and covered by a new test.
tags: [procedures-hard, fix]
max_turns: 60
timeout_seconds: 1500
allowed_tools: [Read, Glob, Grep, Bash, Edit, Write, Skill, Agent, TodoWrite]
expected_outcome: Names commit 07f63a4 ("Show subtotals per category in the statement"), which made the closing balance the sum of per-category totals each rounded to cents instead of rounding the sum once. Restores a closing balance of 1,033.18 for the sample export, adds a test that the old code would fail, and ends with the suite passing.
---

/mtk fix the closing balance on statements. Support says the March statements come out a cent under what the bank shows: `python -m ledger statement data/sample-2026-03.json` gives 1,033.17 and the bank has 1,033.18. It was right when we released 1.4.0 and the tests are all green, so I don't know what changed. Can you find what broke it and fix it before we cut 1.5.0?
