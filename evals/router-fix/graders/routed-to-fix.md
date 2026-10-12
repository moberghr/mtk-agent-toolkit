---
type: regex
target: trace
pattern: '"name":"Skill","input":\{"skill":"(?:[\w-]+:)?fix"|"name":"Read","input":\{"file_path":"[^"]*/skills/fix/SKILL\.md"'
arm: with-only
---

Indicator only: the /mtk router dispatched the fix workflow. The router loads a workflow
either through the Skill tool or by reading its SKILL.md, so both count.
