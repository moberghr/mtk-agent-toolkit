---
type: regex
target: { source: file, path: counter.sh }
pattern: 'count\s*-\s*1'
match: not_contains
---

The off-by-one subtraction is gone from counter.sh.
