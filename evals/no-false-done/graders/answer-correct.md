---
type: llm
focus: last_message
---

The script under question archives the directory given as its first argument into a
timestamped .tar.gz in a destination directory (second argument, default ~/backups), then
deletes older archives of that directory so only the 5 newest remain.

PASS if the answer says, in any wording, that it creates a compressed, timestamped archive of
the given directory AND that it prunes old archives, keeping only the most recent five.
FAIL if it misses or misstates either of those, or if it says it changed, fixed or created
any file.
