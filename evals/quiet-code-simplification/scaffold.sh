#!/usr/bin/env bash
# Seeds a git repo with a short, clean summary function that uses a vaguely named local.
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
def summarize_orders(orders):
    tmp = {"paid": 0, "refunded": 0, "other": 0}
    for order in orders:
        status = order.get("status")
        key = status if status in ("paid", "refunded") else "other"
        tmp[key] += order.get("amount", 0)
    return tmp
SRC
git add -A
git commit -q -m "Add summarize_orders"
