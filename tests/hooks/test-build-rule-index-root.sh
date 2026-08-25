#!/usr/bin/env bash
set -euo pipefail

# build-rule-index.sh must write into the PROJECT being bootstrapped, not into
# whatever directory the script itself happens to live in.
#
# WHY. It resolved its root as `dirname $0/..`. Invoked from a plugin cache — the
# only way a bootstrapped repo ever calls it — that regenerates the PLUGIN's own
# index and silently leaves the target repo with no INDEX.md at all. Every rule
# file in the target then loads eagerly on every request, forever, which is the
# exact cost the index exists to remove. CLAUDE.md already states the contract:
# target-repo scripts resolve the project root from $CLAUDE_PROJECT_DIR/git so
# their output lands in the target regardless of where the script lives.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/build-rule-index.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

PROJ="$(mktemp -d)"
trap 'rm -rf "$PROJ"' EXIT
mkdir -p "$PROJ/.claude/rules" "$PROJ/src"
( cd "$PROJ" && git init -q . )
printf 'x\n' > "$PROJ/src/a.txt"
cat > "$PROJ/.claude/rules/security.md" <<'RULE'
---
paths:
  - "src/**"
axes:
  decision: security
  topic: security
  scope: project
---
# Security Rules

## §1.1 — Example
Body.
RULE

# Snapshot the toolkit's own index so a misrooted run is detectable.
before="$(cat "$REPO_ROOT/.claude/rules/INDEX.md" 2>/dev/null || true)"

( cd "$PROJ" && CLAUDE_PROJECT_DIR="$PROJ" bash "$SCRIPT" >/dev/null 2>&1 ) \
  || fail "script exited non-zero in a target project"

[ -f "$PROJ/.claude/rules/INDEX.md" ] \
  || fail "no INDEX.md written into the target project — the script rooted itself somewhere else"
grep -q 'security.md' "$PROJ/.claude/rules/INDEX.md" \
  || fail "target INDEX.md does not list the project's own rule file"

after="$(cat "$REPO_ROOT/.claude/rules/INDEX.md" 2>/dev/null || true)"
[ "$before" = "$after" ] \
  || fail "running against a target project rewrote the TOOLKIT's own INDEX.md"

printf 'PASS: build-rule-index.sh roots on the project, not the script\n'
