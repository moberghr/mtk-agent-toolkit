#!/usr/bin/env bash
# Seeds a small repo whose last commit changed three files, plus a reviewer lane result
# that claims PASS but whose coverage accounts for only two of them.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

mkdir -p src review
cat > AGENTS.md <<'DOC'
# invoice-tools

Small Python utility library.

## Build & Test

No automated tests.
DOC
printf '@AGENTS.md\n' > CLAUDE.md
printf 'def total(items):\n    return sum(items)\n' > src/totals.py
git add -A
git commit -q -m "Initial commit"

printf 'def total(items):\n    return round(sum(items), 2)\n' > src/totals.py
printf 'def fmt(amount):\n    return f"{amount:.2f}"\n' > src/format.py
printf 'def tax(amount, rate):\n    return amount * rate\n' > src/tax.py
git add -A
git commit -q -m "Round totals, add formatting and tax helpers"

printf 'src/totals.py\nsrc/format.py\nsrc/tax.py\n' > review/changed-files.txt
cat > review/lane-result.json <<'JSON'
{
  "verdict": "PASS",
  "coverage": {
    "no_issues": ["src/totals.py", "src/format.py"],
    "skipped": []
  },
  "threshold": 80,
  "summary": { "critical": 0, "warning": 0, "suggestion": 0, "filtered_below_threshold": 0 },
  "findings": [],
  "below_threshold_rationale": "Reviewed the rounding and formatting changes; nothing reached the threshold."
}
JSON
git add -A
git commit -q -m "Add review inputs"
