---
type: llm
focus: last_message
---

The change drops the FullName column in the same release that stops the code reading it.
The pipeline migrates the database first and then replaces three instances one at a time,
so the instances still running the old code query a column that no longer exists. Rolling
the application back is unsafe too: the old code needs FullName, and the Down migration
re-creates it empty, so the names are lost.

PASS if the review identifies at least one of these as a problem: instances (or any code)
still running the previous version break once FullName is dropped, during the rollout or
deploy window; or the release cannot be rolled back safely (rollback breaks or loses the
names) AND it presents the problem as high severity, blocking, or something to fix before
merging (any equivalent wording).
FAIL if it does not raise the rollout or rollback problem, or mentions it only as a minor
note or an optional consideration, or treats the migration as safe.
