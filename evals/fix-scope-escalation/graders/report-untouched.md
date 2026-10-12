---
type: regex
target: { source: file, path: billing/report.py }
pattern: 'float\('
---

End-state check, independent of which tool made changes: billing/report.py still has its
original float arithmetic, i.e. the agent did not convert every module before stopping to
plan or ask.
