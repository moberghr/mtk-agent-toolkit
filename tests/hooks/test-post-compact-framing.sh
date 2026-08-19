#!/usr/bin/env bash
set -euo pipefail

# Anti-resurrection framing (round 8, option B): post-compaction recovery
# context must be framed as a historical snapshot — reference, not
# instructions — so cancelled/superseded work cannot restart itself after
# compaction. Empty state stays silent.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/post-compact.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
git -C "$WORK" init -q
cd "$WORK"

# --- 1. no recoverable state → no output ---------------------------------------

out="$(CLAUDE_PROJECT_DIR="$WORK" bash "$HOOK" </dev/null 2>/dev/null || true)"
[ -z "$out" ] || fail "empty repo must emit nothing. Got: $out"
printf '  PASS  empty state stays silent\n'

# --- 2. recovered state carries the anti-resurrection framing -------------------

mkdir -p tasks docs/handoffs
printf -- '- [ ] unfinished thing\n' > tasks/todo.md
printf '# handoff\n' > docs/handoffs/2099-session.md

out="$(CLAUDE_PROJECT_DIR="$WORK" bash "$HOOK" </dev/null 2>/dev/null || true)"
[ -n "$out" ] || fail "recoverable state must emit recovery context"
case "$out" in *'HISTORICAL SNAPSHOT'*) : ;; *) fail "framing must declare a historical snapshot. Got: $out" ;; esac
case "$out" in *'latest user message always wins'*) : ;; *) fail "framing must state the latest user message wins. Got: $out" ;; esac
case "$out" in *'do not resume it'*) : ;; *) fail "framing must close cancelled work. Got: $out" ;; esac
case "$out" in *'"additionalContext"'*) : ;; *) fail "must emit the SessionStart additionalContext envelope. Got: $out" ;; esac
printf '  PASS  recovery context framed as reference-only\n'

printf '\nAll post-compact framing checks passed.\n'
