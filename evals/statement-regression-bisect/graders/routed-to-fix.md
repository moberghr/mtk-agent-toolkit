---
type: regex
target: trace
pattern: '"name":"Skill","input":\{"skill":"(?:[\w-]+:)?fix"|"name":"Read","input":\{"file_path":"[^"]*/skills/fix/SKILL\.md"'
arm: with-only
---

Indicator only: the /mtk router dispatched the fix workflow, through the Skill tool or a
Read of its SKILL.md. A run where it did not load is visible here.
