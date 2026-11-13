---
type: regex
target: trace
pattern: '"name":"Skill","input":\{"skill":"(?:[\w-]+:)?implement"|"name":"Read","input":\{"file_path":"[^"]*/skills/implement/SKILL\.md"'
arm: with-only
---

Indicator only: the /mtk router dispatched the implement workflow, through the Skill tool or a
Read of its SKILL.md. A run where it did not load is visible here.
