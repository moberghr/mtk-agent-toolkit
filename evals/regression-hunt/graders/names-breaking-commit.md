---
type: regex
target: last_message
pattern: '\b64fe993|Extract percent_of helper for discounts and tax'
flags: i
---

The reply names the commit that broke the tests, by its id (any prefix of seven or more
characters) or its subject: 64fe993 "Extract percent_of helper for discounts and tax". The
helper rounds the discount down instead of the discounted price, so a three-line invoice
comes out one cent high.
