#!/usr/bin/env bash
set -euo pipefail

# mtk-verify-run.sh — the verification evidence contract, as one command.
#
# Runs a verification command with its FULL output redirected to a persisted,
# citable log file; only the exit code and a bounded tail enter the agent's
# context. Removes the double burn (inline output + banner re-quote) without
# dropping evidence: the log path is printed for citation in the completion
# report, so evidence stays audit-reachable after the session ends.
#
# Contract (see .claude/references/verification-evidence-contract.md):
#   exit=N                                          <- machine-readable outcome
#   --- tail -K of '<cmd>' (full output: <path>) ---
#   <last K lines>
#
# Differences from `cmd | mtk-compress.sh`:
#   - the command's exit code is PRESERVED (a pipe reports the compressor's);
#   - the full output is persisted on disk, not lossily elided in flight;
#   - the `exit=N` line is an authoritative signal for the session ledger's
#     outcome column (mtk_classify_verification_outcome).
#
# Usage:
#   bash scripts/mtk-verify-run.sh [--tail N] [--label name] -- <cmd> [args...]
#   bash scripts/mtk-verify-run.sh [--tail N] [--label name] "<command string>"
#
# Env:
#   MTK_VERIFY_TAIL        tail line count (default 30, same bound as
#                          MTK_COMPRESS_MAX_LOG_LINES)
#   MTK_VERIFY_ERROR_HITS  max error-keyword hit lines shown on failure
#                          (default 8; hits carry log line numbers)

TAIL_LINES="${MTK_VERIFY_TAIL:-30}"
LABEL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --tail)  TAIL_LINES="${2:?--tail needs a value}"; shift 2 ;;
    --label) LABEL="${2:?--label needs a value}"; shift 2 ;;
    --) shift; break ;;
    -*) echo "mtk-verify-run: unknown option $1" >&2; exit 64 ;;
    *) break ;;
  esac
done

[ $# -gt 0 ] || { echo "mtk-verify-run: no command given" >&2; exit 64; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
EVIDENCE_DIR="$REPO_ROOT/.mtk/evidence"
mkdir -p "$EVIDENCE_DIR"

# Human-readable command line for the citation header.
if [ $# -eq 1 ]; then
  CMD_DISPLAY="$1"
else
  CMD_DISPLAY="$*"
fi

# Slug for the log filename: label wins, else first word of the command.
slug_source="${LABEL:-${CMD_DISPLAY%% *}}"
slug="$(printf '%s' "$slug_source" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-40)"
LOG_FILE="$EVIDENCE_DIR/$(date -u +%Y%m%d-%H%M%S)-${slug}-$$.log"

# Run the command with full output to disk. A single argument is a command
# string (bash -c); multiple arguments run verbatim. The command's failure
# must not abort this wrapper before it reports — disable -e around it.
rc=0
set +e
if [ $# -eq 1 ]; then
  bash -c "$1" > "$LOG_FILE" 2>&1
else
  "$@" > "$LOG_FILE" 2>&1
fi
rc=$?
set -e

# Citable path: repo-relative when the log is under the repo root.
CITE_PATH="$LOG_FILE"
case "$LOG_FILE" in
  "$REPO_ROOT"/*) CITE_PATH="${LOG_FILE#"$REPO_ROOT"/}" ;;
esac

total_lines="$(wc -l < "$LOG_FILE" | tr -d ' ')"
printf 'exit=%s\n' "$rc"

# On failure, the first diagnostic often sits far ABOVE the tail (a long build
# scrolls past its first error). Emit a deterministic error slice: the first
# keyword hits with their line numbers, so the reader can widen from the
# persisted log by coordinate instead of guessing. Lines are raw log content,
# never rewritten — only selected (capped per line for context economy).
if [ "$rc" -ne 0 ]; then
  hits="$(grep -niE 'error|fatal|panic|traceback|failed|denied|exception|assert' "$LOG_FILE" 2>/dev/null \
    | head -n "${MTK_VERIFY_ERROR_HITS:-8}" | cut -c1-200 || true)"
  if [ -n "$hits" ]; then
    printf -- '--- first error hits (line numbers refer to %s) ---\n' "$CITE_PATH"
    printf '%s\n' "$hits"
  fi
fi

printf -- '--- tail -%s of %s (%s lines total, full output: %s) ---\n' \
  "$TAIL_LINES" "'$CMD_DISPLAY'" "$total_lines" "$CITE_PATH"
tail -n "$TAIL_LINES" "$LOG_FILE"

exit "$rc"
