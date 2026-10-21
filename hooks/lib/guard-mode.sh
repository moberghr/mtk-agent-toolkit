#!/usr/bin/env bash
set -euo pipefail

# Guard-mode helpers (off | advisory | shadow | active). Must be sourced AFTER
# hook-io.sh, which provides mtk_deny, mtk_repo_root, mtk_json_escape,
# mtk_session_file and mtk_emit_additional_context.
# security-gate.sh deliberately does NOT source this file: it calls mtk_deny
# directly, so no MTK_*_ENFORCE value can reach it (S3.18).

# --- Guard modes (off | advisory | shadow | active) -------------------------
# A shadow-capable guard reads its mode from MTK_<NAME>_ENFORCE and passes it
# EXPLICITLY to mtk_deny_gated — there is no env channel into the deny itself,
# so mtk_deny (hook-io.sh) stays the unconditional floor that security-gate and the
# config-guard allow-list protection call directly (S3.18): no MTK_*_ENFORCE
# value can shadow them.
#
# Mode matrix (what mtk_deny_gated does when a guard's check fires):
#   mode      deny (exit 2)?  shadow log line?  text from mtk_deny_gated
#   off       no              no                none
#   advisory  no              no                none
#   shadow    no              yes, one line     none
#   active    yes             no                mtk_deny reason + continuation suffix
# Advisory text is the CALLER's job, never mtk_deny_gated's. Per guard today:
#   scope-guard  (default advisory)  off → silent; advisory and shadow → its own
#                additionalContext warning; active → deny.
#   config-guard config class (default active) and test class (TEST_GUARD,
#                default shadow) emit no advisory text: off and advisory both
#                skip the check; shadow logs; active denies.
#
# Usage:  mode="$(mtk_guard_mode SCOPE_GUARD advisory)"
# Prints one of off|advisory|shadow|active. Values are case-insensitive; an
# unset or empty value prints the default. A non-empty unknown value prints the
# default AND one stderr line naming the variable, so a typo is visible instead
# of silently running the default. Back-compat:
#   - SCOPE_GUARD keeps its pre-mode truthy set (1|true|TRUE|yes|YES|on|ON →
#     active) and its pre-mode falsy set (0|false|FALSE|no|NO → the default,
#     no warning): those were documented values before modes existed.
# (config-guard's kill-switch MTK_CONFIG_GUARD=0 is not a mode: the hook exits
# on it before it reads its mode.)
mtk_guard_mode() { # $1=NAME  $2=default
  local name="${1:-}" def="${2:-advisory}" var raw=""
  case "$def" in off|advisory|shadow|active) ;; *) def="advisory" ;; esac
  case "$name" in
    ''|*[!A-Z0-9_]*) printf '%s\n' "$def"; return 0 ;;
  esac
  var="MTK_${name}_ENFORCE"
  raw="${!var:-}"
  # Bracket classes, not ${raw,,}: macOS ships bash 3.2, which has no case
  # conversion, and a tr fork per hook call buys nothing here.
  case "$raw" in
    [Oo][Ff][Ff]) printf 'off\n'; return 0 ;;
    [Aa][Dd][Vv][Ii][Ss][Oo][Rr][Yy]) printf 'advisory\n'; return 0 ;;
    [Ss][Hh][Aa][Dd][Oo][Ww]) printf 'shadow\n'; return 0 ;;
    [Aa][Cc][Tt][Ii][Vv][Ee]) printf 'active\n'; return 0 ;;
  esac
  if [ "$name" = "SCOPE_GUARD" ]; then
    case "$raw" in
      1|true|TRUE|yes|YES|on|ON) printf 'active\n'; return 0 ;;
      0|false|FALSE|no|NO) printf '%s\n' "$def"; return 0 ;;
    esac
  fi
  if [ -n "$raw" ]; then
    raw="${raw//$'\n'/ }"
    printf '[mtk] %s=%s not recognised; using %s\n' "$var" "${raw:0:80}" "$def" >&2 || true
  fi
  printf '%s\n' "$def"
}

# Mode-gated deny for shadow-capable guards. The mode is an explicit argument.
#   active   → mtk_deny "$reason" "$toggle" (exit 2, unchanged deny ergonomics)
#   shadow   → append one {"ts","hook","code","target"} JSON line to
#              <repo root>/.mtk/metrics/enforcement-shadow.jsonl and return 0
#              with no stdout/stderr (the model sees nothing from this call).
#              `target` is the cksum of the optional 6th argument (the path or
#              command the deny is about) — never the raw text.
#   advisory | off | anything else → return 0; the caller emits any advisory.
# A failed shadow write never breaks the hook: the log is telemetry, not a gate.
# It still returns 0 with no stdout, but prints one stderr line
# `[mtk] shadow log not written: <reason>` so the loss is not silent.
# `code` must be a literal token at every call site: scripts/check-guard-twins.sh
# requires a deny:<code> and an allow:<code> labelled test case for each one.
#
# Usage:  mtk_deny_gated <mode> <hook> <code> <reason> [toggle] [target]
mtk_deny_gated() {
  local mode="${1:-}" hook="${2:-}" code="${3:-}" reason="${4:-}" toggle="${5:-}" target="${6:-}"
  case "$mode" in
    active) mtk_deny "$reason" "$toggle" ;;
    shadow) ;;
    *) return 0 ;;
  esac
  local root ts tsum="" dir
  root="$(mtk_repo_root 2>/dev/null)" || root=""
  if [ -z "$root" ]; then
    _mtk_shadow_not_written "no project root"
    return 0
  fi
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || ts=""
  if [ -n "$target" ]; then
    tsum="$(printf '%s' "$target" | cksum 2>/dev/null | cut -d' ' -f1)" || tsum=""
  fi
  dir="$root/.mtk/metrics"
  if ! { [ -d "$dir" ] || mkdir -p "$dir"; } 2>/dev/null; then
    _mtk_shadow_not_written "cannot create $dir"
    return 0
  fi
  if ! {
    printf '{"ts":"%s","hook":"%s","code":"%s","target":"%s"}\n' \
      "$(mtk_json_escape "$ts")" "$(mtk_json_escape "$hook")" \
      "$(mtk_json_escape "$code")" "$(mtk_json_escape "$tsum")" \
      >>"$dir/enforcement-shadow.jsonl"
  } 2>/dev/null; then
    _mtk_shadow_not_written "cannot append to $dir/enforcement-shadow.jsonl"
  fi
  return 0
}

# One stderr line when a shadow log line is lost. Stderr on exit 0 never reaches
# the model, so this keeps shadow invisible to it while the loss stays visible in
# hook output; a failed write to stderr is ignored. (Not the brace form: a
# group's 2>/dev/null would apply before the inner >&2 and swallow the line.)
_mtk_shadow_not_written() { # $1=reason
  printf '[mtk] shadow log not written: %s\n' "${1:-unknown}" >&2 || true
}

# Advisory emitter for shadow-capable guards: emit <text> as additionalContext
# for <event> at most once per <key> per session, when <mode> is advisory or
# shadow. Callers MUST namespace keys as <hook>:<key> (e.g. scope-guard:<path>,
# push-gate:<change id>): every guard shares one .advised store per session and
# a key matches only as a whole line, so an un-namespaced key could suppress
# another guard's advisory.
#   mode off | active | unknown → nothing emitted, return 1.
#   session id set (_MTK_SESSION_ID) → keys are remembered one per line in
#     "$(mtk_session_file).advised"; a repeat key is suppressed (return 1).
#   no session id → there is no session to scope to: every call emits.
# Returns 0 when it emitted, 1 when it did not. A failed dedup-store write never
# breaks the hook: the text is still emitted, it may just repeat.
#
# Usage:  mtk_advise_gated <mode> <event> <key> <text>
mtk_advise_gated() {
  local mode="${1:-}" event="${2:-}" key="${3:-}" text="${4:-}" store=""
  case "$mode" in
    advisory|shadow) ;;
    *) return 1 ;;
  esac
  if [ -n "${_MTK_SESSION_ID:-}" ]; then
    store="$(mtk_session_file).advised"
    if grep -qxF -- "$key" "$store" 2>/dev/null; then
      return 1
    fi
    # Brace group: a bare `>>"$store" 2>/dev/null` opens the store before the
    # stderr redirect applies, so an open error would leak to stderr.
    { printf '%s\n' "$key" >>"$store"; } 2>/dev/null || true
  fi
  mtk_emit_additional_context "$event" "$text"
  return 0
}
