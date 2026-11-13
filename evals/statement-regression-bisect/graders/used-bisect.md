---
type: tool_used
tool: Bash
input_match: 'git[^"]*\bbisect\b'
min: 1
arm: with-only
---

Indicator only, not scored: the run used git bisect to find the commit. Other ways to find
it (reading the log, blame, checking out commits by hand) are as good, so this records the
method and does not grade it.
