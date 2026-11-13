---
type: regex
target: trace
pattern: '"name":"Skill","input":\{[^}]*"skill":"(?:[\w-]+:)?code-review-and-quality"|"name":"Read","input":\{"file_path":"[^"]*/skills/code-review-and-quality/SKILL\.md"'
match: not_contains
arm: both
---

The code-review-and-quality skill did not load: no Skill call for it and no Read of its SKILL.md. Scored in
both arms. The without-plugin arm passes it by construction, so a with-plugin miss shows as
a lower score and a negative delta. scripts/eval-compare.sh reads it by this file name.
