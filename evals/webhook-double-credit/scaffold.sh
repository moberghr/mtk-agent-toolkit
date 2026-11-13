#!/usr/bin/env bash
# Seeds a Python wallet service with a payment-provider webhook endpoint and the provider's
# delivery notes, commits it, then commits a change on a feature branch: event parsing, a
# transfer.settled handler that credits the merchant wallet and writes a ledger entry, a
# merchant.updated handler, a monthly statement endpoint with its index, and tests.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

mkdir -p app docs migrations tests .claude
printf 'python\n' > .claude/tech-stack
cat > AGENTS.md <<'DOC'
# wallet

Python 3.12 merchant wallet service: FastAPI, psycopg 3, PostgreSQL.

## Build & Test

    python -m pytest
DOC
printf '@AGENTS.md\n' > CLAUDE.md

cat > migrations/001_init.sql <<'SQL'
CREATE TABLE wallets (
    merchant_id   TEXT PRIMARY KEY,
    display_name  TEXT NOT NULL DEFAULT '',
    balance_cents BIGINT NOT NULL DEFAULT 0
);

CREATE TABLE ledger_entries (
    id           BIGSERIAL PRIMARY KEY,
    merchant_id  TEXT NOT NULL REFERENCES wallets (merchant_id),
    amount_cents BIGINT NOT NULL,
    kind         TEXT NOT NULL,
    reference    TEXT NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
SQL

cat > app/db.py <<'SRC'
from contextlib import contextmanager
import os

import psycopg

_DSN = os.environ.get("WALLET_DATABASE_URL", "postgresql://localhost/wallet")


@contextmanager
def transaction():
    """Yield a cursor inside one transaction; commit on success, roll back on error."""
    with psycopg.connect(_DSN) as conn:
        with conn.transaction():
            with conn.cursor() as cur:
                yield cur
SRC

cat > app/webhooks.py <<'SRC'
import hashlib
import hmac
import json
import logging
import os

from fastapi import APIRouter, Request, Response

log = logging.getLogger(__name__)
router = APIRouter()

_SECRET = os.environ.get("PROVIDER_WEBHOOK_SECRET", "").encode()


def verify_signature(payload: bytes, signature: str) -> bool:
    expected = hmac.new(_SECRET, payload, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature)


@router.post("/webhooks/payments")
async def payment_webhook(request: Request) -> Response:
    payload = await request.body()
    if not verify_signature(payload, request.headers.get("X-Signature", "")):
        return Response(status_code=401)

    event = json.loads(payload)
    log.info("webhook %s received: %s", event["id"], event["type"])
    return Response(status_code=200)
SRC
cat > docs/provider-webhooks.md <<'DOC'
# Payment provider webhooks

The provider posts events to `/webhooks/payments` as JSON:

    {"id": "evt_...", "type": "transfer.settled", "created": 1762940000, "data": {...}}

- Requests are signed: `X-Signature` is the hex HMAC-SHA256 of the body with our webhook
  secret.
- Delivery is retried with backoff for up to three days until we answer with a 2xx status.
  A delivery that times out after 10 seconds counts as failed.
- Event types we subscribe to: `transfer.settled`, `merchant.updated`.

### transfer.settled

`data`: `transfer_id`, `merchant_id`, `amount_cents` (positive integer), `currency`.

### merchant.updated

`data`: `merchant_id`, `display_name`.
DOC
touch app/__init__.py tests/__init__.py
git add -A
git commit -q -m "Add payment provider webhook endpoint"

# The change under review, committed on a feature branch.
git checkout -q -b settlement-webhooks

cat > app/events.py <<'SRC'
from dataclasses import dataclass
from datetime import datetime, timezone


class InvalidEvent(ValueError):
    pass


@dataclass(frozen=True)
class Event:
    id: str
    type: str
    created: datetime
    data: dict


def parse_event(body: dict) -> Event:
    try:
        event_id = body["id"]
        event_type = body["type"]
        created = datetime.fromtimestamp(int(body["created"]), tz=timezone.utc)
        data = body["data"]
    except (KeyError, TypeError, ValueError) as exc:
        raise InvalidEvent(f"malformed event: {exc}") from exc
    if not isinstance(data, dict):
        raise InvalidEvent("event data must be an object")
    return Event(event_id, event_type, created, data)
SRC

cat > app/webhooks.py <<'SRC'
import hashlib
import hmac
import json
import logging
import os

from fastapi import APIRouter, Request, Response

from app.db import transaction
from app.events import Event, InvalidEvent, parse_event

log = logging.getLogger(__name__)
router = APIRouter()

_SECRET = os.environ.get("PROVIDER_WEBHOOK_SECRET", "").encode()


def verify_signature(payload: bytes, signature: str) -> bool:
    expected = hmac.new(_SECRET, payload, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature)


@router.post("/webhooks/payments")
async def payment_webhook(request: Request) -> Response:
    payload = await request.body()
    if not verify_signature(payload, request.headers.get("X-Signature", "")):
        return Response(status_code=401)

    try:
        event = parse_event(json.loads(payload))
    except (json.JSONDecodeError, InvalidEvent):
        log.warning("rejected malformed webhook body")
        return Response(status_code=400)

    log.info("webhook %s received: %s", event.id, event.type)
    handler = HANDLERS.get(event.type)
    if handler is None:
        return Response(status_code=200)
    try:
        handler(event)
    except Exception:
        log.exception("webhook %s failed", event.id)
        return Response(status_code=500)
    return Response(status_code=200)


def settle_transfer(event: Event) -> None:
    """Credit the merchant's wallet with a settled transfer and record it in the ledger."""
    data = event.data
    with transaction() as cur:
        cur.execute(
            "UPDATE wallets SET balance_cents = balance_cents + %s WHERE merchant_id = %s",
            (data["amount_cents"], data["merchant_id"]),
        )
        cur.execute(
            "INSERT INTO ledger_entries (merchant_id, amount_cents, kind, reference) "
            "VALUES (%s, %s, 'transfer_settled', %s)",
            (data["merchant_id"], data["amount_cents"], data["transfer_id"]),
        )


def update_merchant(event: Event) -> None:
    with transaction() as cur:
        cur.execute(
            "UPDATE wallets SET display_name = %s WHERE merchant_id = %s",
            (event.data["display_name"], event.data["merchant_id"]),
        )


HANDLERS = {
    "transfer.settled": settle_transfer,
    "merchant.updated": update_merchant,
}
SRC

cat > app/statements.py <<'SRC'
from datetime import date, datetime, timezone

from fastapi import APIRouter, HTTPException

from app.db import transaction

router = APIRouter()


def _month_bounds(year: int, month: int) -> tuple[datetime, datetime]:
    if not 1 <= month <= 12:
        raise HTTPException(status_code=400, detail="month must be 1-12")
    start = datetime(year, month, 1, tzinfo=timezone.utc)
    end = datetime(year + month // 12, month % 12 + 1, 1, tzinfo=timezone.utc)
    return start, end


@router.get("/merchants/{merchant_id}/statements/{year}/{month}")
def monthly_statement(merchant_id: str, year: int, month: int) -> dict:
    start, end = _month_bounds(year, month)
    with transaction() as cur:
        cur.execute(
            "SELECT amount_cents, kind, reference, created_at FROM ledger_entries "
            "WHERE merchant_id = %s AND created_at >= %s AND created_at < %s "
            "ORDER BY created_at, id",
            (merchant_id, start, end),
        )
        rows = cur.fetchall()
    return {
        "merchant_id": merchant_id,
        "period": date(year, month, 1).strftime("%Y-%m"),
        "entries": [
            {"amount_cents": a, "kind": k, "reference": r, "created_at": c.isoformat()}
            for a, k, r, c in rows
        ],
        "total_cents": sum(a for a, _, _, _ in rows),
    }
SRC

cat > migrations/002_ledger_statement_index.sql <<'SQL'
CREATE INDEX ledger_entries_merchant_created
    ON ledger_entries (merchant_id, created_at);
SQL

cat > tests/test_events.py <<'SRC'
import pytest

from app.events import InvalidEvent, parse_event


def test_parses_a_settled_transfer():
    event = parse_event({
        "id": "evt_1",
        "type": "transfer.settled",
        "created": 1762940000,
        "data": {"transfer_id": "tr_1", "merchant_id": "m_1", "amount_cents": 1250, "currency": "EUR"},
    })
    assert event.id == "evt_1"
    assert event.data["amount_cents"] == 1250
    assert event.created.year == 2025


def test_missing_field_is_rejected():
    with pytest.raises(InvalidEvent):
        parse_event({"id": "evt_1", "type": "transfer.settled", "data": {}})


def test_data_must_be_an_object():
    with pytest.raises(InvalidEvent):
        parse_event({"id": "evt_1", "type": "x", "created": 1, "data": []})
SRC

cat > tests/test_statements.py <<'SRC'
from datetime import datetime, timezone

import pytest
from fastapi import HTTPException

from app.statements import _month_bounds


def test_month_bounds():
    assert _month_bounds(2026, 11) == (
        datetime(2026, 11, 1, tzinfo=timezone.utc),
        datetime(2026, 12, 1, tzinfo=timezone.utc),
    )


def test_december_rolls_into_next_year():
    assert _month_bounds(2026, 12)[1] == datetime(2027, 1, 1, tzinfo=timezone.utc)


def test_month_out_of_range():
    with pytest.raises(HTTPException):
        _month_bounds(2026, 13)
SRC
git add -A
git commit -q -m "Settle transfers into merchant wallets, merchant updates, monthly statements"
