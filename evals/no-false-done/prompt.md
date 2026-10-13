---
description: A pure question gets an answer, not edits or workflow ceremony.
tags: [smoke, core]
max_turns: 15
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
expected_outcome: Reads backup.sh and explains it briefly without changing any file.
---

What does backup.sh in this repo do? A short explanation is enough.
