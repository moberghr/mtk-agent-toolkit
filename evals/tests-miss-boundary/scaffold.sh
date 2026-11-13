#!/usr/bin/env bash
# Seeds a Python withdrawal service with unittest tests, commits it, then commits a
# change on a feature branch across several files: a daily withdrawal limit, a fee for foreign
# cards, an audit record per withdrawal, a day rollover, and tests for each.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

mkdir -p src tests docs .claude
printf 'python\n' > .claude/tech-stack
cat > AGENTS.md <<'DOC'
# cash-withdrawals

Python 3.12 cash withdrawal rules for the branch ATM network. Standard library only;
amounts are Decimal.

## Build & Test

    python3 -m unittest discover -s tests -t .
DOC
printf '@AGENTS.md\n' > CLAUDE.md
touch src/__init__.py tests/__init__.py

cat > src/withdrawals.py <<'SRC'
from dataclasses import dataclass
from decimal import Decimal


@dataclass
class Account:
    id: str
    balance: Decimal
    withdrawn_today: Decimal = Decimal("0")


class InsufficientFunds(Exception):
    pass


def withdraw(account: Account, amount: Decimal) -> Decimal:
    """Take amount out of the account and return the new balance."""
    if amount <= 0:
        raise ValueError("amount must be positive")
    if amount > account.balance:
        raise InsufficientFunds(account.id)
    account.balance -= amount
    account.withdrawn_today += amount
    return account.balance
SRC

cat > docs/rules.md <<'DOC'
# Withdrawal rules

- A withdrawal must be a positive amount and cannot overdraw the account.
DOC

cat > tests/test_withdrawals.py <<'SRC'
import unittest
from decimal import Decimal

from src.withdrawals import Account, InsufficientFunds, withdraw


class WithdrawTests(unittest.TestCase):
    def test_withdrawal_reduces_balance(self):
        acct = Account("a1", Decimal("300.00"))
        self.assertEqual(withdraw(acct, Decimal("120.00")), Decimal("180.00"))

    def test_amount_must_be_positive(self):
        with self.assertRaises(ValueError):
            withdraw(Account("a1", Decimal("300.00")), Decimal("0"))

    def test_cannot_overdraw(self):
        with self.assertRaises(InsufficientFunds):
            withdraw(Account("a1", Decimal("50.00")), Decimal("50.01"))


if __name__ == "__main__":
    unittest.main()
SRC
git add -A
git commit -q -m "Add withdrawal rules"

# The change under review, committed on a feature branch.
git checkout -q -b daily-limit
cat > docs/rules.md <<'DOC'
# Withdrawal rules

- A withdrawal must be a positive amount and cannot overdraw the account.
- Daily cash limit: a customer can take out 500.00 per calendar day, the limit included.
  The day rolls over at midnight in the branch's time zone.
- Cards issued abroad pay a fee of 1.5% of the amount, at least 2.00, rounded half-up to
  the cent. The fee is taken from the balance but does not count towards the daily limit.
- Every accepted withdrawal writes an audit record.
DOC

cat > src/fees.py <<'SRC'
from decimal import ROUND_HALF_UP, Decimal

FOREIGN_FEE_RATE = Decimal("0.015")
FOREIGN_FEE_MIN = Decimal("2.00")


def withdrawal_fee(amount: Decimal, foreign_card: bool) -> Decimal:
    if not foreign_card:
        return Decimal("0.00")
    fee = (amount * FOREIGN_FEE_RATE).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    return max(fee, FOREIGN_FEE_MIN)
SRC

cat > src/audit.py <<'SRC'
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal


@dataclass(frozen=True)
class AuditRecord:
    account_id: str
    amount: Decimal
    fee: Decimal
    at: datetime


class AuditLog:
    def __init__(self) -> None:
        self.records: list[AuditRecord] = []

    def record(self, account_id: str, amount: Decimal, fee: Decimal, at: datetime) -> None:
        self.records.append(AuditRecord(account_id, amount, fee, at))
SRC

cat > src/withdrawals.py <<'SRC'
from dataclasses import dataclass
from datetime import date, datetime
from decimal import Decimal
from typing import Optional

from src.audit import AuditLog
from src.fees import withdrawal_fee

DAILY_LIMIT = Decimal("500.00")


@dataclass
class Account:
    id: str
    balance: Decimal
    withdrawn_today: Decimal = Decimal("0")
    last_withdrawal_day: Optional[date] = None


class InsufficientFunds(Exception):
    pass


class DailyLimitExceeded(Exception):
    pass


def _roll_over(account: Account, today: date) -> None:
    if account.last_withdrawal_day != today:
        account.withdrawn_today = Decimal("0")
        account.last_withdrawal_day = today


def withdraw(
    account: Account,
    amount: Decimal,
    now: Optional[datetime] = None,
    foreign_card: bool = False,
    audit: Optional[AuditLog] = None,
) -> Decimal:
    """Take amount (plus any fee) out of the account and return the new balance."""
    now = now or datetime.now()
    if amount <= 0:
        raise ValueError("amount must be positive")
    _roll_over(account, now.date())
    if account.withdrawn_today + amount > DAILY_LIMIT:
        raise DailyLimitExceeded(account.id)
    fee = withdrawal_fee(amount, foreign_card)
    if amount + fee > account.balance:
        raise InsufficientFunds(account.id)
    account.balance -= amount + fee
    account.withdrawn_today += amount
    if audit is not None:
        audit.record(account.id, amount, fee, now)
    return account.balance
SRC

cat > tests/test_fees.py <<'SRC'
import unittest
from decimal import Decimal

from src.fees import withdrawal_fee


class FeeTests(unittest.TestCase):
    def test_domestic_card_pays_nothing(self):
        self.assertEqual(withdrawal_fee(Decimal("300.00"), foreign_card=False), Decimal("0.00"))

    def test_percentage_fee(self):
        self.assertEqual(withdrawal_fee(Decimal("300.00"), foreign_card=True), Decimal("4.50"))

    def test_minimum_fee(self):
        self.assertEqual(withdrawal_fee(Decimal("20.00"), foreign_card=True), Decimal("2.00"))

    def test_minimum_fee_threshold(self):
        # 1.5% of 133.33 is 1.99995, which rounds to 2.00: exactly the minimum.
        self.assertEqual(withdrawal_fee(Decimal("133.33"), foreign_card=True), Decimal("2.00"))
        self.assertEqual(withdrawal_fee(Decimal("133.67"), foreign_card=True), Decimal("2.01"))

    def test_rounds_half_up(self):
        # 1.5% of 233.00 is 3.495.
        self.assertEqual(withdrawal_fee(Decimal("233.00"), foreign_card=True), Decimal("3.50"))


if __name__ == "__main__":
    unittest.main()
SRC

cat > tests/test_withdrawals.py <<'SRC'
import unittest
from datetime import datetime
from decimal import Decimal

from src.audit import AuditLog
from src.withdrawals import Account, DailyLimitExceeded, InsufficientFunds, withdraw

NOON = datetime(2026, 11, 12, 12, 0)
NEXT_MORNING = datetime(2026, 11, 13, 8, 0)


class WithdrawTests(unittest.TestCase):
    def test_withdrawal_reduces_balance(self):
        acct = Account("a1", Decimal("300.00"))
        self.assertEqual(withdraw(acct, Decimal("120.00"), now=NOON), Decimal("180.00"))

    def test_amount_must_be_positive(self):
        with self.assertRaises(ValueError):
            withdraw(Account("a1", Decimal("300.00")), Decimal("0"), now=NOON)

    def test_cannot_overdraw(self):
        with self.assertRaises(InsufficientFunds):
            withdraw(Account("a1", Decimal("50.00")), Decimal("50.01"), now=NOON)

    def test_fee_counts_towards_the_balance_check(self):
        with self.assertRaises(InsufficientFunds):
            withdraw(Account("a1", Decimal("100.00")), Decimal("99.00"), now=NOON, foreign_card=True)

    def test_foreign_card_pays_the_fee(self):
        acct = Account("a1", Decimal("1000.00"))
        self.assertEqual(withdraw(acct, Decimal("300.00"), now=NOON, foreign_card=True), Decimal("695.50"))
        self.assertEqual(acct.withdrawn_today, Decimal("300.00"))

    def test_withdrawal_within_daily_limit(self):
        acct = Account("a1", Decimal("2000.00"))
        withdraw(acct, Decimal("100.00"), now=NOON)
        self.assertEqual(acct.withdrawn_today, Decimal("100.00"))

    def test_withdrawal_over_daily_limit_is_refused(self):
        acct = Account("a1", Decimal("2000.00"))
        withdraw(acct, Decimal("450.00"), now=NOON)
        with self.assertRaises(DailyLimitExceeded):
            withdraw(acct, Decimal("200.00"), now=NOON)

    def test_limit_resets_the_next_day(self):
        acct = Account("a1", Decimal("2000.00"))
        withdraw(acct, Decimal("450.00"), now=NOON)
        withdraw(acct, Decimal("450.00"), now=NEXT_MORNING)
        self.assertEqual(acct.withdrawn_today, Decimal("450.00"))

    def test_accepted_withdrawal_is_audited(self):
        log = AuditLog()
        withdraw(Account("a1", Decimal("300.00")), Decimal("40.00"), now=NOON, audit=log)
        self.assertEqual(len(log.records), 1)
        self.assertEqual(log.records[0].amount, Decimal("40.00"))

    def test_refused_withdrawal_is_not_audited(self):
        log = AuditLog()
        with self.assertRaises(InsufficientFunds):
            withdraw(Account("a1", Decimal("10.00")), Decimal("40.00"), now=NOON, audit=log)
        self.assertEqual(log.records, [])


if __name__ == "__main__":
    unittest.main()
SRC
git add -A
git commit -q -m "Daily withdrawal limit, foreign card fee, audit log"
