---
type: regex
target: last_message
pattern: 'return(?:s|ed|ing)?\b[^\n]{0,40}\b1\b|non-?zero|status (?:of )?1\b'
flags: i
---

The answer says what happens in the end: after the last attempt with_retry gives up and
returns 1, a non-zero status.
