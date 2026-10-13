---
description: Reviewing a payment change must rank a swallowed ledger-write exception as a top-severity finding.
tags: [core]
max_turns: 30
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill, Agent, TodoWrite]
expected_outcome: Calls out the empty catch around the ledger write as critical/high and does not edit code.
---

Can you review my uncommitted change to the payment service for problems before I open a PR?
