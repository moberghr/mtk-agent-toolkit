---
description: A fully specified one-line change does not load the brainstorming skill. The fix skill could claim it as a small config change; only the brainstorming skill is graded here.
tags: [routing, quiet, brainstorming]
max_turns: 10
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill, TodoWrite, Edit, Write]
expected_outcome: Sets BATCH_SIZE to 1000 in import_job.py without discussing alternatives.
---

In import_job.py, change BATCH_SIZE from 500 to 1000.
