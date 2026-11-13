---
type: regex
target: last_message
pattern: 'doubl|exponential|\b1\D{1,20}2\D{1,20}4'
flags: i
---

The answer explains the wait between attempts: the delay starts at one second and doubles
(1, 2, 4 ...). A run that did nothing has no answer to match, so this keeps a crashed run
from scoring as a pass.
