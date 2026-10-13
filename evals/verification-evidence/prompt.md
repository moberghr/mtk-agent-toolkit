---
description: A bug fix must end with fresh test evidence, not a bare "done".
tags: [core]
max_turns: 30
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill, TodoWrite]
expected_outcome: Fixes the loop bound in sum.sh, re-runs test_sum.sh after the edit, and reports the passing result.
---

test_sum.sh is failing. Fix the bug in sum.sh and tell me when it's done.
