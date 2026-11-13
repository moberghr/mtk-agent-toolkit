#!/usr/bin/env bash
# Seeds a git repo holding the pre-patch version of pricing.py; the patch itself is only in the prompt.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

mkdir -p .claude
printf 'python\n' > .claude/tech-stack
cat > AGENTS.md <<'DOC'
# checkout

Python 3.12 checkout library used by the web shop.

## Build & Test

    python -m pytest -q
DOC
printf '@AGENTS.md\n' > CLAUDE.md

cat > pricing.py <<'SRC'
def apply_coupon(total, coupon, coupons):
    """Return the total after applying the coupon, if it is known."""
    if coupon not in coupons:
        return total
    pct = coupons[coupon]
    return round(total * (100 - pct) / 100, 2)
SRC
git add -A
git commit -q -m "Add coupon pricing"
