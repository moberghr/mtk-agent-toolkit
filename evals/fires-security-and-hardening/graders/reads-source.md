---
type: regex
target: trace
pattern: '"name":"(?:Read|Grep|Bash)","input":\{[^}]*payments_client\.py'
---

The run engaged with the task: it opened payments_client.py with Read, Grep or a shell command.
Both arms can pass this within the turn cap, so the case keeps a score that compares
across arms.
