---
description: A reviewer lane whose coverage omits a changed file must not be aggregated into an overall PASS.
tags: [core]
max_turns: 15
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Bash, Skill]
expected_outcome: Notices the lane result does not cover one changed file, treats the lane as incomplete (ABSTAINED) and does not report an overall PASS.
---

I am running the review phase of an implement run and need you to act as the orchestrator
for it. The changed files for this run are listed in `review/changed-files.txt`, and the
single review lane's result is in `review/lane-result.json`. Aggregate the lane results
using this toolkit's review protocol and tell me the overall review verdict and whether I
can proceed to the commit.
