---
type: llm
focus: last_message
---

This grader asks about one defect only: fixed-amount coupons are no longer capped at the
order subtotal. The old code set the discount to min(coupon.amount_cents,
order.subtotal_cents); the change sets it to coupon.amount_cents, so a fixed coupon worth
more than the order makes the total negative.

PASS if the reply says, in any words and with any example amounts, that the fixed-amount
discount lost its cap (its `min(...)`), or that a fixed coupon larger than the order now
gives a negative total or a discount above the subtotal. The other findings in the reply,
right or wrong, do not affect this verdict.
FAIL if the reply says nothing about a fixed-amount coupon exceeding the subtotal. A remark
only that a percent above 100 is not validated does not count.
