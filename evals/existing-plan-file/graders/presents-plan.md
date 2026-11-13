---
type: llm
focus: last_message
---

The user asked for a plan for CSV export of the monthly revenue report, without building
it.

PASS if the reply presents a plan for the CSV export (concrete steps or tasks, in the reply
or in a file it names), OR asks the user a question about the unfinished plan already in
tasks/todo.md (for example whether to replace, archive or keep it) before writing the new
one.
FAIL if the reply contains neither a plan for the CSV export nor such a question, for
example an error, an unrelated answer or an empty reply.
