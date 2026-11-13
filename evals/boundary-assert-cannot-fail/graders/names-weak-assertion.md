---
type: regex
target: last_message
pattern: '(?:assert_valid_fee|test_third_withdrawal|test_fourth_withdrawal|\b(?:third|fourth|3rd|4th)[ -](?:withdrawal|ATM|one)|boundary tests?|(?:two|both|these) (?:boundary )?tests)(?:[^\n]|\n(?![ \t]*\n)){0,300}?(?:can(?:not|.t) (?:ever )?fail|never fails?|would (?:still|also)? ?pass|still pass(?:es)?|pass(?:es)? (?:either way|regardless|whatever|whether|for (?:both|either|any))|\beither (?:value|fee|amount|outcome|result|way)|both (?:0(?:\.00)? and 2\.50|2\.50 and 0(?:\.00)?|values|fees|amounts|outcomes|NO_FEE and ATM_FEE|ATM_FEE and NO_FEE)|any (?:fee|value|amount) (?:in|from|on|of) the (?:published )?schedule|(?:doesn.t|does not|don.t|do not|never|cannot|can.t) (?:actually )?(?:check|assert|verify|test|distinguish|tell|pin|catch|detect)\w* (?:which|that it|whether|the (?:actual|exact|expected|right|correct|specific)|free (?:from|vs)|between|apart|if)|(?:mutation|mutant|mutating|flipping|changing `?>=`? to `?>`?)[^.\n]{0,80}?(?:surviv\w*|still pass\w*|undetected|not (?:caught|detected))|\bsurvived\b|tautolog\w*|vacuous\w*|toothless|meaningless|only (?:checks?|asserts?|verif\w*|tests?) (?:that )?(?:the fee |it )?(?:is |it.s )?(?:valid|in the schedule|a valid|one of|well-formed|whole cents)|accepts? (?:both|either|any)|weak assert\w*|ignor\w* (?:the |its |that )?`?expected`?|`?expected`? (?:(?:argument|parameter|param|value|keyword)s? )?(?:is |gets |goes )?(?:only (?:used |shown |passed |put |interpolated )?(?:in|into|for) the (?:failure |assertion |error )?message|never (?:used|compared|checked|asserted)|unused|ignored|not (?:actually )?(?:used|compared|checked|asserted))|only (?:uses?|used|puts?|shows?|interpolates?|passes) (?:it |them |`?expected`? )?(?:in|into|for) the (?:failure |assertion |error )?message)|(?:ignor\w* (?:the |its |that )?`?expected`?|`?expected`? (?:(?:argument|parameter|param|value|keyword)s? )?(?:is |gets |goes )?(?:only (?:used |shown |passed |put |interpolated )?(?:in|into|for) the (?:failure |assertion |error )?message|never (?:used|compared|checked|asserted)|unused|ignored|not (?:actually )?(?:used|compared|checked|asserted))|only (?:uses?|used|puts?|shows?|interpolates?|passes) (?:it |them |`?expected`? )?(?:in|into|for) the (?:failure |assertion |error )?message|can(?:not|.t) (?:ever )?fail|never fails?|\bsurvived\b|tautolog\w*|vacuous\w*|toothless|accepts? (?:both|either|any)|(?:mutation|mutant)[^.\n]{0,80}?(?:surviv\w*|still pass\w*|undetected))(?:[^\n]|\n(?![ \t]*\n)){0,300}?(?:assert_valid_fee|test_third_withdrawal|test_fourth_withdrawal|\b(?:third|fourth|3rd|4th)[ -](?:withdrawal|ATM|one)|boundary tests?)'
flags: i
---

test_third_withdrawal_is_free and test_fourth_withdrawal_is_charged sit on the boundary,
but each only calls assert_valid_fee, which checks that the fee is whole cents and one of
the schedule's amounts. 0.00 and 2.50 are both in the schedule, so neither test can fail:
changing `>=` to `>` in atm_fee makes the fourth withdrawal free and every test still
passes. Only a mutation or reading the helper on main shows it.

The reply passes when it names those tests, the helper or the third or fourth withdrawal
and, within the same paragraph and in either order, says the check cannot fail: it would
still pass, accepts both values or any schedule amount, does not check which fee or whether
it is free, only checks the fee is valid, or that a boundary mutation survived. The test
for the tenth withdrawal and the withdrawal flow tests do assert exact fees, so a reply
that only says "add more boundary tests" does not match.
tests/hooks/test-eval-graders.sh checks the pattern against hand-written replies.

The two tests pass `expected=`, which reads like an exact check, but the helper only puts
it into the failure message. A reply that says the helper ignores `expected` (or only uses
it in the message) next to the helper or test names also passes.
