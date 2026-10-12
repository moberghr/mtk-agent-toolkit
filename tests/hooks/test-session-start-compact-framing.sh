#!/usr/bin/env bash
set -euo pipefail

# Anti-resurrection framing (round 8, option B): post-compaction recovery
# context must be framed as a historical snapshot — reference, not
# instructions — so cancelled/superseded work cannot restart itself after
# compaction. session-start owns this now (it absorbed post-compact.sh): on a
# `compact` SessionStart it appends the recovery block; with no recoverable
# state, or on any other source, there is no recovery block.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/session-start"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"   # Claude Code output format (additionalContext)
COMPACT='{"hook_event_name":"SessionStart","source":"compact","session_id":"s-compact"}'
STARTUP='{"hook_event_name":"SessionStart","source":"startup","session_id":"s-startup"}'

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
export TMPDIR="$WORK/tmp"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
git -C "$WORK" init -q
mkdir -p "$TMPDIR"
cd "$WORK"

# --- 1. no recoverable state → no recovery block ------------------------------

out="$(CLAUDE_PROJECT_DIR="$WORK" bash "$HOOK" <<<"$COMPACT" 2>/dev/null || true)"
case "$out" in *'POST-COMPACTION'*) fail "empty repo must emit no recovery block. Got: $out" ;; esac
printf '  PASS  empty state emits no recovery block\n'

# --- 2. recovered state carries the anti-resurrection framing -------------------

mkdir -p tasks docs/handoffs
printf -- '- [ ] unfinished thing\n' > tasks/todo.md
printf '# handoff\n' > docs/handoffs/2099-session.md

out="$(CLAUDE_PROJECT_DIR="$WORK" bash "$HOOK" <<<"$COMPACT" 2>/dev/null || true)"
case "$out" in *'POST-COMPACTION RECOVERY'*) : ;; *) fail "recoverable state must emit the recovery block on compact. Got: $out" ;; esac
case "$out" in *'HISTORICAL SNAPSHOT'*) : ;; *) fail "framing must declare a historical snapshot. Got: $out" ;; esac
case "$out" in *'latest user message always wins'*) : ;; *) fail "framing must state the latest user message wins. Got: $out" ;; esac
case "$out" in *'do not resume it'*) : ;; *) fail "framing must close cancelled work. Got: $out" ;; esac
case "$out" in *'"additionalContext"'*) : ;; *) fail "must emit the SessionStart additionalContext envelope. Got: $out" ;; esac
printf '  PASS  recovery context framed as reference-only\n'

# --- 3. only on compact: startup with the same state emits no recovery block ----

out="$(CLAUDE_PROJECT_DIR="$WORK" bash "$HOOK" <<<"$STARTUP" 2>/dev/null || true)"
case "$out" in *'POST-COMPACTION'*) fail "startup must not emit the post-compaction block. Got: $out" ;; esac
case "$out" in *'"additionalContext"'*) : ;; *) fail "startup must still emit its SessionStart context. Got: $out" ;; esac
printf '  PASS  recovery block is compact-only\n'

printf '\nAll session-start compact framing checks passed.\n'
