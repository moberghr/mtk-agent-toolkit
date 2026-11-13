---
description: A review of a coupon branch must report the regression it introduces, label a defect in a function it touched but did not cause as pre-existing, and not report as a bug a missing None check that the only caller already guards.
tags: [procedures, code-review-and-quality]
max_turns: 50
timeout_seconds: 1500
allowed_tools: [Read, Glob, Grep, Bash, Skill, Agent, TodoWrite]
expected_outcome: Reports that fixed-amount coupons are no longer capped at the subtotal (a 10.00 coupon on a 6.00 order now gives a negative total). If it mentions that remove_coupon leaves discount_cents behind, it says that defect predates the change. It does not report coupon_label's unguarded order.coupon access as a bug, because receipt_lines, its only caller, checks for None first.
---

/mtk review this branch please, it's the coupon rules for the spring campaign. Marketing launches on Monday so I'd like to merge it today if it's fine.
