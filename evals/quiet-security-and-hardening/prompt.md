---
description: Raising a model token limit shares the word token with auth code but touches no auth, secret, audit trail or external input, so the security skill stays unloaded. The fix skill could claim it as a small config change; only the security skill is graded here.
tags: [routing, quiet, security-and-hardening]
max_turns: 10
timeout_seconds: 240
allowed_tools: [Read, Glob, Grep, Skill, TodoWrite, Edit, Write]
expected_outcome: Sets MAX_TOKENS to 4000 in summarize.py and changes nothing else.
---

The release-note summaries from summarize.py get cut off mid-sentence. Raise the token limit there from 2000 to 4000.
