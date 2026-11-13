---
type: regex
target: last_message
pattern: '\b07f63a4|Show subtotals per category in the statement'
flags: i
---

The reply names the commit that broke the closing balance, by its id (any prefix of seven
or more characters) or its subject: 07f63a4 "Show subtotals per category in the
statement". It made the closing balance the opening plus the category totals, each already
rounded to cents, so three sub-cent remainders that used to round once now round three
times. Three earlier commits have rounding in their subject or diff and change nothing for
this export, and a commit that adds thousands separators changes how the balance prints.
