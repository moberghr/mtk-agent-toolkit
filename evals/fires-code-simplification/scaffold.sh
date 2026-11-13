#!/usr/bin/env bash
# Seeds a git repo whose latest commit adds a working but deeply nested summary function and its test.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

mkdir -p .claude
printf 'python\n' > .claude/tech-stack
cat > AGENTS.md <<'DOC'
# reports

Python 3.12 reporting helpers for the order dashboard.

## Build & Test

    python -m pytest -q
DOC
printf '@AGENTS.md\n' > CLAUDE.md

cat > report.py <<'SRC'
def order_count(orders):
    return len(orders)
SRC
git add -A
git commit -q -m "Add report helpers"

cat >> report.py <<'SRC'


def summarize_orders(orders):
    result = {"paid": 0, "refunded": 0, "other": 0}
    for order in orders:
        if order is not None:
            if "status" in order:
                if order["status"] == "paid":
                    if order.get("amount", 0) > 0:
                        result["paid"] = result["paid"] + order["amount"]
                    else:
                        result["other"] = result["other"] + 0
                else:
                    if order["status"] == "refunded":
                        result["refunded"] = result["refunded"] + order.get("amount", 0)
                    else:
                        result["other"] = result["other"] + order.get("amount", 0)
            else:
                result["other"] = result["other"] + order.get("amount", 0)
    return result
SRC
cat > test_report.py <<'SRC'
from report import summarize_orders


def test_summarize_orders():
    orders = [
        {"status": "paid", "amount": 100},
        {"status": "paid", "amount": 0},
        {"status": "refunded", "amount": 40},
        {"status": "pending", "amount": 7},
        {"amount": 3},
        None,
    ]
    assert summarize_orders(orders) == {"paid": 100, "refunded": 40, "other": 10}
SRC
git add -A
git commit -q -m "Add summarize_orders"
