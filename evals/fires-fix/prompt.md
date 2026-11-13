---
description: A failing-test report that never names the workflow loads the fix skill.
tags: [routing, fires, fix]
max_turns: 8
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill, TodoWrite]
expected_outcome: Loads the fix skill in the first turns and starts on cart.sh; finishing the change is not graded.
---

test_cart.sh fails on the empty-cart check: cart_total prints nothing for an empty cart, but it should print 0. Can you sort it out?
