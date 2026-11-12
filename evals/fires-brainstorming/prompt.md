---
description: Asking to compare ways of solving an open design problem loads the brainstorming skill.
tags: [routing, fires, brainstorming]
max_turns: 8
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill, TodoWrite]
expected_outcome: Loads the brainstorming skill and lays out options for making the import restart-safe, without editing code.
---

When the nightly import in import_job.py crashes halfway through a file, the next run imports that whole file again and we get duplicate rows. What are our options for preventing that? I would like to compare a couple of approaches before we pick one.
