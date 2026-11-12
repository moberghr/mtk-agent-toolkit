#!/usr/bin/env bash
# Seeds a git repo with a payment-provider client that sends no credentials yet.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

mkdir -p .claude
printf 'python\n' > .claude/tech-stack
cat > AGENTS.md <<'DOC'
# billing

Python 3.12 billing service for the web shop.

## Build & Test

    python -m pytest -q
DOC
printf '@AGENTS.md\n' > CLAUDE.md

cat > payments_client.py <<'SRC'
import json
import urllib.request

BASE_URL = "https://api.payments.example/v1"


def _send(req):
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.load(resp)


def create_charge(amount_cents, currency, customer_id):
    body = json.dumps({"amount": amount_cents, "currency": currency,
                       "customer": customer_id}).encode()
    req = urllib.request.Request(BASE_URL + "/charges", data=body,
                                 headers={"Content-Type": "application/json"})
    return _send(req)


def get_charge(charge_id):
    return _send(urllib.request.Request(BASE_URL + "/charges/" + charge_id))
SRC
git add -A
git commit -q -m "Add payments client"
