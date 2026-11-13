#!/usr/bin/env bash
# Seeds a Bash invoicing library with a 34-commit history. tests/run.sh passes at the tag
# v1.2.0 (the third commit) and fails at HEAD. Identity and dates are pinned so every
# commit id is the same on every run.
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
  when="$(printf '2026-09-%02dT%02d:15:00Z' $((1 + n / 2)) $((9 + (n % 2) * 5)))"
  git add -A
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git commit -q -m "$1"
}

# tests/run.sh is rewritten as the library grows; these flags say which checks it holds.
T_FORMAT=0 T_TIER15=0 T_EXPORT=0 T_MATH=0 T_EXPORT_CCY=0
write_tests() {
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -u' 'cd "$(dirname "$0")/.."'
    [ "$T_MATH" = 1 ] && printf '%s\n' '. lib/math.sh'
    printf '%s\n' '. lib/pricing.sh' '. lib/invoice.sh'
    [ "$T_FORMAT" = 1 ] && printf '%s\n' '. lib/format.sh'
    [ "$T_EXPORT" = 1 ] && printf '%s\n' '. lib/export.sh'
    cat <<'SRC'

passed=0
failed=0
check() {
  if [ "$2" = "$3" ]; then
    passed=$((passed + 1))
    echo "ok   $1"
  else
    failed=$((failed + 1))
    echo "FAIL $1: expected $2, got $3"
  fi
}

apply_discount 5000
check "no discount below 100.00" 5000 "$DISCOUNTED"
apply_discount 20000
check "5% from 100.00" 19000 "$DISCOUNTED"
apply_discount 60000
check "8% from 500.00" 55200 "$DISCOUNTED"
SRC
    if [ "$T_TIER15" = 1 ]; then
      printf '%s\n' 'apply_discount 200000' 'check "15% from 2000.00" 170000 "$DISCOUNTED"'
    fi
    cat <<'SRC'

PRICES=(2500); QTYS=(2)
check "invoice with one line" 5000 "$(invoice_total)"
PRICES=(2500 12050 999); QTYS=(2 1 3)
check "invoice with three lines" 19444 "$(invoice_total)"
SRC
    if [ "$T_FORMAT" = 1 ]; then
      printf '\n%s\n%s\n' 'check "format whole amount" "12.00" "$(format_cents 1200)"' \
        'check "format with cents" "1234.56" "$(format_cents 123456)"'
    fi
    if [ "$T_MATH" = 1 ]; then
      printf '%s\n' 'check "percent_of a round amount" 1000 "$(percent_of 20000 5)"'
    fi
    if [ "$T_EXPORT" = 1 ]; then
      if [ "$T_EXPORT_CCY" = 1 ]; then
        printf '%s\n' 'PRICES=(2500 999); QTYS=(2 3)' \
          'check "csv export header" "line,qty,unit,currency" "$(export_csv EUR | head -1)"' \
          'check "csv export first line" "1,2,25.00,EUR" "$(export_csv EUR | sed -n 2p)"'
      else
        printf '%s\n' 'PRICES=(2500 999); QTYS=(2 3)' \
          'check "csv export header" "line,qty,unit" "$(export_csv | head -1)"' \
          'check "csv export first line" "1,2,25.00" "$(export_csv | sed -n 2p)"'
      fi
    fi
    printf '\n%s\n%s\n' 'echo "tests: $passed passed, $failed failed"' '[ "$failed" -eq 0 ]'
  } > tests/run.sh
  chmod +x tests/run.sh
}

mkdir -p lib tests bin docs examples
cat > AGENTS.md <<'DOC'
# invoicer

Bash library that prices orders and prints invoices and receipts. Amounts are integer
cents. Bash 3.2 compatible.

## Build & Test

    bash tests/run.sh
DOC
printf '@AGENTS.md\n' > CLAUDE.md

cat > lib/pricing.sh <<'SRC'
# apply_discount PRICE_CENTS: sets DISCOUNTED to the unit price after the volume discount.
apply_discount() {
  local price=$1
  DISCOUNTED=$price
  if [ "$price" -ge 50000 ]; then
    DISCOUNTED=$((price * 92 / 100))
  elif [ "$price" -ge 10000 ]; then
    DISCOUNTED=$((price * 95 / 100))
  fi
}
SRC
cat > lib/invoice.sh <<'SRC'
# invoice_total: prints the total in cents of the lines in PRICES (unit cents) and QTYS.
invoice_total() {
  local total=0 i
  for ((i = 0; i < ${#PRICES[@]}; i++)); do
    apply_discount "${PRICES[$i]}"
    total=$((total + QTYS[$i] * DISCOUNTED))
  done
  echo "$total"
}
SRC
write_tests
commit "Initial invoice calculator"

cat > README.md <<'DOC'
# invoicer

Source the files in `lib/` and call the functions. All amounts are integer cents.

    . lib/pricing.sh
    . lib/invoice.sh
    PRICES=(2500 999); QTYS=(2 3)
    invoice_total   # 7997
DOC
commit "Add README with usage"

cat > lib/format.sh <<'SRC'
# format_cents CENTS: prints CENTS as a decimal amount with two places, e.g. 123456 -> 1234.56
format_cents() {
  local cents=$1
  echo "$((cents / 100)).$(printf '%02d' $((cents % 100)))"
}
SRC
T_FORMAT=1; write_tests
commit "Add format_cents for display"
git tag v1.2.0

printf '\nDiscounts are applied to the unit price, and the discounted unit price is rounded down to the cent.\n' >> README.md
commit "Document rounding"

cat > lib/receipt.sh <<'SRC'
# print_receipt: prints the lines in PRICES/QTYS and the invoice total.
print_receipt() {
  local i
  for ((i = 0; i < ${#PRICES[@]}; i++)); do
    echo "${QTYS[$i]} x $(format_cents "${PRICES[$i]}")"
  done
  echo "TOTAL $(format_cents "$(invoice_total)")"
}
SRC
commit "Add receipt printer"

cat > lib/format.sh <<'SRC'
# format_cents CENTS: prints CENTS as a decimal amount with two places, e.g. 123456 -> 1234.56
format_cents() {
  printf '%d.%02d\n' $(($1 / 100)) $(($1 % 100))
}
SRC
commit "Use printf in format_cents"

cat > lib/receipt.sh <<'SRC'
# print_receipt [CURRENCY]: prints the lines in PRICES/QTYS and the invoice total.
print_receipt() {
  local currency=${1:-EUR} i
  echo "Receipt ($currency)"
  for ((i = 0; i < ${#PRICES[@]}; i++)); do
    echo "${QTYS[$i]} x $(format_cents "${PRICES[$i]}")"
  done
  echo "TOTAL $(format_cents "$(invoice_total)") $currency"
}
SRC
commit "Add currency code to receipt header"

cat > CHANGELOG.md <<'DOC'
# Changelog

## 1.2.0

- `format_cents` for display.
DOC
commit "Add CHANGELOG"

cat > lib/pricing.sh <<'SRC'
# Volume discount tiers, lowest first: "minimum unit price in cents:percent off".
DISCOUNT_TIERS=(10000:5 50000:8)

# apply_discount PRICE_CENTS: sets DISCOUNTED to the unit price after the volume discount.
apply_discount() {
  local price=$1 tier min pct t
  DISCOUNTED=$price
  for ((t = 0; t < ${#DISCOUNT_TIERS[@]}; t++)); do
    tier=${DISCOUNT_TIERS[$t]}
    min=${tier%%:*}
    pct=${tier##*:}
    if [ "$price" -ge "$min" ]; then
      DISCOUNTED=$((price * (100 - pct) / 100))
    fi
  done
}
SRC
commit "Move discount thresholds into a table"

sed 's/^Discounts are applied/Volume discounts are applied/' README.md > README.md.tmp && mv README.md.tmp README.md
commit "Clarify README wording"

cat > lib/receipt.sh <<'SRC'
# print_receipt [CURRENCY]: prints the lines in PRICES/QTYS, the tax and the invoice total.
TAX_PERCENT=${TAX_PERCENT:-0}
print_receipt() {
  local currency=${1:-EUR} i total tax
  echo "Receipt ($currency)"
  for ((i = 0; i < ${#PRICES[@]}; i++)); do
    echo "${QTYS[$i]} x $(format_cents "${PRICES[$i]}")"
  done
  total=$(invoice_total)
  tax=$((total * TAX_PERCENT / 100))
  echo "TAX $(format_cents "$tax") $currency"
  echo "TOTAL $(format_cents $((total + tax))) $currency"
}
SRC
commit "Add tax line to receipt"

cat > CONTRIBUTING.md <<'DOC'
# Contributing

Keep everything Bash 3.2 compatible and run `bash tests/run.sh` before pushing.
DOC
commit "Add contributing notes"

cat > lib/invoice.sh <<'SRC'
# invoice_total: prints the total in cents of the lines in PRICES (unit cents) and QTYS.
# Returns 1 without printing a total when a quantity is not a positive integer.
invoice_total() {
  local total=0 i
  for ((i = 0; i < ${#PRICES[@]}; i++)); do
    case "${QTYS[$i]}" in
      ''|*[!0-9]*|0) echo "invalid quantity on line $((i + 1))" >&2; return 1 ;;
    esac
    apply_discount "${PRICES[$i]}"
    total=$((total + QTYS[$i] * DISCOUNTED))
  done
  echo "$total"
}
SRC
commit "Validate quantities in invoice_total"

printf '1.3.0-dev\n' > VERSION
commit "Start 1.3.0 development"

sed 's/^  total=\$(invoice_total)$/  total=$(invoice_total) || return 1/' \
  lib/receipt.sh > lib/receipt.sh.tmp && mv lib/receipt.sh.tmp lib/receipt.sh
commit "Stop receipt on an invalid invoice"

cat > lib/export.sh <<'SRC'
# export_csv: prints the lines in PRICES/QTYS as CSV with a header row.
export_csv() {
  local i
  echo "line,qty,unit"
  for ((i = 0; i < ${#PRICES[@]}; i++)); do
    echo "$((i + 1)),${QTYS[$i]},$(format_cents "${PRICES[$i]}")"
  done
}
SRC
commit "Add CSV export of invoice lines"

T_EXPORT=1; write_tests
commit "Test CSV export"

printf '\n`print_receipt [CURRENCY]` prints a receipt; set `TAX_PERCENT` to add a tax line.\n' >> README.md
commit "Document print_receipt"

cat > lib/math.sh <<'SRC'
# percent_of AMOUNT PERCENT: prints PERCENT percent of AMOUNT cents, rounded down to the cent.
# Splits off the whole units first so large amounts stay well inside 64-bit arithmetic.
percent_of() {
  local whole=$(($1 / 100)) part=$(($1 % 100))
  echo $((whole * $2 + part * $2 / 100))
}
SRC
sed 's/^      DISCOUNTED=\$((price \* (100 - pct) \/ 100))$/      DISCOUNTED=$((price - $(percent_of "$price" "$pct")))/' \
  lib/pricing.sh > lib/pricing.sh.tmp && mv lib/pricing.sh.tmp lib/pricing.sh
sed 's/^  tax=\$((total \* TAX_PERCENT \/ 100))$/  tax=$(percent_of "$total" "$TAX_PERCENT")/' \
  lib/receipt.sh > lib/receipt.sh.tmp && mv lib/receipt.sh.tmp lib/receipt.sh
T_MATH=1; write_tests
commit "Extract percent_of helper for discounts and tax"

printf '\nUse integer cents everywhere; never floating point.\n' >> CONTRIBUTING.md
commit "Note the integer-cents rule"

cat > bin/invoicer <<'SRC'
#!/usr/bin/env bash
# invoicer: prints a receipt for "unit_cents qty" pairs given as arguments.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
. "$here/lib/math.sh"; . "$here/lib/pricing.sh"; . "$here/lib/invoice.sh"
. "$here/lib/format.sh"; . "$here/lib/receipt.sh"
PRICES=(); QTYS=()
while [ $# -ge 2 ]; do PRICES+=("$1"); QTYS+=("$2"); shift 2; done
print_receipt
SRC
chmod +x bin/invoicer
commit "Add bin/invoicer command-line entry point"

cat > bin/invoicer <<'SRC'
#!/usr/bin/env bash
# invoicer [FILE]: prints a receipt for "unit_cents qty" lines read from FILE or stdin.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
. "$here/lib/math.sh"; . "$here/lib/pricing.sh"; . "$here/lib/invoice.sh"
. "$here/lib/format.sh"; . "$here/lib/receipt.sh"
PRICES=(); QTYS=()
while read -r price qty; do
  [ -n "$price" ] || continue
  PRICES+=("$price"); QTYS+=("$qty")
done < "${1:-/dev/stdin}"
print_receipt
SRC
commit "Read invoice lines from a file in bin/invoicer"

sed 's/^print_receipt$/print_receipt "${CURRENCY:-EUR}"/' bin/invoicer > bin/invoicer.tmp && mv bin/invoicer.tmp bin/invoicer
chmod +x bin/invoicer
commit "Let bin/invoicer take the currency from CURRENCY"

cat >> CHANGELOG.md <<'DOC'

## 1.3.0 (unreleased)

- Receipts with currency and tax lines.
- CSV export of invoice lines.
DOC
commit "Update CHANGELOG for 1.3.0"

printf '# shellcheck shell=bash\n' | cat - lib/receipt.sh > lib/receipt.sh.tmp && mv lib/receipt.sh.tmp lib/receipt.sh
commit "Add shellcheck directive to receipt.sh"

cat > docs/pricing.md <<'DOC'
# Pricing

Volume discounts depend on the unit price, from `DISCOUNT_TIERS` in `lib/pricing.sh`:

| Unit price from | Discount |
|---|---|
| 100.00 | 5% |
| 500.00 | 8% |
DOC
commit "Describe discount tiers in docs/pricing.md"

sed 's/^DISCOUNT_TIERS=(10000:5 50000:8)$/DISCOUNT_TIERS=(10000:5 50000:8 200000:15)/' lib/pricing.sh > lib/pricing.sh.tmp && mv lib/pricing.sh.tmp lib/pricing.sh
printf '| 2000.00 | 15%% |\n' >> docs/pricing.md
T_TIER15=1; write_tests
commit "Add a 15% tier from 2000.00"

sed 's/Source the files/Source the files/; s/call the functions\./call the functions./; s/All amounts are integer cents\./All amounts are in integer cents./' README.md > README.md.tmp && mv README.md.tmp README.md
commit "Tweak README wording"

printf '# shellcheck shell=bash\n' | cat - lib/export.sh > lib/export.sh.tmp && mv lib/export.sh.tmp lib/export.sh
printf '# shellcheck shell=bash\n' | cat - lib/format.sh > lib/format.sh.tmp && mv lib/format.sh.tmp lib/format.sh
commit "Add shellcheck directives to export.sh and format.sh"

cat > lib/export.sh <<'SRC'
# shellcheck shell=bash
# export_csv [CURRENCY]: prints the lines in PRICES/QTYS as CSV with a header row.
export_csv() {
  local currency=${1:-EUR} i
  echo "line,qty,unit,currency"
  for ((i = 0; i < ${#PRICES[@]}; i++)); do
    echo "$((i + 1)),${QTYS[$i]},$(format_cents "${PRICES[$i]}"),$currency"
  done
}
SRC
T_EXPORT_CCY=1; write_tests
commit "Add the currency column to the CSV export"

grep -v '^print_receipt' bin/invoicer > bin/invoicer.tmp
printf '%s\n' 'TAX_PERCENT=${TAX:-$TAX_PERCENT}' 'print_receipt "${CURRENCY:-EUR}"' >> bin/invoicer.tmp
mv bin/invoicer.tmp bin/invoicer
chmod +x bin/invoicer
commit "Let bin/invoicer take the tax rate from TAX"

cat >> CHANGELOG.md <<'DOC'
- `bin/invoicer` reads invoice lines from a file or stdin.
- A 15% volume tier from 2000.00.
DOC
commit "Draft 1.3.0 release notes"

printf '1.3.0-rc1\n' > VERSION
commit "Bump VERSION to 1.3.0-rc1"

printf '2500 2\n12050 1\n999 3\n' > examples/order.txt
printf '\nTry it: `bin/invoicer examples/order.txt`\n' >> README.md
commit "Add an example order"
