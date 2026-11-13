---
type: regex
target: trace
pattern: '"name":"Skill","input":\{[^}]*"skill":"(?:[\w-]+:)?research-context"|"name":"Read","input":\{"file_path":"[^"]*/skills/research-context/SKILL\.md"'
arm: with-only
---

Plugin-fired indicator: the research-context skill loaded, through the Skill tool or a Read of its
SKILL.md, plugin-namespaced or not. Only the with-plugin arm can pass it, so a two-arm run
reports it without scoring it. scripts/eval-compare.sh reads it by this file name.
