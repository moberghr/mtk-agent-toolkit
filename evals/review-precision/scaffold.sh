#!/usr/bin/env bash
# Seeds a Python checkout module with carts, fixed-amount coupons and receipts, commits it,
# then commits a change on a feature branch across several files: percentage coupons, coupon
# expiry and minimum order values, case-insensitive codes, a coupon history on the order,
# and coupon labels on the receipt.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

mkdir -p src tests docs .claude
printf 'python\n' > .claude/tech-stack
cat > AGENTS.md <<'DOC'
# checkout

Python 3.12 checkout pricing for the web shop. Standard library only; amounts are
integer cents.

## Build & Test

    python3 -m unittest discover -s tests -t .
DOC
printf '@AGENTS.md\n' > CLAUDE.md
touch src/__init__.py tests/__init__.py

cat > src/cart.py <<'SRC'
from dataclasses import dataclass, field


@dataclass
class Line:
    sku: str
    unit_cents: int
    qty: int


@dataclass
class Cart:
    lines: list[Line] = field(default_factory=list)

    def add(self, sku: str, unit_cents: int, qty: int = 1) -> None:
        for line in self.lines:
            if line.sku == sku:
                line.qty += qty
                return
        self.lines.append(Line(sku, unit_cents, qty))

    def remove(self, sku: str) -> None:
        self.lines = [line for line in self.lines if line.sku != sku]

    def subtotal_cents(self) -> int:
        return sum(line.unit_cents * line.qty for line in self.lines)
SRC

cat > src/coupons.py <<'SRC'
from dataclasses import dataclass
from typing import Optional


@dataclass
class Coupon:
    code: str
    amount_cents: int


@dataclass
class Order:
    subtotal_cents: int
    coupon: Optional[Coupon] = None
    discount_cents: int = 0


def apply_coupon(order: Order, coupon: Coupon) -> None:
    order.coupon = coupon
    order.discount_cents = min(coupon.amount_cents, order.subtotal_cents)


def remove_coupon(order: Order) -> None:
    order.coupon = None


def total_cents(order: Order) -> int:
    return order.subtotal_cents - order.discount_cents
SRC

cat > src/receipt.py <<'SRC'
from src.coupons import Order, total_cents


def _money(cents: int) -> str:
    return f"{cents / 100:.2f}"


def receipt_lines(order: Order) -> list[str]:
    lines = [f"Subtotal {_money(order.subtotal_cents)}"]
    if order.coupon is not None:
        lines.append(f"Coupon {order.coupon.code} -{_money(order.discount_cents)}")
    lines.append(f"Total {_money(total_cents(order))}")
    return lines
SRC

cat > tests/test_cart.py <<'SRC'
import unittest

from src.cart import Cart


class CartTests(unittest.TestCase):
    def test_adding_the_same_sku_increases_quantity(self):
        cart = Cart()
        cart.add("MUG", 1200)
        cart.add("MUG", 1200, qty=2)
        self.assertEqual(len(cart.lines), 1)
        self.assertEqual(cart.subtotal_cents(), 3600)

    def test_remove(self):
        cart = Cart()
        cart.add("MUG", 1200)
        cart.add("TEE", 2500)
        cart.remove("MUG")
        self.assertEqual(cart.subtotal_cents(), 2500)


if __name__ == "__main__":
    unittest.main()
SRC

cat > tests/test_coupons.py <<'SRC'
import unittest

from src.coupons import Coupon, Order, apply_coupon, total_cents
from src.receipt import receipt_lines


class CouponTests(unittest.TestCase):
    def test_fixed_coupon_reduces_total(self):
        order = Order(subtotal_cents=5000)
        apply_coupon(order, Coupon("WELCOME10", amount_cents=1000))
        self.assertEqual(total_cents(order), 4000)

    def test_receipt_without_coupon(self):
        self.assertEqual(receipt_lines(Order(subtotal_cents=1250)), ["Subtotal 12.50", "Total 12.50"])


if __name__ == "__main__":
    unittest.main()
SRC

cat > docs/coupons.md <<'DOC'
# Coupons

A coupon takes a fixed amount off the order subtotal. One coupon per order.
DOC
git add -A
git commit -q -m "Carts, fixed-amount coupons and receipts"

# The change under review, committed on a feature branch.
git checkout -q -b coupon-rules
cat > src/codes.py <<'SRC'
import re

_CODE = re.compile(r"^[A-Z0-9]{4,16}$")


def normalise_code(raw: str) -> str:
    """Coupon codes are case-insensitive and may be typed with spaces or dashes."""
    code = re.sub(r"[\s-]", "", raw).upper()
    if not _CODE.match(code):
        raise ValueError(f"not a coupon code: {raw!r}")
    return code
SRC

cat > src/coupons.py <<'SRC'
from dataclasses import dataclass, field
from datetime import date
from typing import Optional

from src.codes import normalise_code


class CouponNotApplicable(Exception):
    pass


@dataclass
class Coupon:
    code: str
    amount_cents: int = 0
    percent: int = 0
    min_subtotal_cents: int = 0
    expires: Optional[date] = None

    def __post_init__(self) -> None:
        self.code = normalise_code(self.code)


@dataclass
class Order:
    subtotal_cents: int
    coupon: Optional[Coupon] = None
    discount_cents: int = 0
    coupon_history: list[str] = field(default_factory=list)


def _discount_for(coupon: Coupon, subtotal_cents: int) -> int:
    if coupon.percent:
        return subtotal_cents * coupon.percent // 100
    return coupon.amount_cents


def apply_coupon(order: Order, coupon: Coupon, today: Optional[date] = None) -> None:
    today = today or date.today()
    if coupon.expires is not None and today > coupon.expires:
        raise CouponNotApplicable(f"{coupon.code} expired on {coupon.expires.isoformat()}")
    if order.subtotal_cents < coupon.min_subtotal_cents:
        raise CouponNotApplicable(f"{coupon.code} needs a subtotal of at least {coupon.min_subtotal_cents}")
    order.coupon = coupon
    order.discount_cents = _discount_for(coupon, order.subtotal_cents)
    order.coupon_history.append(coupon.code)


def coupon_label(order: Order) -> str:
    coupon = order.coupon
    if coupon.percent:
        return f"{coupon.code} ({coupon.percent}% off)"
    return coupon.code


def remove_coupon(order: Order) -> None:
    if order.coupon is not None:
        order.coupon_history.append(f"-{order.coupon.code}")
    order.coupon = None


def total_cents(order: Order) -> int:
    return order.subtotal_cents - order.discount_cents
SRC

cat > src/receipt.py <<'SRC'
from src.coupons import Order, coupon_label, total_cents


def _money(cents: int) -> str:
    return f"{cents / 100:.2f}"


def receipt_lines(order: Order) -> list[str]:
    lines = [f"Subtotal {_money(order.subtotal_cents)}"]
    if order.coupon is not None:
        lines.append(f"Coupon {coupon_label(order)} -{_money(order.discount_cents)}")
    lines.append(f"Total {_money(total_cents(order))}")
    return lines
SRC

cat > src/cart.py <<'SRC'
from dataclasses import dataclass, field


@dataclass
class Line:
    sku: str
    unit_cents: int
    qty: int


@dataclass
class Cart:
    lines: list[Line] = field(default_factory=list)

    def add(self, sku: str, unit_cents: int, qty: int = 1) -> None:
        if qty < 1:
            raise ValueError("quantity must be at least 1")
        for line in self.lines:
            if line.sku == sku:
                line.qty += qty
                return
        self.lines.append(Line(sku, unit_cents, qty))

    def remove(self, sku: str) -> None:
        self.lines = [line for line in self.lines if line.sku != sku]

    def item_count(self) -> int:
        return sum(line.qty for line in self.lines)

    def subtotal_cents(self) -> int:
        return sum(line.unit_cents * line.qty for line in self.lines)
SRC

cat > tests/test_codes.py <<'SRC'
import unittest

from src.codes import normalise_code


class NormaliseCodeTests(unittest.TestCase):
    def test_case_spaces_and_dashes(self):
        self.assertEqual(normalise_code(" spring-15 "), "SPRING15")

    def test_rejects_junk(self):
        with self.assertRaises(ValueError):
            normalise_code("10%OFF!")


if __name__ == "__main__":
    unittest.main()
SRC

cat > tests/test_coupons.py <<'SRC'
import unittest
from datetime import date

from src.coupons import Coupon, CouponNotApplicable, Order, apply_coupon, remove_coupon, total_cents
from src.receipt import receipt_lines

TODAY = date(2026, 11, 12)


class CouponTests(unittest.TestCase):
    def test_fixed_coupon_reduces_total(self):
        order = Order(subtotal_cents=5000)
        apply_coupon(order, Coupon("WELCOME10", amount_cents=1000), today=TODAY)
        self.assertEqual(total_cents(order), 4000)

    def test_percent_coupon_reduces_total(self):
        order = Order(subtotal_cents=5000)
        apply_coupon(order, Coupon("spring15", percent=15), today=TODAY)
        self.assertEqual(total_cents(order), 4250)

    def test_expired_coupon_is_refused(self):
        order = Order(subtotal_cents=5000)
        with self.assertRaises(CouponNotApplicable):
            apply_coupon(order, Coupon("OCTOBER5", amount_cents=500, expires=date(2026, 10, 31)), today=TODAY)

    def test_minimum_subtotal(self):
        order = Order(subtotal_cents=1500)
        with self.assertRaises(CouponNotApplicable):
            apply_coupon(order, Coupon("BIGBASKET", amount_cents=1000, min_subtotal_cents=3000), today=TODAY)

    def test_history_records_apply_and_remove(self):
        order = Order(subtotal_cents=5000)
        apply_coupon(order, Coupon("WELCOME10", amount_cents=1000), today=TODAY)
        remove_coupon(order)
        self.assertEqual(order.coupon_history, ["WELCOME10", "-WELCOME10"])

    def test_receipt_without_coupon(self):
        self.assertEqual(receipt_lines(Order(subtotal_cents=1250)), ["Subtotal 12.50", "Total 12.50"])

    def test_receipt_with_percent_coupon(self):
        order = Order(subtotal_cents=2000)
        apply_coupon(order, Coupon("SPRING15", percent=15), today=TODAY)
        self.assertEqual(
            receipt_lines(order),
            ["Subtotal 20.00", "Coupon SPRING15 (15% off) -3.00", "Total 17.00"],
        )


if __name__ == "__main__":
    unittest.main()
SRC

cat > tests/test_cart.py <<'SRC'
import unittest

from src.cart import Cart


class CartTests(unittest.TestCase):
    def test_adding_the_same_sku_increases_quantity(self):
        cart = Cart()
        cart.add("MUG", 1200)
        cart.add("MUG", 1200, qty=2)
        self.assertEqual(len(cart.lines), 1)
        self.assertEqual(cart.subtotal_cents(), 3600)
        self.assertEqual(cart.item_count(), 3)

    def test_rejects_zero_quantity(self):
        with self.assertRaises(ValueError):
            Cart().add("MUG", 1200, qty=0)

    def test_remove(self):
        cart = Cart()
        cart.add("MUG", 1200)
        cart.add("TEE", 2500)
        cart.remove("MUG")
        self.assertEqual(cart.subtotal_cents(), 2500)


if __name__ == "__main__":
    unittest.main()
SRC

cat > docs/coupons.md <<'DOC'
# Coupons

A coupon takes a fixed amount or a whole percentage off the order subtotal. One coupon
per order. Codes are case-insensitive; spaces and dashes are ignored. A coupon can have an
expiry date and a minimum subtotal.
DOC
git add -A
git commit -q -m "Percentage coupons, expiry, minimum order and coupon history"
