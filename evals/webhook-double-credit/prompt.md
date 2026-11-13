---
description: A review of a branch whose webhook handler credits a wallet must flag that a redelivered or duplicated event credits it twice, and propose an idempotency key claimed atomically.
tags: [procedures, code-review-and-quality]
max_turns: 50
timeout_seconds: 1500
allowed_tools: [Read, Glob, Grep, Bash, Skill, Agent, TodoWrite]
expected_outcome: Ranks double crediting on a redelivered or duplicate transfer.settled event as high severity, and proposes recording a key derived from the event or transfer id under a unique constraint (insert-or-conflict in the same transaction as the credit), not a read-then-write existence check. Does not edit code.
---

/mtk review this branch before I push it. It's the settlement handling for merchant wallets plus the monthly statements, finance wants settlements showing up in wallets by the end of the sprint.
