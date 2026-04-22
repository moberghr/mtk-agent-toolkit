#!/usr/bin/env bash
set -euo pipefail

# SC1: tier-1 correction-nudge fires on correction keywords and stays silent
# on casual prompts and agreement phrasing.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISPATCH="$REPO_ROOT/hooks/userprompt-dispatch.sh"

pass=0
fail=0

assert_fires() {
  local label="$1"
  local prompt="$2"
  local out
  out="$(printf '{"prompt":"%s"}' "$prompt" | MTK_HOOKS_TIER2=1 "$DISPATCH")"
  if printf '%s' "$out" | grep -q 'MTK-NUDGE'; then
    pass=$((pass + 1))
    printf '  PASS  [positive] %s\n' "$label"
  else
    fail=$((fail + 1))
    printf '  FAIL  [positive] %s\n    prompt: %s\n    out: %s\n' "$label" "$prompt" "$out"
  fi
}

assert_silent() {
  local label="$1"
  local prompt="$2"
  local out
  out="$(printf '{"prompt":"%s"}' "$prompt" | MTK_HOOKS_TIER2=1 "$DISPATCH")"
  if [ -z "$out" ] || ! printf '%s' "$out" | grep -q 'MTK-NUDGE'; then
    pass=$((pass + 1))
    printf '  PASS  [negative] %s\n' "$label"
  else
    fail=$((fail + 1))
    printf '  FAIL  [negative] %s\n    prompt: %s\n    out: %s\n' "$label" "$prompt" "$out"
  fi
}

cd "$REPO_ROOT"

# Positives — the regex must catch these
assert_fires "no-not-like-that"         "no, not like that — don't modify the auth layer"
assert_fires "stop-wrong-approach"      "stop — wrong approach"
assert_fires "thats-wrong"              "that's wrong, please revert"
assert_fires "scrap-that"               "scrap that, try again"
assert_fires "thats-not-what"           "actually, that's not what I asked for"

# Negatives — the regex must leave these alone
assert_silent "agreement-with-no"       "No, I think the original approach is correct, so let's keep going"
assert_silent "no-reply-word"           "Can you add no-reply email?"
assert_silent "stop-as-noun"            "the stop command was the bug"
assert_silent "undo-discussion"         "explain how undo works in git"
assert_silent "looks-right"             "no, that still looks right to me"
assert_silent "stop-fine-as-is"         "stop, that's fine as is"

printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
