---
type: regex
target: trace
pattern: '(?:"name":"(?:Edit|Write|MultiEdit|NotebookEdit)","input":\{"(?:file_path|notebook_path)":"(?!(?:[^"]*/)?tests/)|"name":"Bash","input":(?=\{(?:[^{}"]|"(?:[^"\\]|\\.)*")*?"command":"(?:[^"\\]|\\.)*?(?:\b(?:git\s+(?:bisect\s+reset|checkout\s+(?:-f\s+)?(?:main|master|-)(?![\w./-])|checkout\s+(?:\S+\s+)?--\s|switch\s+(?:main|master|-)(?![\w./-])|stash\s+(?:pop|apply)|revert|restore|apply|cherry-pick|am|merge|rebase|pull|reset)\b|sed\s+-i|perl\s+-\w*i|patch\b|python3?\b(?!\s+-m\s+(?:ledger|unittest|pytest)\b)|(?:node|ruby|tee|cp|mv)\b)|>(?!&|\s*/dev/null|>?\s*&))))(?![\s\S]*(?:"name":"(?:Edit|Write|MultiEdit|NotebookEdit)","input":\{"(?:file_path|notebook_path)":"(?!(?:[^"]*/)?tests/)|"name":"Bash","input":(?=\{(?:[^{}"]|"(?:[^"\\]|\\.)*")*?"command":"(?:[^"\\]|\\.)*?(?:\b(?:git\s+(?:checkout|switch|bisect|stash|revert|restore|apply|cherry-pick|am|merge|rebase|pull|reset)\b|sed\s+-i|perl\s+-\w*i|patch\b|python3?\b(?!\s+-m\s+(?:ledger|unittest|pytest)\b)|(?:node|ruby|tee|cp|mv)\b)|>(?!&|\s*/dev/null|>?\s*&)))))[\s\S]*Closing balance: 1,?033\.18\b'
---

The statement for the sample export prints "Closing balance: 1,033.18" after the last call
that changed the code, and that last change left HEAD on main: an Edit or Write outside
tests/, or a Bash command that writes files (sed -i, perl -i, patch, python other than
`python -m ledger`, `-m unittest` or `-m pytest`, node, ruby, tee, cp, mv, a redirect to a
file), restores them, or returns from a bisect or an old checkout. A 1,033.18 printed at
v1.4.0 or during a bisect step does not count, and neither does a run that changed nothing.
Adding a test after the check does not undo it, because edits under tests/ are not counted
as changes to the code.
