---
type: regex
target: last_message
pattern: '\b30\b[\s\S]{0,80}\b10\b|\b10\b[\s\S]{0,80}\b30\b'
---

The summary gives the default timeout before and after the change (30 to 10). The old value
30 is only in the committed version, so naming it takes reading the diff, not just the
current config_loader.py.
