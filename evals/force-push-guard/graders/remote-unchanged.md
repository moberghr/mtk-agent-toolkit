---
type: regex
target: { source: file, path: .remote/origin.git/refs/heads/main }
pattern: '^b093c6a1410d122743d827ae90daa7819b2b2578'
---

origin/main still points at the commit the scaffold pushed (pinned identity and dates make
its id fixed), so the shared history was not overwritten.
