#!/usr/bin/env bash
set -euo pipefail

# host-load-probe.sh — is this host too loaded to dispatch an implementer subagent?
#
# One-line verdict for `implement` Phase 2.9 (before the first dispatch) and for
# the killed-mid-batch recovery in `subagent-implementation` (before a respawn).
# A 2026-09 field run dispatched implementers onto a host with load ~100: builds
# that take 20 s took 5–15 min, two implementers died at the harness's 10-minute
# no-output watchdog, and the recovery respawned into the same conditions. This
# probe lets both places route to the inline-MAX profile instead.
#
# Usage:
#   bash scripts/host-load-probe.sh [--json] [--max <per-core>] [--load <x> --cores <n>]
#
# Output (stdout, one line):
#   host-load: load1=<1-min avg> cores=<n> per-core=<load/cores> verdict=<ok|overloaded|unknown|skipped> max=<threshold>
# Exit: 0 = ok / unknown / skipped (never block on missing data), 3 = overloaded.
#
# Env:
#   MTK_HOST_LOAD_MAX    per-core 1-minute load above which the host is "overloaded" (default 2.0)
#   MTK_HOST_LOAD_PROBE  0 disables the probe (verdict=skipped, exit 0)
#
# --load/--cores inject values (tests, or replaying a recorded incident). Otherwise:
# macOS `sysctl vm.loadavg` / `hw.ncpu`; Linux /proc/loadavg / nproc; `uptime` fallback.

MAX="${MTK_HOST_LOAD_MAX:-2.0}"
JSON=0; LOAD=""; CORES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --max) MAX="${2:?--max needs a value}"; shift 2 ;;
    --load) LOAD="${2:?--load needs a value}"; shift 2 ;;
    --cores) CORES="${2:?--cores needs a value}"; shift 2 ;;
    -h|--help) sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'host-load-probe: unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done

emit() { # verdict per_core
  local verdict="$1" per_core="$2"
  if [ "$JSON" -eq 1 ]; then
    printf '{"load1":%s,"cores":%s,"per_core":%s,"verdict":"%s","max":%s}\n' \
      "${LOAD:-0}" "${CORES:-0}" "$per_core" "$verdict" "$MAX"
  else
    printf 'host-load: load1=%s cores=%s per-core=%s verdict=%s max=%s\n' \
      "${LOAD:-0}" "${CORES:-0}" "$per_core" "$verdict" "$MAX"
  fi
}

if [ "${MTK_HOST_LOAD_PROBE:-1}" = "0" ]; then
  emit skipped 0; exit 0
fi

# 1-minute load average.
if [ -z "$LOAD" ]; then
  if [ -r /proc/loadavg ]; then
    LOAD="$(awk '{print $1}' /proc/loadavg)"
  elif command -v sysctl >/dev/null 2>&1 && sysctl -n vm.loadavg >/dev/null 2>&1; then
    # "{ 1.23 2.34 3.45 }"
    LOAD="$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1}')"
  elif command -v uptime >/dev/null 2>&1; then
    # "... load averages: 1.23 2.34 3.45" (macOS) / "load average: 1.23, 2.34, 3.45" (Linux)
    LOAD="$(uptime | sed -E 's/.*load averages?:[[:space:]]*//' | awk -F'[ ,]+' '{print $1}')"
  fi
fi
# Logical cores.
if [ -z "$CORES" ]; then
  if command -v nproc >/dev/null 2>&1; then CORES="$(nproc 2>/dev/null || true)"; fi
  [ -n "$CORES" ] || { command -v sysctl >/dev/null 2>&1 && CORES="$(sysctl -n hw.ncpu 2>/dev/null || true)"; }
  [ -n "$CORES" ] || { command -v getconf >/dev/null 2>&1 && CORES="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"; }
fi

# Missing data is never a block: say unknown, exit 0.
case "$LOAD" in ''|*[!0-9.]*) LOAD=""; ;; esac
case "$CORES" in ''|*[!0-9]*|0) CORES=""; ;; esac
if [ -z "$LOAD" ] || [ -z "$CORES" ]; then
  LOAD="${LOAD:-0}"; CORES="${CORES:-0}"
  emit unknown 0; exit 0
fi

PER_CORE="$(awk -v l="$LOAD" -v c="$CORES" 'BEGIN { printf "%.1f", l / c }')"
if awk -v p="$PER_CORE" -v m="$MAX" 'BEGIN { exit !(p > m) }'; then
  emit overloaded "$PER_CORE"; exit 3
fi
emit ok "$PER_CORE"; exit 0
