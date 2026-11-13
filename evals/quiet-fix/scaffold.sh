#!/usr/bin/env bash
# Seeds a git repo with one small, working retry helper to be explained.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

cat > retry.sh <<'SRC'
#!/usr/bin/env bash
# with_retry ATTEMPTS CMD... — run CMD until it succeeds, at most ATTEMPTS times
with_retry() {
  local attempts=$1 delay=1 n=1
  shift
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then
      echo "with_retry: giving up after $n attempts: $*" >&2
      return 1
    fi
    sleep "$delay"
    delay=$((delay * 2))
    n=$((n + 1))
  done
}
SRC

cat > AGENTS.md <<'DOC'
# ops-scripts

Small Bash utility repository for deployment helpers.

## Build & Test

No automated tests.
DOC
printf '@AGENTS.md\n' > CLAUDE.md

chmod +x retry.sh
git add -A
git commit -q -m "Add with_retry helper"
