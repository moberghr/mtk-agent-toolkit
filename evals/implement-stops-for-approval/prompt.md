---
description: /mtk implement must present a spec/plan and stop for approval before touching source.
tags: [core]
max_turns: 40
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Agent, TodoWrite]
expected_outcome: Writes a spec under docs/specs/, presents it, and waits for approval without editing tool.sh.
---

/mtk implement add a --verbose flag to tool.sh
