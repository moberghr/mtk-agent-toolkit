#!/usr/bin/env bash
set -euo pipefail

# verify-commands.sh — runs a list of named shell commands (the build/test/
# format commands setup-bootstrap STEP 3.5a is about to publish in CLAUDE.md,
# sourced from tech-stack skills, never from repo content) and reports
# verified/failed/skipped per command as JSON (F7). Read-only over the repo:
# it never writes anything itself — it only executes the commands it's given,
# from the current working directory, and reports what happened.
#
# Usage:
#   <name>\t<command> lines on stdin, e.g.:
#     printf 'build\tdotnet build\ntest\tdotnet test --list-tests\n' | \
#       bash scripts/verify-commands.sh
#
#   Or read the same name<TAB>command lines from a file instead of stdin:
#     bash scripts/verify-commands.sh --file commands.tsv
#
#   Per-command timeout in seconds (default 300):
#     bash scripts/verify-commands.sh --timeout 60
#
# Line format: "name<TAB>command". A line whose command half is empty (no tab
# at all, or a tab with nothing after it) is reported `skipped`.
#
# Output (always JSON on stdout):
#   {"results": [{"name": "...", "command": "...",
#                 "status": "verified|failed|skipped", "detail": "..."}]}
#
# detail:
#   ""                            — verified
#   "exit <code>[: <first line>]" — failed (non-zero exit; first non-blank
#                                    line of stderr, else stdout, if any)
#   "timeout after <N>s"          — failed (killed by the timeout wrapper;
#                                    detected via the `timeout` binary's
#                                    standard exit code 124 — a command that
#                                    legitimately exits 124 on its own would
#                                    be misreported as a timeout, an accepted
#                                    tradeoff of this detection)
#   Whenever no `timeout`/`gtimeout` binary is available (S3.3 graceful
#   degradation), the command still runs — just without an enforced
#   wall-clock limit — and "(no timeout binary — ran unbounded)" is appended
#   to whatever detail was otherwise computed.
#
# Exit codes:
#   0 — always (individual command failures are reported in the JSON body;
#       this script's own exit code reflects only its own execution)
#   2 — usage error (unknown flag, missing --file target, non-numeric
#       --timeout)
#
# Spec: docs/specs/2026-07-03-v719-setup-improvements.md (F7)

usage() {
  awk '/^# /{f=1} f{ if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

TIMEOUT=300
INPUT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout)
      shift
      if [ $# -eq 0 ]; then
        echo "ERROR: verify-commands: --timeout requires a value" >&2
        exit 2
      fi
      case "$1" in
        ''|*[!0-9]*)
          echo "ERROR: verify-commands: --timeout value must be a non-negative integer: $1" >&2
          exit 2
          ;;
      esac
      TIMEOUT="$1"
      shift
      ;;
    --file)
      shift
      if [ $# -eq 0 ]; then
        echo "ERROR: verify-commands: --file requires a path" >&2
        exit 2
      fi
      INPUT_FILE="$1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: verify-commands: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -n "$INPUT_FILE" ] && [ ! -f "$INPUT_FILE" ]; then
  echo "ERROR: verify-commands: --file not found: $INPUT_FILE" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: verify-commands: python3 is required" >&2
  exit 2
fi

# Portable timeout probe (S3.3 graceful degradation): prefer the GNU-style
# `timeout` binary; some macOS setups only expose it as `gtimeout` (coreutils
# installed via Homebrew without the unprefixed shims). If neither exists,
# every command below just runs unbounded and gets a note in its detail.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

TMP_DIR="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked indirectly via `trap ... EXIT` below
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

RESULTS_FILE="$TMP_DIR/results.tsv"
: > "$RESULTS_FILE"

# Append one result row. Tabs/newlines are flattened to spaces since
# results.tsv is tab-delimited and consumed line-by-line by the JSON builder.
add_result() {
  local name="$1" command="$2" status="$3" detail="$4"
  name="${name//$'\t'/ }"; name="${name//$'\n'/ }"
  command="${command//$'\t'/ }"; command="${command//$'\n'/ }"
  detail="${detail//$'\t'/ }"; detail="${detail//$'\n'/ }"
  printf '%s\t%s\t%s\t%s\n' "$name" "$command" "$status" "$detail" >> "$RESULTS_FILE"
}

run_command() {
  local name="$1" command="$2"

  if [ -z "$command" ]; then
    add_result "$name" "$command" "skipped" ""
    return
  fi

  local outf errf rc degraded=0
  outf="$(mktemp "$TMP_DIR/out.XXXXXX")"
  errf="$(mktemp "$TMP_DIR/err.XXXXXX")"

  rc=0
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$TIMEOUT" bash -o pipefail -c "$command" >"$outf" 2>"$errf" </dev/null || rc=$?
  else
    degraded=1
    bash -o pipefail -c "$command" >"$outf" 2>"$errf" </dev/null || rc=$?
  fi

  local status="verified" detail=""
  if [ -n "$TIMEOUT_BIN" ] && [ "$rc" -eq 124 ]; then
    status="failed"
    detail="timeout after ${TIMEOUT}s"
  elif [ "$rc" -ne 0 ]; then
    status="failed"
    local first_line=""
    first_line="$(grep -m1 -v '^[[:space:]]*$' "$errf" 2>/dev/null || true)"
    if [ -z "$first_line" ]; then
      first_line="$(grep -m1 -v '^[[:space:]]*$' "$outf" 2>/dev/null || true)"
    fi
    if [ -n "$first_line" ]; then
      detail="exit ${rc}: ${first_line}"
    else
      detail="exit ${rc}"
    fi
  fi

  if [ "$degraded" -eq 1 ]; then
    if [ -z "$detail" ]; then
      detail="(no timeout binary — ran unbounded)"
    else
      detail="${detail} (no timeout binary — ran unbounded)"
    fi
  fi

  add_result "$name" "$command" "$status" "$detail"
}

if [ -n "$INPUT_FILE" ]; then
  LOOP_SRC="$INPUT_FILE"
else
  # Copy stdin to a temp file first so the read loop below never competes
  # with a verified command that also happens to read from fd 0.
  LOOP_SRC="$TMP_DIR/stdin.tsv"
  cat > "$LOOP_SRC"
fi

while IFS=$'\t' read -r name command || [ -n "${name:-}" ]; do
  [ -z "${name:-}" ] && continue
  run_command "$name" "$command"
done < "$LOOP_SRC"

python3 - "$RESULTS_FILE" <<'PY'
import json
import sys

path = sys.argv[1]
results = []
with open(path, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t", 3)
        while len(parts) < 4:
            parts.append("")
        name, command, status, detail = parts
        results.append({"name": name, "command": command, "status": status, "detail": detail})

print(json.dumps({"results": results}, indent=2))
PY
