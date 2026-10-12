#!/usr/bin/env bash
# Seeds a git repo with a summing function that has an off-by-one loop bound,
# plus a test script that fails until the bound is fixed.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

cat > sum.sh <<'SRC'
#!/usr/bin/env bash
# sum_to N — print 1 + 2 + ... + N
sum_to() {
  local n=$1 total=0 i
  for ((i = 1; i < n; i++)); do
    total=$((total + i))
  done
  echo "$total"
}
SRC

cat > test_sum.sh <<'SRC'
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/sum.sh"
fail=0
check() {
  local got
  got=$(sum_to "$1")
  if [ "$got" = "$2" ]; then
    echo "ok   sum_to $1 = $got"
  else
    echo "FAIL sum_to $1: expected $2, got $got"
    fail=1
  fi
}
check 1 1
check 4 10
check 10 55
exit "$fail"
SRC

cat > AGENTS.md <<'DOC'
# sum-utils

Small Bash utility repository.

## Build & Test

    bash test_sum.sh
DOC
printf '@AGENTS.md\n' > CLAUDE.md

chmod +x sum.sh test_sum.sh
git add -A
git commit -q -m "Add sum_to and its test"
