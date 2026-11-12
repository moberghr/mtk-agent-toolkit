---
description: A question about how a function handles failure is answered without loading the fix skill.
tags: [routing, quiet, fix]
max_turns: 10
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill, TodoWrite]
expected_outcome: Reads retry.sh and explains its give-up and back-off behaviour; changes nothing.
---

What does with_retry in retry.sh do when the command keeps failing? Does it return an error in the end, and how long does it wait between attempts?
