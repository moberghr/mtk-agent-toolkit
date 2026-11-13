---
type: regex
target: last_message
pattern: 'KeyError|(?:unknown|missing|invalid|unrecogni[sz]ed|non-?existent|absent|no)\s+coupon|not in (?:the )?coupons'
flags: i
---

The reply names the defect the patch introduces: with the `coupon not in coupons` guard
gone, an unknown coupon, or an order with no coupon, raises KeyError instead of returning
the total unchanged. Both arms can find it from the pasted patch, and a run that did
nothing has no reply to match.
