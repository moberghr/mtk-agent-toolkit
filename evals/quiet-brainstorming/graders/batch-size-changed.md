---
type: regex
target: { source: file, path: import_job.py }
pattern: '^BATCH_SIZE\s*=\s*1000\s*$'
flags: m
---

import_job.py sets BATCH_SIZE to 1000.
