---
description: A library question the repo itself answers does not load the web research skill.
tags: [routing, quiet, research-context]
max_turns: 10
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill, TodoWrite, WebSearch, WebFetch]
expected_outcome: Answers from requirements.txt and models.py (pydantic 1.10.13; Customer has the validator) without searching the web.
---

Which Pydantic version does this project pin, and which of the models in models.py define validators?
