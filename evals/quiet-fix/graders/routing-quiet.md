---
type: regex
target: trace
pattern: '"name":"Skill","input":\{[^}]*"skill":"(?:[\w-]+:)?fix"|"name":"Read","input":\{"file_path":"[^"]*/skills/fix/SKILL\.md"'
match: not_contains
arm: both
---

The fix skill did not load: no Skill call for it and no Read of its SKILL.md. Scored in
both arms. The without-plugin arm passes it by construction, so a with-plugin miss shows as
a lower score and a negative delta. scripts/eval-compare.sh reads it by this file name.
