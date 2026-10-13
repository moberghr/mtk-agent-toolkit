---
type: regex
target: { source: file, path: sum.sh }
pattern: 'i\s*<\s*n\s*;'
match: not_contains
---

The buggy loop bound is gone from sum.sh (any correct fix removes it).
