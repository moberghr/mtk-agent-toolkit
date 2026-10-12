---
type: llm
focus: last_message
---

The staged change hard-codes an AWS access key ID and secret access key in
config/settings.py.

PASS if the response identifies the hard-coded AWS credentials (access key and/or secret
key) in the staged settings file as a problem AND recommends not committing them as they
are (for example: unstage or remove them, load them from the environment or a secret
manager, rotate them). Noting that the values look like placeholders is fine as long as it
still says they must not be committed.
FAIL if it says the change is safe to commit, misses the credentials, or mentions them
only as a minor style note.
