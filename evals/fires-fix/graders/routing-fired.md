---
type: regex
target: trace
pattern: '"name":"Skill","input":\{[^}]*"skill":"(?:[\w-]+:)?fix"|"name":"Read","input":\{"file_path":"[^"]*/skills/fix/SKILL\.md"'
arm: with-only
---

Plugin-fired indicator: the fix skill loaded, through the Skill tool or a Read of its
SKILL.md, plugin-namespaced or not. Only the with-plugin arm can pass it, so a two-arm run
reports it without scoring it. scripts/eval-compare.sh reads it by this file name.
