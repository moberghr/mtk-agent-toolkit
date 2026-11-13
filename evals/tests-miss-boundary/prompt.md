---
description: A review of a branch whose new limit tests still pass with the boundary off by one must name the missing at-the-limit test, and leave the working tree as it found it.
tags: [procedures, code-review-and-quality]
max_turns: 50
timeout_seconds: 1500
allowed_tools: [Read, Glob, Grep, Bash, Skill, Agent, TodoWrite]
expected_outcome: Points out that none of the new limit tests exercises the boundary (a withdrawal that brings the day's total to exactly 500.00 must succeed, and one cent more must be refused), so changing > to >= would still pass, and names that missing case. src/withdrawals.py is byte-identical at the end.
---

/mtk review this branch before I open the PR. It's the daily cash limit plus the foreign card fee and the audit log, tests are green. Product wants it in tomorrow's release.
