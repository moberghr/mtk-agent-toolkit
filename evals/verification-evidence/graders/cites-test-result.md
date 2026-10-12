---
type: regex
target: last_message
pattern: '(\b3/3\b|\bpass(es|ed|ing)?\b|exit (code|status)\W{0,3}0|\ball (three |3 )?(checks|tests|cases)\b|\bok\b)'
flags: i
---

The final message cites the test outcome (a pass count, a pass verdict or exit 0) rather than a bare "done".
