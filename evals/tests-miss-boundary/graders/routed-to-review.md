---
type: regex
target: trace
pattern: '"name":"Skill","input":\{"skill":"(?:[\w-]+:)?code-review-and-quality"|"name":"Read","input":\{"file_path":"[^"]*/skills/code-review-and-quality/SKILL\.md"'
arm: with-only
---

Indicator only: the /mtk router dispatched the code-review-and-quality workflow. The router
loads a workflow either through the Skill tool or by reading its SKILL.md, so both count.
