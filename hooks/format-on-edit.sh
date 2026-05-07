#!/usr/bin/env bash
set -euo pipefail

# PostToolUse hook: format the file Claude just edited.
#
# Claude Code passes hook input via stdin JSON (tool_input.file_path).
# There is no $CLAUDE_FILE env var — this wrapper exists so settings.json
# stays simple and so file-extension dispatch happens in shell, not in
# settings.json's matcher field (which only filters by tool name).
#
# Wired from .claude/settings.json:
#   { "matcher": "Edit|Write",
#     "hooks": [{ "type": "command",
#                 "command": "bash $CLAUDE_PLUGIN_ROOT/hooks/format-on-edit.sh" }] }
#
# Per-stack formatter is selected by file extension. Add new stacks by
# extending the case block. Failures are reported on stderr (so they
# surface in Claude Code's hook log) but never block the edit.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

INPUT=$(cat)

FILE_PATH=$(mtk_extract_file_path "$INPUT" 2>/dev/null || true)
[ -z "${FILE_PATH:-}" ] && exit 0
[ -f "$FILE_PATH" ] || exit 0

log_warn() {
  printf 'mtk format-on-edit: %s\n' "$1" >&2
}

run_formatter() {
  local label="$1"; shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_warn "${label} failed for ${FILE_PATH} (exit ${rc})"
    return 1
  fi
  return 0
}

ext="${FILE_PATH##*.}"

case "$ext" in
  ts|tsx|js|jsx|mjs|cjs)
    if command -v npx >/dev/null 2>&1; then
      run_formatter "biome" npx --no-install biome format --write "$FILE_PATH" \
        || run_formatter "prettier" npx --no-install prettier --write --log-level=warn "$FILE_PATH" \
        || true
    fi
    ;;
  py)
    if command -v ruff >/dev/null 2>&1; then
      run_formatter "ruff format" ruff format "$FILE_PATH" || true
      run_formatter "ruff check --fix" ruff check --fix "$FILE_PATH" || true
    elif command -v black >/dev/null 2>&1; then
      run_formatter "black" black --quiet "$FILE_PATH" || true
    fi
    ;;
  cs)
    if command -v dotnet >/dev/null 2>&1; then
      # dotnet format needs the solution/project; run from repo root.
      run_formatter "dotnet format" dotnet format --include "$FILE_PATH" --verbosity quiet || true
    fi
    ;;
  *)
    exit 0
    ;;
esac

exit 0
