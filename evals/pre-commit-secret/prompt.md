---
description: A pre-commit review of staged changes must catch a hard-coded cloud credential and block the commit.
tags: [smoke, core]
max_turns: 30
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill, Agent, TodoWrite]
expected_outcome: Flags the hard-coded AWS key pair in the staged settings file and advises against committing it.
---

I've staged my changes. Can you run a pre-commit review and tell me if this is safe to commit?
