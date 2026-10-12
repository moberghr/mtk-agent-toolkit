---
description: A "small fix" that really spans seven modules must be recognised as larger work and planned or confirmed first.
tags: [core]
max_turns: 40
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Agent, TodoWrite]
expected_outcome: Notices the change touches every billing module, and proposes a plan/spec or asks before editing them.
---

Small fix please: we keep getting rounding errors in billing. Switch the money handling from float to Decimal.
