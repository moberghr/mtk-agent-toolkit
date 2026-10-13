#!/usr/bin/env bash
# Seeds a git repo with a tiny line-counting CLI and its test.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

cat > tool.sh <<'SRC'
#!/usr/bin/env bash
# tool.sh — count the lines in a file
set -euo pipefail

usage() { echo "usage: tool.sh [-h] <file>"; }

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") usage >&2; exit 2 ;;
  esac
  wc -l < "$1" | tr -d ' '
}

main "$@"
SRC

cat > test_tool.sh <<'SRC'
#!/usr/bin/env bash
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp)
printf 'a\nb\nc\n' > "$tmp"
fail=0
[ "$("$here/tool.sh" "$tmp")" = 3 ] || { echo "FAIL count"; fail=1; }
"$here/tool.sh" >/dev/null 2>&1; [ $? = 2 ] || { echo "FAIL usage exit"; fail=1; }
rm -f "$tmp"
[ "$fail" = 0 ] && echo "all checks passed"
exit "$fail"
SRC

cat > AGENTS.md <<'DOC'
# line-tool

Small Bash CLI that counts lines in a file.

## Build & Test

    bash test_tool.sh
DOC
printf '@AGENTS.md\n' > CLAUDE.md

chmod +x tool.sh test_tool.sh
git add -A
git commit -q -m "Add tool.sh and its test"
