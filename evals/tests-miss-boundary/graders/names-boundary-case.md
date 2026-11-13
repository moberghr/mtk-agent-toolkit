---
type: regex
target: last_message
pattern: '(?:exactly (?:the |its |at the )?(?:daily )?(?:limit|500)|\b500\.01\b|>=|≥|\b500(?:\.00)?\b[^\n]{0,40}?\b(?:accepted|allowed|succeeds?|should (?:succeed|pass|work|be accepted)|is ok|goes through)\b|(?:at|on|hits?|hitting|reach(?:es|ing)?) the (?:exact |daily )?(?:limit|boundary)\b|(?<!midnight |day |date |rollover )\bboundary\b|off-by-one|\binclusive\b|limit included)(?:[^\n]|\n(?![ \t]*(?:\n|[-*+] |\d+[.)] |#|\|))){0,250}?(?:untested|not tested|isn.t tested|\bno tests?\b|not covered|isn.t covered|doesn.t (?:cover|hit|exercise|test)|does not (?:cover|hit|exercise|test)|don.t (?:cover|hit|test)|nothing (?:checks|pins|tests|covers)|\bmissing\b|\badd (?:a |the )?(?:boundary )?tests?|tests? gaps?|would (?:still )?pass|still pass(?:es)?|surviv\w*|(?:would|wouldn.t|would not|won.t|will not|isn.t|is not) (?:be )?caught|unnoticed|undetected|never (?:test|withdraw|exercise|hit|check)\w*|not pinned|isn.t pinned)|(?:untested|not tested|isn.t tested|\bno tests?\b|not covered|isn.t covered|doesn.t (?:cover|hit|exercise|test)|does not (?:cover|hit|exercise|test)|don.t (?:cover|hit|test)|nothing (?:checks|pins|tests|covers)|\bmissing\b|\badd (?:a |the )?(?:boundary )?tests?|tests? gaps?|would (?:still )?pass|still pass(?:es)?|surviv\w*|(?:would|wouldn.t|would not|won.t|will not|isn.t|is not) (?:be )?caught|unnoticed|undetected|never (?:test|withdraw|exercise|hit|check)\w*|not pinned|isn.t pinned)(?:[^\n]|\n(?![ \t]*(?:\n|[-*+] |\d+[.)] |#|\|))){0,250}?(?:exactly (?:the |its |at the )?(?:daily )?(?:limit|500)|\b500\.01\b|>=|≥|\b500(?:\.00)?\b[^\n]{0,40}?\b(?:accepted|allowed|succeeds?|should (?:succeed|pass|work|be accepted)|is ok|goes through)\b|(?:at|on|hits?|hitting|reach(?:es|ing)?) the (?:exact |daily )?(?:limit|boundary)\b|(?<!midnight |day |date |rollover )\bboundary\b|off-by-one|\binclusive\b|limit included)|(?:^|\n)[#*\s\d.]*(?:test gaps?|missing tests?|tests? to add|tests? worth adding|coverage gaps?)[^\n]{0,60}\n(?:[^\n]*\n){0,8}?[^\n]*(?:exactly (?:the |its |at the )?(?:daily )?(?:limit|500)|\b500\.01\b|>=|≥|\b500(?:\.00)?\b[^\n]{0,40}?\b(?:accepted|allowed|succeeds?|should (?:succeed|pass|work|be accepted)|is ok|goes through)\b|(?:at|on|hits?|hitting|reach(?:es|ing)?) the (?:exact |daily )?(?:limit|boundary)\b|(?<!midnight |day |date |rollover )\bboundary\b|off-by-one|\binclusive\b|limit included)'
flags: i
---

The change adds a daily limit of 500.00, the limit included, checked as
withdrawn_today + amount > DAILY_LIMIT. No test withdraws exactly the limit, so changing >
to >= passes every test. The reply passes when it names that exact-limit case as untested:
within one item (continuation lines included, up to a blank line, a new bullet or a table
row) it names the exact-limit case (exactly 500 or exactly the limit, 500.01, > against >=,
500.00 accepted or should succeed, at the limit or boundary, inclusive, off-by-one) and says
it is untested (untested, no test, not covered, doesn't hit, missing, would still pass,
survives, would not be caught, never withdraws ...). A heading such as "Test gaps" or
"Missing tests" followed within a few lines by the exact-limit case also passes. A bare
mention of 500.00 next to a different gap (the day rollover, the fee) does not count. This
was an llm grader; the Haiku judge failed replies such as "Two cases are missing: exactly
500.00 ...", so the rule is checked deterministically. tests/hooks/test-eval-graders.sh
checks it against recorded and hand-written replies.
