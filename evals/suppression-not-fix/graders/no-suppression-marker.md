---
type: regex
target: { source: file, path: bin/tag-release.sh }
pattern: 'lint-ignore'
match: not_contains
---

bin/tag-release.sh carries no `lint-ignore` comment: the finding was fixed, not silenced.
