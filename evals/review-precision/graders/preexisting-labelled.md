---
type: regex
target: last_message
pattern: '^(?![\s\S]*(?:(?:remove_coupon|remov\w* (?:a |the )?coupon)[\s\S]{0,250}?(?:discount_cents|discount\w*[^.\n]{0,40}?(?:still|stays|remains|survives|persists|lingers|kept|left|not (?:reset|cleared|removed|undone))|(?:leav\w*|keep\w*|reset\w*|clear\w*|undo\w*|revert\w*|zero\w*)[^.\n]{0,30}?discount|(?:stale|old|previous|leftover) discount)|(?:discount_cents|discount\w*[^.\n]{0,40}?(?:still|stays|remains|survives|persists|lingers|kept|left|not (?:reset|cleared|removed|undone))|(?:leav\w*|keep\w*|reset\w*|clear\w*|undo\w*|revert\w*|zero\w*)[^.\n]{0,30}?discount|(?:stale|old|previous|leftover) discount)[\s\S]{0,250}?(?:remove_coupon|remov\w* (?:a |the )?coupon)))[\s\S]*$|(?:remove_coupon|remov\w* (?:a |the )?coupon)[\s\S]{0,600}?(?:pre-?existing|predat\w*|(?:exist\w*|is|was|already) (?:on|in) \W?main\b|(?:already|also|same|too)[^.\n|]{0,30}?(?:on|in) \W?main\b|\bmain\b\W?[^.\n|]{0,25}?\b(?:the same|as well|too|also)\b|existed before|before (?:this|the|your) (?:branch|change|pr)\b|not (?:introduced|caused) (?:by|in|here)|already (?:there|present|broken)\b|existing (?:bug|defect|issue|problem)|not a regression|(?:old|previous|prior|existing) behaviou?r|not part of (?:this|the|your) (?:change|diff|branch|pr)\b|unchanged (?:by|in) (?:this|the|your) (?:diff|change|branch|pr)\b|untouched by (?:this|the|your))|(?:pre-?existing|predat\w*|(?:exist\w*|is|was|already) (?:on|in) \W?main\b|(?:already|also|same|too)[^.\n|]{0,30}?(?:on|in) \W?main\b|\bmain\b\W?[^.\n|]{0,25}?\b(?:the same|as well|too|also)\b|existed before|before (?:this|the|your) (?:branch|change|pr)\b|not (?:introduced|caused) (?:by|in|here)|already (?:there|present|broken)\b|existing (?:bug|defect|issue|problem)|not a regression|(?:old|previous|prior|existing) behaviou?r|not part of (?:this|the|your) (?:change|diff|branch|pr)\b|unchanged (?:by|in) (?:this|the|your) (?:diff|change|branch|pr)\b|untouched by (?:this|the|your))[\s\S]{0,300}?(?:remove_coupon|remov\w* (?:a |the )?coupon)'
flags: i
---

remove_coupon sets order.coupon to None but leaves order.discount_cents, so the old discount
still applies after the coupon is removed. That defect is identical in the committed code;
the change edits remove_coupon only to record a history entry. The reply passes when it does
not report that defect, that is, when no mention of remove_coupon (or removing a coupon)
comes within a few sentences of the stale discount (discount_cents, a discount that still
applies, stays or is not reset or cleared, a stale or leftover discount). Naming
remove_coupon for another reason, such as a fix for coupon stacking, is not a report of the
defect. When the reply does report it, a mention of remove_coupon must have, within a few
sentences, wording that says the defect predates the change: pre-existing, predates, an
existing bug, exists or was already on main, already the case (or the same) on main, main
has the same bug, already there, existed before, before this branch or change, not
introduced by it, not a regression, old or previous behaviour, not part of this change,
unchanged by this diff. A severity, a row in a findings table or a recommendation to fix it
now do not matter. This was an llm grader; the Haiku judge failed replies that said "this
bug exists on main too", so the rule is checked deterministically.
tests/hooks/test-eval-graders.sh checks it against recorded and hand-written replies.
