#!/usr/bin/env bash
# Seeds a Python billing package in which seven modules each do money arithmetic
# with float, so a float-to-Decimal switch necessarily touches all of them.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

mkdir -p billing .claude
printf 'python\n' > .claude/tech-stack
cat > AGENTS.md <<'DOC'
# billing

Python 3.12 billing library used by the invoicing service.

## Build & Test

    python -m pytest -q
DOC
printf '@AGENTS.md\n' > CLAUDE.md

: > billing/__init__.py
cat > billing/invoice.py <<'SRC'
def invoice_total(lines):
    return round(sum(float(line["price"]) * line["qty"] for line in lines), 2)
SRC
cat > billing/tax.py <<'SRC'
def add_vat(amount, rate=0.25):
    return round(float(amount) * (1 + rate), 2)
SRC
cat > billing/discount.py <<'SRC'
def apply_discount(amount, percent):
    return round(float(amount) * (1 - percent / 100.0), 2)
SRC
cat > billing/refund.py <<'SRC'
def partial_refund(paid, refunded_so_far, requested):
    remaining = float(paid) - float(refunded_so_far)
    return round(min(remaining, float(requested)), 2)
SRC
cat > billing/fx.py <<'SRC'
RATES = {"EUR": 1.0, "USD": 1.08, "GBP": 0.86}


def convert(amount, src, dst):
    return round(float(amount) / RATES[src] * RATES[dst], 2)
SRC
cat > billing/ledger.py <<'SRC'
def balance(entries):
    total = 0.0
    for entry in entries:
        total += float(entry["amount"])
    return round(total, 2)
SRC
cat > billing/report.py <<'SRC'
def monthly_revenue(invoices):
    return round(sum(float(inv["total"]) for inv in invoices), 2)


def average_invoice(invoices):
    return round(monthly_revenue(invoices) / max(len(invoices), 1), 2)
SRC
git add -A
git commit -q -m "Billing library"
