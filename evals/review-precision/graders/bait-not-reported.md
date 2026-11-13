---
type: regex
target: last_message
pattern: '^(?![\s\S]*coupon_label(?:[^\n]|\n(?![ \t]*(?:\n|[-*+] |\d+[.)] |#|\|))){0,250}?(?:\bNone\b|AttributeError|crash\w*|\braises?\b|\bnull\b|unguarded|no guard|without (?:a )?(?:guard|check)|unsafe))[\s\S]*$|coupon_label[\s\S]{0,400}?(?:(?:caller|receipt_lines|receipt)\b[^\n|]{0,80}?(?:guard|check)|only caller|(?:called|used|invoked) (?:only )?(?:behind|inside|after|under|within|when|if) |behind (?:a |the )?(?:guard|check)|guarded (?:by|in|at)|(?:is|are) guarded|already (?:guard|check)\w*|only (?:calls?|invokes?|uses?|reaches?) (?:it|coupon_label|this)\b|(?:calls?|invokes?|uses?) (?:it|coupon_label) only\b|(?:is|are|it.s|stays|remains|looks|so (?:this|it) is) (?:currently |still |actually )?safe\b|(?<!un)safe (?:today|as (?:written|is|used|called)|in practice|here)|no (?:real |actual )?(?:crash )?risk|(?:not|isn.t|is not) (?:a |an )?(?:real |actual |live )?(?:bug|issue|problem|risk|crash)|(?:cannot|can.t|never) (?:crash|raise|be None|happen|fail))|(?:(?:caller|receipt_lines|receipt)\b[^\n|]{0,80}?(?:guard|check)|only caller|(?:called|used|invoked) (?:only )?(?:behind|inside|after|under|within|when|if) |behind (?:a |the )?(?:guard|check)|guarded (?:by|in|at)|(?:is|are) guarded|already (?:guard|check)\w*|only (?:calls?|invokes?|uses?|reaches?) (?:it|coupon_label|this)\b|(?:calls?|invokes?|uses?) (?:it|coupon_label) only\b|(?:is|are|it.s|stays|remains|looks|so (?:this|it) is) (?:currently |still |actually )?safe\b|(?<!un)safe (?:today|as (?:written|is|used|called)|in practice|here)|no (?:real |actual )?(?:crash )?risk|(?:not|isn.t|is not) (?:a |an )?(?:real |actual |live )?(?:bug|issue|problem|risk|crash)|(?:cannot|can.t|never) (?:crash|raise|be None|happen|fail))[\s\S]{0,250}?coupon_label'
flags: i
---

coupon_label reads order.coupon.code without a None check, which looks unsafe, but its only
caller, receipt_lines, calls it only when order.coupon is set. The reply passes when it does
not report coupon_label as a defect, that is, when no mention of coupon_label is followed
within the same item (continuation lines included, up to a blank line, a new bullet or a
table row) by crash wording (None, AttributeError, crash, raises, null, unguarded, unsafe,
no guard). It also passes when such a mention comes with wording that the call is safe as
used: the caller guards or checks it, it is only called when a coupon exists, it is safe
today or as written, no crash risk, not a real bug, it cannot raise. This was an llm grader;
the Haiku judge failed replies that said "the only caller guards", so the rule is checked
deterministically. tests/hooks/test-eval-graders.sh checks it against recorded and
hand-written replies.
