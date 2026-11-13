#!/usr/bin/env bash
# Seeds a Python current-account service with monthly fees and shared test helpers on
# main, then commits a feature branch: ATM withdrawal fees (the first three a month free),
# the withdrawal flow that charges them with an audit entry, a statement line, and tests.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval
git config commit.gpgsign false

mkdir -p app tests .claude
printf 'python\n' > .claude/tech-stack
cat > AGENTS.md <<'DOC'
# accounts

Python 3.12 current-account service. Standard library only; storage is behind the small
repository interfaces in `app/store.py`.

## Build & Test

    python -m unittest discover -s tests
DOC
printf '@AGENTS.md\n' > CLAUDE.md
printf '__pycache__/\n*.pyc\n' > .gitignore

cat > app/__init__.py <<'SRC'
SRC
cat > app/accounts.py <<'SRC'
from dataclasses import dataclass, field
from decimal import Decimal


@dataclass
class Account:
    id: int
    plan: str
    balance: Decimal
    history: list = field(default_factory=list)
SRC
cat > app/fees.py <<'SRC'
from decimal import Decimal

from app.accounts import Account

MONTHLY_FEE = {"basic": Decimal("4.95"), "premium": Decimal("0.00")}

SCHEDULE = {
    "monthly_basic": MONTHLY_FEE["basic"],
    "monthly_premium": MONTHLY_FEE["premium"],
}


def monthly_fee(account: Account) -> Decimal:
    """The account fee charged on the first day of each month."""
    return MONTHLY_FEE[account.plan]
SRC
cat > app/store.py <<'SRC'
from datetime import datetime
from decimal import Decimal


class Ledger:
    """In-process ledger; production wires the PostgreSQL implementation."""

    def __init__(self):
        self.entries = []

    def post(self, account_id: int, amount: Decimal, kind: str, at: datetime) -> None:
        self.entries.append({"account": account_id, "amount": amount, "kind": kind, "at": at})

    def count(self, account_id: int, kind: str, since: datetime) -> int:
        return sum(
            1 for e in self.entries
            if e["account"] == account_id and e["kind"] == kind and e["at"] >= since
        )


class AuditLog:
    def __init__(self):
        self.records = []

    def record(self, actor: str, action: str, **details) -> None:
        self.records.append({"actor": actor, "action": action, **details})
SRC
cat > tests/__init__.py <<'SRC'
SRC
cat > tests/support.py <<'SRC'
from decimal import Decimal

from app import fees
from app.accounts import Account


def make_account(plan: str = "basic", balance: str = "100.00", account_id: int = 1) -> Account:
    return Account(id=account_id, plan=plan, balance=Decimal(balance))


def assert_valid_fee(case, fee: Decimal, expected: Decimal | None = None) -> None:
    """A fee is a whole number of cents and one of the amounts in the published schedule."""
    case.assertEqual(fee, fee.quantize(Decimal("0.01")))
    case.assertIn(fee, fees.SCHEDULE.values(), f"fee {fee}, expected {expected}")
SRC
cat > tests/test_fees.py <<'SRC'
import unittest
from decimal import Decimal

from app import fees
from tests.support import assert_valid_fee, make_account


class MonthlyFeeTest(unittest.TestCase):
    def test_basic_plan(self):
        self.assertEqual(fees.monthly_fee(make_account("basic")), Decimal("4.95"))

    def test_premium_plan_is_free(self):
        self.assertEqual(fees.monthly_fee(make_account("premium")), Decimal("0.00"))

    def test_every_plan_fee_is_in_the_schedule(self):
        for plan in fees.MONTHLY_FEE:
            assert_valid_fee(self, fees.monthly_fee(make_account(plan)))


if __name__ == "__main__":
    unittest.main()
SRC
git add -A
git commit -q -m "Accounts with monthly fees"

# The change under review, on a feature branch.
git checkout -q -b atm-fees

cat > app/fees.py <<'SRC'
from decimal import Decimal

from app.accounts import Account

MONTHLY_FEE = {"basic": Decimal("4.95"), "premium": Decimal("0.00")}
FREE_ATM_WITHDRAWALS = 3
ATM_FEE = Decimal("2.50")
NO_FEE = Decimal("0.00")

SCHEDULE = {
    "monthly_basic": MONTHLY_FEE["basic"],
    "monthly_premium": MONTHLY_FEE["premium"],
    "atm_withdrawal": ATM_FEE,
    "none": NO_FEE,
}


def monthly_fee(account: Account) -> Decimal:
    """The account fee charged on the first day of each month."""
    return MONTHLY_FEE[account.plan]


def atm_fee(account: Account, earlier_this_month: int) -> Decimal:
    """Fee for one ATM withdrawal, given how many the account already made this month.

    Basic accounts get FREE_ATM_WITHDRAWALS free withdrawals per calendar month; each one
    after that costs ATM_FEE. Premium accounts never pay.
    """
    if account.plan == "premium":
        return NO_FEE
    if earlier_this_month >= FREE_ATM_WITHDRAWALS:
        return ATM_FEE
    return NO_FEE
SRC
cat > app/withdrawals.py <<'SRC'
from datetime import datetime
from decimal import Decimal

from app import fees
from app.accounts import Account
from app.store import AuditLog, Ledger


class InsufficientFunds(Exception):
    pass


def _month_start(at: datetime) -> datetime:
    return at.replace(day=1, hour=0, minute=0, second=0, microsecond=0)


def withdraw_at_atm(
    account: Account, amount: Decimal, at: datetime, ledger: Ledger, audit: AuditLog
) -> Decimal:
    """Debit an ATM withdrawal and its fee; return the fee charged."""
    if amount <= 0:
        raise ValueError("withdrawal amount must be positive")
    earlier = ledger.count(account.id, "atm_withdrawal", since=_month_start(at))
    fee = fees.atm_fee(account, earlier)
    if account.balance < amount + fee:
        raise InsufficientFunds(account.id)
    account.balance -= amount + fee
    ledger.post(account.id, -amount, "atm_withdrawal", at)
    if fee:
        ledger.post(account.id, -fee, "atm_fee", at)
    audit.record("atm", "withdrawal", account=account.id, amount=str(amount), fee=str(fee))
    return fee
SRC
cat > app/statement.py <<'SRC'
from decimal import Decimal

LABELS = {
    "atm_withdrawal": "ATM withdrawal",
    "atm_fee": "ATM fee",
    "monthly_fee": "Account fee",
}


def statement_lines(entries: list) -> list[str]:
    lines = []
    for entry in sorted(entries, key=lambda e: e["at"]):
        label = LABELS.get(entry["kind"], entry["kind"])
        lines.append(f"{entry['at']:%Y-%m-%d}  {label:<16} {entry['amount']:>9}")
    total = sum((entry["amount"] for entry in entries), Decimal("0.00"))
    lines.append(f"{'':<10}  {'Total':<16} {total:>9}")
    return lines
SRC
cat > tests/test_fees.py <<'SRC'
import unittest
from decimal import Decimal

from app import fees
from tests.support import assert_valid_fee, make_account


class MonthlyFeeTest(unittest.TestCase):
    def test_basic_plan(self):
        self.assertEqual(fees.monthly_fee(make_account("basic")), Decimal("4.95"))

    def test_premium_plan_is_free(self):
        self.assertEqual(fees.monthly_fee(make_account("premium")), Decimal("0.00"))

    def test_every_plan_fee_is_in_the_schedule(self):
        for plan in fees.MONTHLY_FEE:
            assert_valid_fee(self, fees.monthly_fee(make_account(plan)))


class AtmFeeTest(unittest.TestCase):
    def test_first_withdrawal_is_free(self):
        self.assertEqual(fees.atm_fee(make_account("basic"), 0), fees.NO_FEE)

    def test_third_withdrawal_is_free(self):
        fee = fees.atm_fee(make_account("basic"), 2)
        assert_valid_fee(self, fee, expected=fees.NO_FEE)

    def test_fourth_withdrawal_is_charged(self):
        fee = fees.atm_fee(make_account("basic"), 3)
        assert_valid_fee(self, fee, expected=fees.ATM_FEE)

    def test_tenth_withdrawal_is_charged(self):
        self.assertEqual(fees.atm_fee(make_account("basic"), 9), fees.ATM_FEE)

    def test_premium_never_pays(self):
        self.assertEqual(fees.atm_fee(make_account("premium"), 12), fees.NO_FEE)


if __name__ == "__main__":
    unittest.main()
SRC
cat > tests/test_withdrawals.py <<'SRC'
import unittest
from datetime import datetime
from decimal import Decimal

from app.store import AuditLog, Ledger
from app.withdrawals import InsufficientFunds, withdraw_at_atm
from tests.support import make_account


def at(day, hour=12):
    return datetime(2026, 11, day, hour)


class WithdrawAtAtmTest(unittest.TestCase):
    def setUp(self):
        self.ledger = Ledger()
        self.audit = AuditLog()

    def withdraw(self, account, amount, when):
        return withdraw_at_atm(account, Decimal(amount), when, self.ledger, self.audit)

    def test_free_withdrawal_debits_only_the_amount(self):
        account = make_account(balance="100.00")
        self.assertEqual(self.withdraw(account, "40.00", at(3)), Decimal("0.00"))
        self.assertEqual(account.balance, Decimal("60.00"))
        self.assertEqual([e["kind"] for e in self.ledger.entries], ["atm_withdrawal"])

    def test_fifth_withdrawal_debits_the_fee(self):
        account = make_account(balance="500.00")
        for day in range(1, 5):
            self.ledger.post(account.id, Decimal("-10.00"), "atm_withdrawal", at(day))
        self.assertEqual(self.withdraw(account, "10.00", at(6)), Decimal("2.50"))
        self.assertEqual(account.balance, Decimal("487.50"))
        self.assertEqual(self.ledger.entries[-1]["amount"], Decimal("-2.50"))

    def test_count_restarts_each_month(self):
        account = make_account(balance="500.00")
        for hour in range(9, 14):
            self.withdraw(account, "10.00", datetime(2026, 10, 30, hour))
        self.assertEqual(self.withdraw(account, "10.00", at(1)), Decimal("0.00"))

    def test_insufficient_funds_including_fee(self):
        account = make_account(balance="12.00")
        for day in range(1, 6):
            self.ledger.post(account.id, Decimal("-1.00"), "atm_withdrawal", at(day))
        with self.assertRaises(InsufficientFunds):
            self.withdraw(account, "10.00", at(7))
        self.assertEqual(account.balance, Decimal("12.00"))

    def test_audit_record(self):
        account = make_account()
        self.withdraw(account, "20.00", at(2))
        self.assertEqual(
            self.audit.records,
            [{"actor": "atm", "action": "withdrawal", "account": 1, "amount": "20.00", "fee": "0.00"}],
        )


if __name__ == "__main__":
    unittest.main()
SRC
cat > tests/test_statement.py <<'SRC'
import unittest
from datetime import datetime
from decimal import Decimal

from app.statement import statement_lines


class StatementLinesTest(unittest.TestCase):
    def test_fee_line_and_total(self):
        lines = statement_lines([
            {"kind": "atm_withdrawal", "amount": Decimal("-20.00"), "at": datetime(2026, 11, 4)},
            {"kind": "atm_fee", "amount": Decimal("-2.50"), "at": datetime(2026, 11, 4)},
        ])
        self.assertIn("ATM fee", lines[1])
        self.assertTrue(lines[-1].endswith("-22.50"))


if __name__ == "__main__":
    unittest.main()
SRC
git add -A
git commit -q -m "ATM withdrawal fees: first three a month free, then 2.50"
