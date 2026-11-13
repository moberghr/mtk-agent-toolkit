#!/usr/bin/env bash
# Seeds a Python statement tool with a 30-commit history. At the tag v1.4.0 (the fifth
# commit) the sample March statement closes at 1033.18; at HEAD it closes at 1033.17, and
# the unit tests pass at both. Identity and dates are pinned so every commit id is the same
# on every run.
set -euo pipefail
# Ignore the invoking user's global and system git config (a global excludes file, for
# one, would change which files are committed and so every commit id).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Eval GIT_AUTHOR_EMAIL=eval@example.com
export GIT_COMMITTER_NAME=Eval GIT_COMMITTER_EMAIL=eval@example.com

git init -q -b main .
git config user.email eval@example.com
git config user.name Eval
git config commit.gpgsign false
git config tag.gpgsign false

n=0
commit() {
  n=$((n + 1))
  local when
  when="$(printf '2026-10-%02dT%02d:20:00Z' $((1 + n / 2)) $((9 + (n % 2) * 5)))"
  git add -A
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git commit -q -m "$1"
}

mkdir -p ledger tests data .claude
printf 'python\n' > .claude/tech-stack
cat > AGENTS.md <<'DOC'
# ledger

Python 3.12 command-line tool that renders account statements from the bank's JSON
exports. Standard library only.

## Build & Test

    python -m unittest discover -s tests

## Run

    python -m ledger statement <export.json>
DOC
printf '@AGENTS.md\n' > CLAUDE.md
printf '__pycache__/\n*.pyc\n' > .gitignore

cat > ledger/__init__.py <<'SRC'
__version__ = "1.3.0"
SRC
cat > ledger/money.py <<'SRC'
from decimal import ROUND_HALF_UP, Decimal

CENT = Decimal("0.01")


def to_cents(amount: Decimal) -> Decimal:
    """Round to whole cents, half away from zero, as the bank does."""
    return amount.quantize(CENT, rounding=ROUND_HALF_UP)
SRC
cat > ledger/load.py <<'SRC'
import json
from dataclasses import dataclass
from datetime import date, datetime
from decimal import Decimal


@dataclass(frozen=True)
class Line:
    day: date
    description: str
    amount: Decimal


@dataclass(frozen=True)
class Statement:
    account: str
    currency: str
    opening: Decimal
    lines: list


def load(path: str) -> Statement:
    with open(path) as fh:
        raw = json.load(fh)
    lines = [
        Line(
            datetime.strptime(item["date"], "%Y-%m-%d").date(),
            item["description"],
            Decimal(item["amount"]),
        )
        for item in raw["lines"]
    ]
    return Statement(raw["account"], raw["currency"], Decimal(raw["opening"]), lines)
SRC
cat > ledger/statement.py <<'SRC'
from decimal import Decimal

from ledger.load import Statement
from ledger.money import to_cents


def closing_balance(statement: Statement) -> Decimal:
    total = statement.opening + sum((line.amount for line in statement.lines), Decimal(0))
    return to_cents(total)


def render(statement: Statement) -> str:
    out = [f"Statement {statement.account} ({statement.currency})"]
    out.append(f"Opening balance: {to_cents(statement.opening)} {statement.currency}")
    for line in statement.lines:
        out.append(f"{line.day.isoformat()}  {line.description:<34} {to_cents(line.amount):>10}")
    out.append(f"Closing balance: {closing_balance(statement)} {statement.currency}")
    return "\n".join(out)
SRC
cat > ledger/__main__.py <<'SRC'
import argparse
import sys

from ledger.load import load
from ledger.statement import render


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="ledger")
    sub = parser.add_subparsers(dest="command", required=True)
    statement = sub.add_parser("statement", help="print a statement")
    statement.add_argument("path")
    args = parser.parse_args(argv)
    print(render(load(args.path)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
SRC
cat > tests/__init__.py <<'SRC'
SRC
cat > tests/test_statement.py <<'SRC'
import unittest
from datetime import date
from decimal import Decimal

from ledger.load import Line, Statement
from ledger.statement import closing_balance, render


def statement(*amounts, opening="100.00"):
    lines = [
        Line(date(2026, 3, i + 1), f"line {i + 1}", Decimal(amount))
        for i, amount in enumerate(amounts)
    ]
    return Statement("NL01TEST0123456789", "EUR", Decimal(opening), lines)


class ClosingBalanceTest(unittest.TestCase):
    def test_no_lines(self):
        self.assertEqual(closing_balance(statement()), Decimal("100.00"))

    def test_credits_and_debits(self):
        self.assertEqual(closing_balance(statement("25.50", "-10.25")), Decimal("115.25"))

    def test_rounds_half_up(self):
        self.assertEqual(closing_balance(statement("0.004", "0.001")), Decimal("100.01"))


class RenderTest(unittest.TestCase):
    def test_shows_closing_balance(self):
        self.assertIn("Closing balance: 115.25 EUR", render(statement("25.50", "-10.25")))


if __name__ == "__main__":
    unittest.main()
SRC
commit "Statement command: opening, lines and closing balance"

cat > ledger/export.py <<'SRC'
import csv
import io

from ledger.load import Statement
from ledger.money import to_cents


def lines_csv(statement: Statement) -> str:
    out = io.StringIO()
    writer = csv.writer(out)
    writer.writerow(["date", "description", "amount", "currency"])
    for line in statement.lines:
        writer.writerow([line.day.isoformat(), line.description, to_cents(line.amount), statement.currency])
    return out.getvalue()
SRC
cat > tests/test_export.py <<'SRC'
import unittest
from datetime import date
from decimal import Decimal

from ledger.export import lines_csv
from ledger.load import Line, Statement


class ExportTest(unittest.TestCase):
    def test_one_row_per_line(self):
        statement = Statement(
            "NL01TEST0123456789", "EUR", Decimal("0"),
            [Line(date(2026, 3, 2), "Coffee", Decimal("-3.20"))],
        )
        self.assertEqual(
            lines_csv(statement).splitlines(),
            ["date,description,amount,currency", "2026-03-02,Coffee,-3.20,EUR"],
        )


if __name__ == "__main__":
    unittest.main()
SRC
commit "Add CSV export of statement lines"

python3 - <<'PY'
p = "ledger/__main__.py"
s = open(p).read()
s = s.replace("from ledger.load import load\n", "from ledger.export import lines_csv\nfrom ledger.load import load\n")
s = s.replace('    statement.add_argument("path")\n', '    statement.add_argument("path")\n    export = sub.add_parser("export", help="statement lines as CSV")\n    export.add_argument("path")\n')
s = s.replace("    print(render(load(args.path)))\n", "    if args.command == \"export\":\n        sys.stdout.write(lines_csv(load(args.path)))\n    else:\n        print(render(load(args.path)))\n")
open(p, "w").write(s)
PY
commit "Wire the export subcommand"

cat > data/sample-2026-03.json <<'JSON'
{
  "account": "NL20INGB0001234567",
  "currency": "EUR",
  "opening": "1000.00",
  "lines": [
    {"date": "2026-03-02", "description": "Transfer from savings", "amount": "100.00", "category": "income"},
    {"date": "2026-03-04", "description": "Supermarket", "amount": "-23.45", "category": "groceries"},
    {"date": "2026-03-09", "description": "Card USD 10.99 music subscription", "amount": "-10.0060", "category": "subscriptions"},
    {"date": "2026-03-12", "description": "Card GBP 12.40 rail ticket", "amount": "-14.2735", "category": "travel"},
    {"date": "2026-03-15", "description": "Refund webshop", "amount": "20.00", "category": "income"},
    {"date": "2026-03-18", "description": "Market stall", "amount": "-22.22", "category": "groceries"},
    {"date": "2026-03-23", "description": "Card GBP 14.70 hotel city tax", "amount": "-16.8735", "category": "travel"}
  ]
}
JSON
commit "Add the March sample export used in support tickets"

printf '__version__ = "1.4.0"\n' > ledger/__init__.py
cat > CHANGES.md <<'DOC'
# Changes

## 1.4.0

- `export` subcommand: statement lines as CSV.
DOC
commit "Release 1.4.0"
git tag v1.4.0

sed -i.bak 's/            datetime.strptime(item\["date"\], "%Y-%m-%d").date(),/            date.fromisoformat(item["date"]),/' ledger/load.py
sed -i.bak 's/^from datetime import date, datetime$/from datetime import date/' ledger/load.py
rm -f ledger/load.py.bak
commit "Parse dates with date.fromisoformat"

cat > README.md <<'DOC'
# ledger

Renders account statements from the bank's JSON exports.

    python -m ledger statement export.json
    python -m ledger export export.json > lines.csv
DOC
commit "README with usage"

python3 - <<'PY'
p = "ledger/export.py"
s = open(p).read()
s = s.replace("from ledger.money import to_cents\n", "from decimal import ROUND_HALF_EVEN, Decimal\n\nfrom ledger.money import CENT\n")
s = s.replace("to_cents(line.amount)", "line.amount.quantize(CENT, rounding=ROUND_HALF_EVEN)")
open(p, "w").write(s)
PY
commit "Use banker's rounding for CSV amounts, as accounting imports expect"

mkdir -p .github/workflows
cat > .github/workflows/tests.yml <<'YML'
name: tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - run: python -m unittest discover -s tests
YML
commit "CI: run the unit tests"

python3 - <<'PY'
p = "ledger/load.py"
s = open(p).read()
s = s.replace("    amount: Decimal\n\n\n@dataclass", "    amount: Decimal\n    category: str = \"other\"\n\n\n@dataclass")
s = s.replace("            Decimal(item[\"amount\"]),\n        )", "            Decimal(item[\"amount\"]),\n            item.get(\"category\", \"other\"),\n        )")
open(p, "w").write(s)
PY
commit "Read the category of each line"

python3 - <<'PY'
p = "ledger/statement.py"
s = open(p).read()
s = s.replace('    out = [f"Statement {statement.account} ({statement.currency})"]\n',
              '    first = statement.lines[0].day if statement.lines else None\n'
              '    period = first.strftime("%B %Y") if first else "no transactions"\n'
              '    out = [f"Account {statement.account} - {period} - {statement.currency}"]\n')
open(p, "w").write(s)
PY
commit "Statement header shows the account and the period"

python3 - <<'PY'
p = "ledger/money.py"
s = open(p).read()
s += '''

def fmt(amount: Decimal, currency: str = "") -> str:
    """Whole cents with a thousands separator, optionally followed by the currency."""
    text = f"{to_cents(amount):,.2f}"
    return f"{text} {currency}" if currency else text
'''
open(p, "w").write(s)
p = "ledger/statement.py"
s = open(p).read()
s = s.replace("from ledger.money import to_cents\n", "from ledger.money import fmt, to_cents\n")
s = s.replace('f"Opening balance: {to_cents(statement.opening)} {statement.currency}"', 'f"Opening balance: {fmt(statement.opening, statement.currency)}"')
s = s.replace("{to_cents(line.amount):>10}", "{fmt(line.amount):>10}")
s = s.replace('f"Closing balance: {closing_balance(statement)} {statement.currency}"', 'f"Closing balance: {fmt(closing_balance(statement), statement.currency)}"')
open(p, "w").write(s)
PY
commit "Move amount formatting into money.fmt"

python3 - <<'PY'
p = "ledger/load.py"
s = open(p).read()
s = s.replace("from decimal import Decimal\n", "from decimal import Decimal\n\nfrom ledger.money import to_cents\n")
s = s.replace("Decimal(raw[\"opening\"]), lines)", "to_cents(Decimal(raw[\"opening\"])), lines)")
open(p, "w").write(s)
PY
commit "Quantize the opening balance on load"

cat > tests/test_load.py <<'SRC'
import json
import os
import tempfile
import unittest
from datetime import date
from decimal import Decimal

from ledger.load import load


class LoadTest(unittest.TestCase):
    def write(self, body):
        fd, path = tempfile.mkstemp(suffix=".json")
        with os.fdopen(fd, "w") as fh:
            json.dump(body, fh)
        self.addCleanup(os.remove, path)
        return path

    def test_reads_lines_and_category(self):
        path = self.write({
            "account": "A", "currency": "EUR", "opening": "5",
            "lines": [{"date": "2026-03-01", "description": "x", "amount": "-1.5", "category": "travel"}],
        })
        statement = load(path)
        self.assertEqual(statement.opening, Decimal("5.00"))
        self.assertEqual(statement.lines[0].day, date(2026, 3, 1))
        self.assertEqual(statement.lines[0].category, "travel")

    def test_category_defaults_to_other(self):
        path = self.write({
            "account": "A", "currency": "EUR", "opening": "0",
            "lines": [{"date": "2026-03-01", "description": "x", "amount": "1"}],
        })
        self.assertEqual(load(path).lines[0].category, "other")


if __name__ == "__main__":
    unittest.main()
SRC
commit "Tests for loading exports"

python3 - <<'PY'
p = "ledger/__main__.py"
s = open(p).read()
s = s.replace("import argparse\n", "import argparse\nimport json\n")
s = s.replace('    statement.add_argument("path")\n', '    statement.add_argument("path")\n    statement.add_argument("--json", action="store_true", help="print JSON instead of text")\n')
s = s.replace("    else:\n        print(render(load(args.path)))\n",
              "    elif args.json:\n        print(json.dumps(as_dict(load(args.path)), indent=2))\n    else:\n        print(render(load(args.path)))\n")
s = s.replace("from ledger.statement import render\n", "from ledger.statement import as_dict, render\n")
open(p, "w").write(s)
p = "ledger/statement.py"
s = open(p).read()
s += '''

def as_dict(statement: Statement) -> dict:
    return {
        "account": statement.account,
        "currency": statement.currency,
        "opening": str(statement.opening),
        "lines": [
            {"date": line.day.isoformat(), "description": line.description, "amount": str(line.amount)}
            for line in statement.lines
        ],
    }
'''
open(p, "w").write(s)
PY
commit "statement --json"

sed -i.bak 's/python-version: "3.12"/python-version: ["3.12", "3.13"]/' .github/workflows/tests.yml
python3 - <<'PY'
p = ".github/workflows/tests.yml"
s = open(p).read()
s = s.replace("    runs-on: ubuntu-latest\n", "    runs-on: ubuntu-latest\n    strategy:\n      matrix:\n        python: [\"3.12\", \"3.13\"]\n")
s = s.replace('          python-version: ["3.12", "3.13"]', '          python-version: ${{ matrix.python }}')
open(p, "w").write(s)
PY
rm -f .github/workflows/tests.yml.bak
commit "CI: test on Python 3.12 and 3.13"

python3 - <<'PY'
p = "ledger/load.py"
s = open(p).read()
s = s.replace("from ledger.money import to_cents\n", "from ledger.money import to_cents\n\nFX_PLACES = Decimal(\"0.0001\")\n")
s = s.replace("            Decimal(item[\"amount\"]),\n", "            Decimal(item[\"amount\"]).quantize(FX_PLACES),\n")
open(p, "w").write(s)
PY
commit "Keep converted card amounts at four decimals on load"

cat >> README.md <<'DOC'

## Categories

Each line in an export may carry a `category` (`income`, `groceries`, `travel`, ...).
Lines without one are filed under `other`.
DOC
commit "Document line categories"

cat > ledger/summary.py <<'SRC'
from collections import defaultdict
from dataclasses import dataclass
from decimal import Decimal

from ledger.money import to_cents


@dataclass(frozen=True)
class CategoryTotal:
    category: str
    total: Decimal


def category_totals(lines) -> list[CategoryTotal]:
    """One total per category, in cents, sorted by category name."""
    totals: dict[str, Decimal] = defaultdict(Decimal)
    for line in lines:
        totals[line.category] += line.amount
    return [CategoryTotal(name, to_cents(total)) for name, total in sorted(totals.items())]
SRC
python3 - <<'PY'
p = "ledger/statement.py"
s = open(p).read()
s = s.replace("from ledger.money import fmt, to_cents\n", "from ledger.money import fmt\nfrom ledger.summary import category_totals\n")
s = s.replace(
    "def closing_balance(statement: Statement) -> Decimal:\n"
    "    total = statement.opening + sum((line.amount for line in statement.lines), Decimal(0))\n"
    "    return to_cents(total)\n",
    "def closing_balance(statement: Statement) -> Decimal:\n"
    "    \"\"\"Opening balance plus the category totals, so the printed subtotals add up.\"\"\"\n"
    "    subtotals = category_totals(statement.lines)\n"
    "    return statement.opening + sum((item.total for item in subtotals), Decimal(0))\n")
s = s.replace(
    '    out.append(f"Closing balance: ',
    '    out.append("")\n'
    '    for item in category_totals(statement.lines):\n'
    '        out.append(f"  {item.category:<20} {fmt(item.total):>10}")\n'
    '    out.append(f"Closing balance: ')
open(p, "w").write(s)
PY
cat > tests/test_summary.py <<'SRC'
import unittest
from datetime import date
from decimal import Decimal

from ledger.load import Line
from ledger.summary import CategoryTotal, category_totals


def line(amount, category):
    return Line(date(2026, 3, 1), "x", Decimal(amount), category)


class CategoryTotalsTest(unittest.TestCase):
    def test_groups_and_sorts(self):
        totals = category_totals([line("-5.00", "travel"), line("10.00", "income"), line("-2.50", "travel")])
        self.assertEqual(
            totals,
            [CategoryTotal("income", Decimal("10.00")), CategoryTotal("travel", Decimal("-7.50"))],
        )

    def test_empty(self):
        self.assertEqual(category_totals([]), [])


if __name__ == "__main__":
    unittest.main()
SRC
commit "Show subtotals per category in the statement"

python3 - <<'PY'
p = "ledger/load.py"
s = open(p).read()
s = s.replace("        for item in raw[\"lines\"]\n    ]\n", "        for item in raw[\"lines\"]\n    ]\n    lines.sort(key=lambda line: (line.day, line.description))\n")
open(p, "w").write(s)
PY
commit "Sort lines by date, then description"

sed -i.bak 's/help="print a statement"/help="print a statement with its closing balance"/' ledger/__main__.py
rm -f ledger/__main__.py.bak
commit "Clearer help for the statement command"

python3 - <<'PY'
p = "ledger/statement.py"
s = open(p).read()
s = s.replace('        "opening": str(statement.opening),\n', '        "opening": str(statement.opening),\n        "closing": str(closing_balance(statement)),\n')
open(p, "w").write(s)
PY
python3 - <<'PY'
p = "tests/test_statement.py"
s = open(p).read()
s = s.replace("from ledger.statement import closing_balance, render\n", "from ledger.statement import as_dict, closing_balance, render\n")
s = s.replace(
    "\n\nif __name__ == \"__main__\":",
    "\n\nclass AsDictTest(unittest.TestCase):\n"
    "    def test_includes_closing(self):\n"
    "        self.assertEqual(as_dict(statement(\"1.00\"))[\"closing\"], \"101.00\")\n"
    "\n\nif __name__ == \"__main__\":")
open(p, "w").write(s)
PY
commit "Closing balance in the JSON output"

python3 - <<'PY'
p = "ledger/load.py"
s = open(p).read()
s = s.replace(
    "def load(path: str) -> Statement:\n    with open(path) as fh:\n        raw = json.load(fh)\n    lines = [\n        Line(\n            date.fromisoformat(item[\"date\"]),\n            item[\"description\"],\n            Decimal(item[\"amount\"]).quantize(FX_PLACES),\n            item.get(\"category\", \"other\"),\n        )\n        for item in raw[\"lines\"]\n    ]\n",
    "def _line(item: dict) -> Line:\n    return Line(\n        date.fromisoformat(item[\"date\"]),\n        item[\"description\"],\n        Decimal(item[\"amount\"]).quantize(FX_PLACES),\n        item.get(\"category\", \"other\"),\n    )\n\n\ndef load(path: str) -> Statement:\n    with open(path) as fh:\n        raw = json.load(fh)\n    lines = [_line(item) for item in raw[\"lines\"]]\n")
open(p, "w").write(s)
PY
commit "Split line parsing out of load()"

python3 - <<'PY'
p = "ledger/money.py"
s = open(p).read()
s = s.replace('    """Round to whole cents, half away from zero, as the bank does."""\n',
              '    """Round to whole cents, half away from zero (ROUND_HALF_UP), as the bank does.\n\n    Use it for amounts shown to customers. CSV exports for accounting use banker\'s\n    rounding instead; see ledger.export.\n    """\n')
open(p, "w").write(s)
PY
commit "Document the rounding rule of to_cents"

python3 - <<'PY'
p = "ledger/__main__.py"
s = open(p).read()
s = s.replace('    statement.add_argument("--json", action="store_true", help="print JSON instead of text")\n',
              '    statement.add_argument("--json", action="store_true", help="print JSON instead of text")\n    statement.add_argument("--no-lines", action="store_true", help="balances and subtotals only")\n')
s = s.replace("        print(render(load(args.path)))\n", "        print(render(load(args.path), show_lines=not args.no_lines))\n")
open(p, "w").write(s)
p = "ledger/statement.py"
s = open(p).read()
s = s.replace("def render(statement: Statement) -> str:\n", "def render(statement: Statement, show_lines: bool = True) -> str:\n")
s = s.replace("    for line in statement.lines:\n        out.append(", "    for line in statement.lines if show_lines else []:\n        out.append(")
open(p, "w").write(s)
PY
commit "statement --no-lines"

cat > tests/test_cli.py <<'SRC'
import contextlib
import io
import json
import os
import tempfile
import unittest

from ledger.__main__ import main

EXPORT = {
    "account": "NL01TEST0123456789", "currency": "EUR", "opening": "10.00",
    "lines": [{"date": "2026-03-01", "description": "Coffee", "amount": "-2.50", "category": "food"}],
}


class CliTest(unittest.TestCase):
    def run_cli(self, *args):
        fd, path = tempfile.mkstemp(suffix=".json")
        with os.fdopen(fd, "w") as fh:
            json.dump(EXPORT, fh)
        self.addCleanup(os.remove, path)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(main([args[0], path, *args[1:]]), 0)
        return out.getvalue()

    def test_statement_text(self):
        self.assertIn("Closing balance: 7.50 EUR", self.run_cli("statement"))

    def test_statement_json(self):
        self.assertEqual(json.loads(self.run_cli("statement", "--json"))["closing"], "7.50")

    def test_no_lines_hides_lines(self):
        self.assertNotIn("Coffee", self.run_cli("statement", "--no-lines"))


if __name__ == "__main__":
    unittest.main()
SRC
commit "CLI tests"

printf '__version__ = "1.5.0.dev0"\n' > ledger/__init__.py
commit "Start 1.5.0 development"

python3 - <<'PY'
p = "ledger/statement.py"
s = open(p).read()
s = s.replace("from decimal import Decimal\n", "from decimal import Decimal\nfrom typing import Any\n", 1)
s = s.replace("def as_dict(statement: Statement) -> dict:", "def as_dict(statement: Statement) -> dict[str, Any]:")
open(p, "w").write(s)
PY
commit "Type hints for the JSON output"

cat > CHANGES.md <<'DOC'
# Changes

## 1.5.0 (unreleased)

- Header shows the account and the statement period.
- Subtotals per category under the lines.
- `statement --json` and `statement --no-lines`.
- CSV amounts use banker's rounding.

## 1.4.0

- `export` subcommand: statement lines as CSV.
DOC
commit "Changelog for 1.5.0"

python3 - <<'PY'
p = "README.md"
s = open(p).read()
s = s.replace("    python -m ledger export export.json > lines.csv\n", "    python -m ledger statement export.json --json\n    python -m ledger statement export.json --no-lines\n    python -m ledger export export.json > lines.csv\n")
open(p, "w").write(s)
PY
commit "README: new statement options"

python3 - <<'PY'
p = "ledger/export.py"
s = open(p).read()
s = s.replace('    writer.writerow(["date", "description", "amount", "currency"])\n', '    writer.writerow(["date", "description", "category", "amount", "currency"])\n')
s = s.replace("        writer.writerow([line.day.isoformat(), line.description, line.amount", "        writer.writerow([line.day.isoformat(), line.description, line.category, line.amount")
open(p, "w").write(s)
p = "tests/test_export.py"
s = open(p).read()
s = s.replace('["date,description,amount,currency", "2026-03-02,Coffee,-3.20,EUR"]', '["date,description,category,amount,currency", "2026-03-02,Coffee,other,-3.20,EUR"]')
open(p, "w").write(s)
PY
commit "Category column in the CSV export"

