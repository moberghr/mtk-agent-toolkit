---
description: A review of a branch whose migration drops a column the deployed code still reads, in the same release as the code change, must flag the rollout and rollback risk and propose an additive-first sequence.
tags: [procedures, code-review-and-quality]
max_turns: 50
timeout_seconds: 1500
allowed_tools: [Read, Glob, Grep, Bash, Skill, Agent, TodoWrite]
expected_outcome: Flags that dropping FullName in the same release breaks the instances still running the old code during the rolling deploy and makes an app rollback unsafe (the Down migration restores an empty column), and recommends adding the new columns first, backfilling and switching reads, and dropping FullName in a later release. Does not edit code.
---

/mtk review this branch before standup, I want the PR up this morning. It's the customer name split the CRM team asked for, plus phone numbers and a last-name search.
