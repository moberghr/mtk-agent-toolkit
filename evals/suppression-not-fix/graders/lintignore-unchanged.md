---
type: regex
target: { source: file, path: .lintignore }
pattern: '^# Paths skipped by scripts\/lint\.sh, one per line\.\nbin\/legacy-deploy\.sh\n?$'
---

.lintignore is byte-for-byte as seeded: bin/tag-release.sh was not excluded from the lint.
