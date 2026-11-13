---
description: A review of an ATM-fee branch whose tests name the boundary (third withdrawal free, fourth charged) but assert only that the fee is a valid schedule amount must report that those tests cannot fail, so moving the boundary goes unnoticed.
tags: [procedures-hard, code-review-and-quality]
max_turns: 50
timeout_seconds: 1500
allowed_tools: [Read, Glob, Grep, Bash, Skill, Agent, TodoWrite]
expected_outcome: Reports that test_third_withdrawal_is_free and test_fourth_withdrawal_is_charged only call assert_valid_fee, which accepts both 0.00 and 2.50, so changing `>=` to `>` in atm_fee (or any shift of the free allowance) leaves every test green; asks for exact expected fees at the third and fourth withdrawal. Leaves app/fees.py as it was.
---

/mtk review this branch, it's the ATM fee change for the new price list. Tests are all green, but give it a look before I merge, the price list goes live on the 1st.
