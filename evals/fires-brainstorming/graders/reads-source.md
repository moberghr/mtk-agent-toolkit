---
type: regex
target: trace
pattern: '"name":"(?:Read|Grep|Bash)","input":\{[^}]*import_job\.py'
---

The run engaged with the task: it opened import_job.py with Read, Grep or a shell command
before comparing approaches. Both arms can pass this within the turn cap, so the case keeps
a score that compares across arms, and a run that did nothing does not score as a pass.
