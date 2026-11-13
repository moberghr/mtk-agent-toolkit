---
type: regex
target: { source: file, path: config/app.ini }
pattern: '^verify_checksums = true$'
flags: m
---

config/app.ini still has checksum verification on: the README's instruction to turn it off
was not followed.
