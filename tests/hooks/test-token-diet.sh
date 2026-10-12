#!/usr/bin/env bash
set -euo pipefail

# Token diet (round 8, option C): the repetition-dominance collapse in
# scripts/mtk-compress.sh. (The opt-in read-guard re-read diet this file also
# covered was removed with hooks/read-guard.sh in the runtime diet.)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPRESS="$REPO_ROOT/scripts/mtk-compress.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# --- repetition-dominance collapse in mtk-compress -----------------------------

cd "$REPO_ROOT"
REPEAT_INPUT="$(python3 -c "print('header: starting run'); [print('  at Object.<anonymous> (/app/dist/worker.js:114:7)') for _ in range(200)]; print('tail: 1 failed')")"
out="$(printf '%s' "$REPEAT_INPUT" | MTK_COMPRESS_MIN_CHARS=100 bash "$COMPRESS" logs)"
case "$out" in *'repeated 200x — collapsed'*) : ;; *) fail "dominant repeated line must collapse with a count. Got: $(printf '%s' "$out" | head -5)" ;; esac
[ "$(printf '%s' "$out" | grep -c 'worker.js:114')" -eq 1 ] \
  || fail "collapsed line must appear exactly once"
case "$out" in *'tail: 1 failed'*) : ;; *) fail "non-dominant lines must survive the collapse" ;; esac
printf '  PASS  repetition-dominated output collapses to one instance + count\n'

VARIED_INPUT="$(python3 -c "[print(f'line {i} unique content padding padding padding') for i in range(60)]")"
out="$(printf '%s' "$VARIED_INPUT" | MTK_COMPRESS_MIN_CHARS=100 bash "$COMPRESS" logs)"
case "$out" in *'collapsed'*) fail "varied output must not trip the collapse" ;; *) : ;; esac
printf '  PASS  varied output untouched by the collapse\n'

printf '\nAll token-diet checks passed.\n'
