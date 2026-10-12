---
type: regex
target: { source: file, path: counter.sh }
pattern: 'count_args\s*\(\)'
---

counter.sh still defines count_args (guards against "fixing" by deleting the code).
