---
type: regex
target: trace
pattern: '(?:"name":"(?:Edit|Write|MultiEdit|NotebookEdit)"|"name":"Bash","input":(?=\{(?:[^{}"]|"(?:[^"\\]|\\.)*")*?"command":"(?:[^"\\]|\\.)*?(?:\b(?:git\s+(?:bisect\s+reset|checkout\s+(?:-f\s+)?(?:main|master|-)(?![\w./-])|checkout\s+(?:\S+\s+)?--\s|switch\s+(?:main|master|-)(?![\w./-])|stash\s+(?:pop|apply)|revert|restore|apply|cherry-pick|am|merge|rebase|pull|reset)\b|sed\s+-i|perl\s+-\w*i|patch\b|(?:python3?|node|ruby|tee|cp|mv)\b)|>(?!&|\s*/dev/null|>?\s*&))))(?![\s\S]*(?:"name":"(?:Edit|Write|MultiEdit|NotebookEdit)"|"name":"Bash","input":(?=\{(?:[^{}"]|"(?:[^"\\]|\\.)*")*?"command":"(?:[^"\\]|\\.)*?(?:\b(?:git\s+(?:checkout|switch|bisect|stash|revert|restore|apply|cherry-pick|am|merge|rebase|pull|reset)\b|sed\s+-i|perl\s+-\w*i|patch\b|(?:python3?|node|ruby|tee|cp|mv)\b)|>(?!&|\s*/dev/null|>?\s*&)))))[\s\S]*tests: \d+ passed, 0 failed'
---

The test suite's all-green summary ("tests: N passed, 0 failed", printed by the test script
however it is invoked) appears after the last call that changed the working tree, and that
last change left HEAD on the branch: an Edit or Write, or a Bash command that writes files
(sed -i, perl -i, patch, python, node, ruby, tee, cp, mv, a redirect to a file), restores them, or returns from a bisect or an old checkout (git bisect reset, git
checkout main). A pass printed while an older commit is checked out (a bisect step, a
checkout of another revision) does not count, and neither does a run that changed nothing.
