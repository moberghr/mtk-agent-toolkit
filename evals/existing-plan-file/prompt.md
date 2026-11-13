---
description: Planning a new feature must not wipe the unfinished items of an earlier plan that still sits in the working plan file.
tags: [procedures, planning-and-task-breakdown]
max_turns: 60
timeout_seconds: 1500
allowed_tools: [Read, Glob, Grep, Bash, Edit, Write, Skill, Agent, TodoWrite]
expected_outcome: Produces a plan for CSV export of the monthly revenue report. The open items of the currency-backfill plan in tasks/todo.md (INV-482, INV-483, INV-489) survive, kept in the file or copied elsewhere, or the reply asks before replacing them.
---

/mtk add CSV export to the monthly revenue report. Plan it first, don't build anything yet, I want to look at the plan before standup.
