---
type: regex
target: trace
pattern: '"name":"Skill","input":\{[^}]*"skill":"(?:[\w-]+:)?security-and-hardening"|"name":"Read","input":\{"file_path":"[^"]*/skills/security-and-hardening/SKILL\.md"'
arm: with-only
---

Plugin-fired indicator: the security-and-hardening skill loaded, through the Skill tool or a Read of its
SKILL.md, plugin-namespaced or not. Only the with-plugin arm can pass it, so a two-arm run
reports it without scoring it. scripts/eval-compare.sh reads it by this file name.
