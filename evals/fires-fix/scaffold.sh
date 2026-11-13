#!/usr/bin/env bash
# Seeds a git repo with a cart total helper that prints nothing for an empty cart, plus its test.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

cat > cart.sh <<'SRC'
#!/usr/bin/env bash
# cart_total PRICE... — print the sum of the item prices, in cents
cart_total() {
  [ $# -gt 0 ] || return 1
  local total=0
  for price in "$@"; do
    total=$((total + price))
  done
  echo "$total"
}
SRC

cat > test_cart.sh <<'SRC'
#!/usr/bin/env bash
. "$(dirname "$0")/cart.sh"
fail=0
[ "$(cart_total)" = 0 ] || { echo "FAIL empty cart"; fail=1; }
[ "$(cart_total 250)" = 250 ] || { echo "FAIL one item"; fail=1; }
[ "$(cart_total 100 250 5)" = 355 ] || { echo "FAIL three items"; fail=1; }
[ "$fail" = 0 ] && echo "all checks passed"
exit "$fail"
SRC

cat > AGENTS.md <<'DOC'
# shop-utils

Small Bash utility repository for the shop scripts.

## Build & Test

    bash test_cart.sh
DOC
printf '@AGENTS.md\n' > CLAUDE.md

chmod +x cart.sh test_cart.sh
git add -A
git commit -q -m "Add cart_total and its test"
