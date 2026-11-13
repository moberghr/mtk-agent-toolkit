---
type: llm
focus: last_message
---

The safe way to make this change is additive first: add FirstName and LastName (and backfill
them, or write both shapes) while FullName stays, move the code to read the new columns, and
drop FullName only in a later, separate release once no running code reads it.

PASS if the review recommends splitting the change so that FullName is removed later than
the release that adds the new columns and switches the code over (expand then contract,
a two-phase or multi-step migration, keeping the old column until every instance runs the
new code, or equivalent wording). A recommendation made conditional on the deployment
("if you run several instances or a rolling deploy, ...") still counts, and the other
findings in the review do not affect this verdict.
FAIL if it recommends nothing of the kind: for example it only suggests a better Down
method, testing the migration, a maintenance window, or making the data split more robust,
while leaving the drop in the same release.
