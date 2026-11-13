---
description: A patch pasted into the prompt, not present in the repo, still loads the review skill.
tags: [routing, fires, code-review-and-quality]
max_turns: 8
timeout_seconds: 1200
allowed_tools: [Read, Glob, Grep, Skill, TodoWrite]
expected_outcome: Loads the review skill for the pasted patch and points out that an unknown or absent coupon now raises KeyError instead of returning the total, without editing anything.
---

A teammate sent me this patch for pricing.py. It is meant to cap coupons at 100%. Can you look it over before I apply it? Is anything wrong with it?

```diff
--- a/pricing.py
+++ b/pricing.py
@@ -1,6 +1,4 @@
 def apply_coupon(total, coupon, coupons):
     """Return the total after applying the coupon, if it is known."""
-    if coupon not in coupons:
-        return total
-    pct = coupons[coupon]
+    pct = min(coupons[coupon], 100)
     return round(total * (100 - pct) / 100, 2)
```
