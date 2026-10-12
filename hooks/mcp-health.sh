#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# mcp-health.sh — records failing MCP tool calls per server (PostToolUseFailure)
# with exponential backoff, advises (or denies) PreToolUse calls to a server in
# backoff, and clears the record on PostToolUse success. Matcher: mcp__.*
#
# Branch is chosen from the payload's `hook_event_name` field — never from an
# env var (that would make the branch spoofable and untestable outside a real
# hook dispatch).
#
# Server name: the second `__`-delimited segment of `tool_name`
# (mcp__<server>__<tool>), validated against ^[A-Za-z0-9_-]{1,64}$. Anything
# else (non-mcp__ tool, malformed server) is ignored — exit 0.
#
# Error classification (PostToolUseFailure only) reads the payload's `error`
# string field, falling back to `tool_response` when `error` is absent. Only
# the listed classes record a failure; anything else (e.g. a validation error)
# records nothing, because a tool-level error is not a server-health problem:
#   auth        401, unauthorized, auth failed, token expired
#   forbidden   403
#   rate-limit  429, rate limit
#   unavailable 503, unavailable, overloaded
#   transport   ECONNREFUSED, ENOTFOUND, ETIMEDOUT, (request) timed out,
#               socket hang up, connection closed, not connected
# Status codes match as whole numbers only (not inside 4031 or 14290), and
# there is no bare "timeout" pattern — both hit ordinary validation errors.
#
# Backoff: next_retry = now + min(base * 2^(failures-1), max), base/max from
# MTK_MCP_HEALTH_BACKOFF_BASE_SECS (30) / MTK_MCP_HEALTH_BACKOFF_MAX_SECS (600).
# Doubling stops once the cap is reached (no int64 overflow); a base/max that
# is not 1-9 plain digits falls back to its default; the stored failure count
# is capped at 1000.
#
# State: $TMPDIR/mtk-mcp-health-<cksum(repo root)>, tab-separated
# `server<TAB>failures<TAB>next_retry<TAB>code<TAB>ts`, one line per server.
# Rewritten whole-file via tmp+mv on every update — never appended in place.
# Every read-modify-write (failure record, success clear) runs under a mkdir
# lock "$STATE_FILE.lock" (no flock on macOS / bash 3.2): up to 100 tries 20ms
# apart, a lock older than 2s is treated as a corpse and stolen, and if the lock
# still cannot be taken the update proceeds UNLOCKED — a lost record is better
# than blocking the tool call. Only a lock this process took is ever released.
# Without it, parallel failures for different servers overwrite each other's
# tmp+mv and all but a few records vanish.
# Only the classification label is stored (never the raw error text), so no
# sanitization of stored text is needed; if a future change stores raw error
# text it must be sanitized first (tabs/newlines stripped, capped ~200 chars)
# to keep the tab-separated format intact.
#
# No probing, no reconnect, no spawning anything — this hook only reads and
# writes its own state file (S3.3: spawning arbitrary MCP commands from a hook
# is out of scope and unsafe).
#
# Fails open on an empty or unparseable payload, and on a payload missing
# `hook_event_name` — this is a drift/advisory guard, not a security gate.
#
# Test seam: MTK_MCP_HEALTH_NOW overrides "now" (epoch seconds) so tests can
# simulate elapsed time deterministically. Test-only — never set in production.
#
# Kill-switch: MTK_MCP_HEALTH=0. Enforce (deny instead of advise, during
# backoff only): MTK_MCP_HEALTH_ENFORCE=1.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

mtk_is_redundant_plugin_invocation "$0" && exit 0

[ "${MTK_MCP_HEALTH:-1}" = "0" ] && exit 0

# Bounded read (see hook-io.sh mtk_read_payload for why). Empty/unparseable
# payload is handled below by the hook_event_name check — fail open.
INPUT=$(mtk_read_payload)

HOOK_EVENT=$(mtk_extract_json_string "$INPUT" "hook_event_name" 2>/dev/null || echo "")
[ -n "$HOOK_EVENT" ] || exit 0

TOOL_NAME=$(mtk_extract_tool_name "$INPUT" 2>/dev/null || echo "")

# Only mcp__<server>__<tool> tool names are in scope.
case "$TOOL_NAME" in
  mcp__*__*) : ;;
  *) exit 0 ;;
esac

MTK_MCP_REST="${TOOL_NAME#mcp__}"
MTK_MCP_SERVER="${MTK_MCP_REST%%__*}"

# Validate server name: ^[A-Za-z0-9_-]{1,64}$, no external regex tool needed.
if [ -z "$MTK_MCP_SERVER" ] || [ "${#MTK_MCP_SERVER}" -gt 64 ]; then
  exit 0
fi
case "$MTK_MCP_SERVER" in
  *[!A-Za-z0-9_-]*) exit 0 ;;
esac

STATE_TMPDIR="${TMPDIR:-/tmp}"
STATE_FILE="${STATE_TMPDIR}/mtk-mcp-health-$(mtk_repo_root | cksum | cut -d' ' -f1)"

NOW="${MTK_MCP_HEALTH_NOW:-$(date +%s)}"

# --- state helpers -----------------------------------------------------------

# mkdir lock around the state file's read-modify-write. Mirrors hook-io.sh
# mtk_session_lock_acquire's corpse-steal semantics, but reports failure (so an
# unlocked update never releases a lock another process holds) and spins 20ms.
MTK_MCP_LOCK="${STATE_FILE}.lock"
MTK_MCP_LOCKED=0
mtk_mcp_lock() {
  local tries=0 mtime now
  while ! mkdir "$MTK_MCP_LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || return 1
    mtime=$(stat -c '%Y' "$MTK_MCP_LOCK" 2>/dev/null || stat -f '%m' "$MTK_MCP_LOCK" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [ "$mtime" -gt 0 ] && [ "$((now - mtime))" -ge 2 ]; then
      rmdir "$MTK_MCP_LOCK" 2>/dev/null || true
      continue
    fi
    sleep 0.02 2>/dev/null || sleep 1
  done
  MTK_MCP_LOCKED=1
}
mtk_mcp_unlock() {
  if [ "$MTK_MCP_LOCKED" = "1" ]; then
    rmdir "$MTK_MCP_LOCK" 2>/dev/null || true
    MTK_MCP_LOCKED=0
  fi
  return 0
}
# Release on every exit path (an errexit mid-update included), then run the
# diagnostic trap with the original exit status.
_mtk_mcp_exit() { local c=$?; mtk_mcp_unlock; (exit "$c"); _mtk_hook_diag; }
trap _mtk_mcp_exit EXIT

# Prints the tab-separated record for $1 (server) if present; returns 1 if not
# found. Reads the file directly (no pipe), so no SIGPIPE/early-exit concern.
mtk_mcp_get_record() {
  local server="$1"
  [ -f "$STATE_FILE" ] || return 1
  awk -F'\t' -v s="$server" '$1==s{print; found=1} END{exit !found}' "$STATE_FILE"
}

# Rewrites the whole file, replacing (or adding) $1's record. tmp+mv, per
# batch notes.
mtk_mcp_set_record() {
  local server="$1" failures="$2" next_retry="$3" code="$4" ts="$5"
  local tmp="${STATE_FILE}.tmp.$$"
  {
    if [ -f "$STATE_FILE" ]; then
      awk -F'\t' -v s="$server" '$1!=s' "$STATE_FILE"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$server" "$failures" "$next_retry" "$code" "$ts"
  } > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

# Rewrites the whole file, dropping $1's record if present.
mtk_mcp_delete_record() {
  local server="$1"
  [ -f "$STATE_FILE" ] || return 0
  local tmp="${STATE_FILE}.tmp.$$"
  awk -F'\t' -v s="$server" '$1!=s' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

# Classifies $1 (error/tool_response text) into one of the five codes above,
# or prints nothing. Herestrings, not `producer | grep -q`, per S3.17.
mtk_mcp_classify_error() {
  local text="${1:-}"
  [ -n "$text" ] || return 0
  if grep -qEi '(^|[^0-9])401([^0-9]|$)|unauthorized|auth failed|token expired' <<<"$text"; then
    printf 'auth'; return 0
  fi
  if grep -qEi '(^|[^0-9])403([^0-9]|$)' <<<"$text"; then
    printf 'forbidden'; return 0
  fi
  if grep -qEi '(^|[^0-9])429([^0-9]|$)|rate limit' <<<"$text"; then
    printf 'rate-limit'; return 0
  fi
  if grep -qEi '(^|[^0-9])503([^0-9]|$)|unavailable|overloaded' <<<"$text"; then
    printf 'unavailable'; return 0
  fi
  if grep -qEi 'ECONNREFUSED|ENOTFOUND|ETIMEDOUT|request timed out|timed out|socket hang up|connection closed|not connected' <<<"$text"; then
    printf 'transport'; return 0
  fi
  return 0
}

# --- dispatch ------------------------------------------------------------

case "$HOOK_EVENT" in

  PostToolUseFailure)
    MTK_MCP_ERR=$(mtk_extract_json_string "$INPUT" "error" 2>/dev/null || echo "")
    if [ -z "$MTK_MCP_ERR" ]; then
      MTK_MCP_ERR=$(mtk_extract_json_string "$INPUT" "tool_response" 2>/dev/null || echo "")
    fi
    MTK_MCP_CODE=$(mtk_mcp_classify_error "$MTK_MCP_ERR")
    [ -n "$MTK_MCP_CODE" ] || exit 0

    mtk_mcp_lock || true  # unlocked fallback: never block the tool call
    MTK_MCP_OLD_FAILURES=0
    if MTK_MCP_REC=$(mtk_mcp_get_record "$MTK_MCP_SERVER"); then
      IFS=$'\t' read -r _ MTK_MCP_OLD_FAILURES _ _ _ <<<"$MTK_MCP_REC"
    fi
    # Stored count: digits only; anything longer than 4 digits is already past
    # the cap. 10# so a leading zero is never read as octal.
    case "${MTK_MCP_OLD_FAILURES:-}" in
      ''|*[!0-9]*) MTK_MCP_OLD_FAILURES=0 ;;
      ?????*) MTK_MCP_OLD_FAILURES=1000 ;;
      *) MTK_MCP_OLD_FAILURES=$((10#$MTK_MCP_OLD_FAILURES)) ;;
    esac
    MTK_MCP_FAILURES=$((MTK_MCP_OLD_FAILURES + 1))
    [ "$MTK_MCP_FAILURES" -le 1000 ] || MTK_MCP_FAILURES=1000

    # Env knobs: 1-9 plain digits (10# arithmetic), else the default — a typo
    # must never crash the hook or overflow the multiply below.
    mtk_mcp_secs() { # $1 value  $2 default
      case "${1:-}" in
        ''|*[!0-9]*|??????????*) printf '%s' "$2" ;;
        *) printf '%s' "$((10#$1))" ;;
      esac
    }
    MTK_MCP_BASE="$(mtk_mcp_secs "${MTK_MCP_HEALTH_BACKOFF_BASE_SECS:-}" 30)"
    MTK_MCP_MAX="$(mtk_mcp_secs "${MTK_MCP_HEALTH_BACKOFF_MAX_SECS:-}" 600)"
    MTK_MCP_POW=1
    MTK_MCP_N=1
    # Stop doubling once base*pow reaches the cap (bounded: base, max < 1e9, so
    # the product stays < 2e18); the 62-step bound covers base=0.
    while [ "$MTK_MCP_N" -lt "$MTK_MCP_FAILURES" ] && [ "$MTK_MCP_N" -lt 62 ] \
      && [ $((MTK_MCP_BASE * MTK_MCP_POW)) -lt "$MTK_MCP_MAX" ]; do
      MTK_MCP_POW=$((MTK_MCP_POW * 2))
      MTK_MCP_N=$((MTK_MCP_N + 1))
    done
    MTK_MCP_BACKOFF=$((MTK_MCP_BASE * MTK_MCP_POW))
    if [ "$MTK_MCP_BACKOFF" -gt "$MTK_MCP_MAX" ]; then
      MTK_MCP_BACKOFF=$MTK_MCP_MAX
    fi
    MTK_MCP_NEXT_RETRY=$((NOW + MTK_MCP_BACKOFF))

    mtk_mcp_set_record "$MTK_MCP_SERVER" "$MTK_MCP_FAILURES" "$MTK_MCP_NEXT_RETRY" "$MTK_MCP_CODE" "$NOW"
    mtk_mcp_unlock
    exit 0
    ;;

  PostToolUse)
    # No state file -> nothing to clear, and no lock to pay for.
    [ -f "$STATE_FILE" ] || exit 0
    mtk_mcp_lock || true
    mtk_mcp_delete_record "$MTK_MCP_SERVER"
    mtk_mcp_unlock
    exit 0
    ;;

  PreToolUse)
    if ! MTK_MCP_REC=$(mtk_mcp_get_record "$MTK_MCP_SERVER"); then
      exit 0
    fi
    IFS=$'\t' read -r _ MTK_MCP_FAILURES MTK_MCP_NEXT_RETRY MTK_MCP_CODE _ <<<"$MTK_MCP_REC"
    case "${MTK_MCP_NEXT_RETRY:-}" in
      ''|*[!0-9]*) exit 0 ;;
    esac
    if [ "$NOW" -lt "$MTK_MCP_NEXT_RETRY" ]; then
      MTK_MCP_SECS_LEFT=$((MTK_MCP_NEXT_RETRY - NOW))
      MTK_MCP_MSG="MCP-HEALTH: server '${MTK_MCP_SERVER}' is in backoff after ${MTK_MCP_FAILURES} failure(s) (${MTK_MCP_CODE}). retry in ${MTK_MCP_SECS_LEFT}s. Prefer non-MCP fallbacks (Bash/scripts) meanwhile."
      if [ "${MTK_MCP_HEALTH_ENFORCE:-0}" = "1" ]; then
        mtk_deny "$MTK_MCP_MSG" 'MTK_MCP_HEALTH_ENFORCE=0 (or MTK_MCP_HEALTH=0)'
      fi
      mtk_emit_additional_context "PreToolUse" "$MTK_MCP_MSG"
      exit 0
    fi
    # Backoff has expired: allow silently, as a probe.
    exit 0
    ;;

  *)
    exit 0
    ;;
esac
