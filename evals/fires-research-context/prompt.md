---
description: A question that needs the current state of a library loads the web research skill.
tags: [routing, fires, research-context]
max_turns: 8
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill, TodoWrite, WebSearch, WebFetch]
expected_outcome: Loads the research skill to look up the current major version and its migration guidance; the brief itself is not graded.
---

We are still on Pydantic 1.10 (see requirements.txt). Before we plan the upgrade to the current major version, what changed that would affect models.py, and what is the recommended migration path today?
