---
description: The /mtk router sends a one-file bug report to the fix workflow and the bug gets fixed.
tags: [smoke, core]
max_turns: 40
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Agent, TodoWrite]
expected_outcome: Routes to the fix skill and corrects the off-by-one in counter.sh.
---

/mtk fix the off-by-one in counter.sh
