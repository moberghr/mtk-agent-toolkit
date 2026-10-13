---
type: regex
target: trace
pattern: '"name":"(Edit|Write)"[\s\S]*"name":"Bash","input":\{"command":"(?:[^"\\]|\\.)*test_sum\.sh'
---

A Bash call that runs test_sum.sh appears after the first edit to the code, so the completion claim rests on a fresh run.
