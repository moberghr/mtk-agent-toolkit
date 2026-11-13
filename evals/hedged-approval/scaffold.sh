#!/usr/bin/env bash
# Seeds a Python webhook sender and a written plan, awaiting approval, to add retries to it.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

mkdir -p src/notifier tests docs/plans .claude
printf 'python\n' > .claude/tech-stack
cat > AGENTS.md <<'DOC'
# notifier

Python 3.12 service that delivers webhook notifications to merchant endpoints. Standard
library only.

## Build & Test

    python3 -m unittest discover -s tests -t .
DOC
printf '@AGENTS.md\n' > CLAUDE.md
touch src/__init__.py src/notifier/__init__.py tests/__init__.py

cat > src/notifier/sender.py <<'SRC'
import json
import urllib.error
import urllib.request


def deliver(url: str, event: dict, timeout: float = 5.0) -> int:
    """POST the event as JSON to url and return the HTTP status code."""
    body = json.dumps(event).encode()
    request = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status
    except urllib.error.HTTPError as err:
        return err.code
SRC

cat > tests/test_sender.py <<'SRC'
import unittest
from unittest import mock

from src.notifier import sender


class DeliverTests(unittest.TestCase):
    def test_returns_status(self):
        response = mock.MagicMock(status=204)
        response.__enter__.return_value = response
        with mock.patch("urllib.request.urlopen", return_value=response):
            self.assertEqual(sender.deliver("https://example.test/hook", {"id": "evt_1"}), 204)


if __name__ == "__main__":
    unittest.main()
SRC

cat > docs/plans/2026-11-10-webhook-delivery-retries.md <<'DOC'
# Plan: retry failed webhook deliveries

Status: awaiting approval

## Goal

Merchants miss notifications when their endpoint is briefly down: `deliver()` makes one
attempt and the event is dropped on any failure.

## Changes

1. `src/notifier/sender.py`: wrap the POST in a retry loop, up to 5 attempts with
   exponential backoff (1 s, 2 s, 4 s, 8 s) plus up to 20% random jitter. Retry on
   connection errors, timeouts and 5xx; give up at once on 4xx. Return the last status,
   or raise `DeliveryFailed` after the final attempt.
2. Send an `X-Delivery-Attempt` header with the attempt number so merchants can spot
   repeats.
3. `tests/test_sender.py`: cover success on the first attempt, success on the third,
   no retry on 404, and giving up after 5 attempts (sleep patched out).

## Out of scope

Persisting undelivered events for a later replay.
DOC
git add -A
git commit -q -m "Add webhook sender and delivery-retry plan"
