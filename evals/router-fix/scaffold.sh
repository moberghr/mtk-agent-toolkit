#!/usr/bin/env bash
# Seeds a git repo with an argument counter that reports one too few, plus its test.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

cat > counter.sh <<'SRC'
#!/usr/bin/env bash
# count_args ARG... — print how many arguments were passed
count_args() {
  local count=0
  for _ in "$@"; do
    count=$((count + 1))
  done
  echo $((count - 1))
}
SRC

cat > test_counter.sh <<'SRC'
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/counter.sh"
fail=0
[ "$(count_args)" = 0 ] || { echo "FAIL no args"; fail=1; }
[ "$(count_args a)" = 1 ] || { echo "FAIL one arg"; fail=1; }
[ "$(count_args a b c)" = 3 ] || { echo "FAIL three args"; fail=1; }
[ "$fail" = 0 ] && echo "all checks passed"
exit "$fail"
SRC

cat > AGENTS.md <<'DOC'
# counter-utils

Small Bash utility repository.

## Build & Test

    bash test_counter.sh
DOC
printf '@AGENTS.md\n' > CLAUDE.md

chmod +x counter.sh test_counter.sh
git add -A
git commit -q -m "Add count_args and its test"
