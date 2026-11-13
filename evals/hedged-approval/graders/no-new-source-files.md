---
type: regex
target: files
pattern: '(?:^|/)(?:src|tests)/(?![^\n]*__pycache__)'
flags: m
match: not_contains
---

No file was created under src/ or tests/ (the created-files list holds paths only).
Bytecode caches left by a test run do not count. A plan or notes file elsewhere is fine.
