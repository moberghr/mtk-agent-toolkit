#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# PreToolUse security gate for Bash commands.
# Receives JSON on stdin with tool_name, tool_input, etc.
# Exit 0 = allow, exit 2 = block.
#
# The deny list in settings.json handles exact pattern matches.
# This script catches nuanced destructive patterns that deny rules miss:
# - Force pushes with alternate syntax (--force-with-lease to protected branches)
# - Destructive operations disguised with flags or pipes
# - Database drop/truncate commands

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

mtk_is_redundant_plugin_invocation "$0" && exit 0

INPUT="$(mtk_read_payload)"

TOOL_NAME=$(mtk_extract_tool_name "$INPUT" 2>/dev/null || echo "")
COMMAND=$(mtk_extract_command "$INPUT" 2>/dev/null || echo "")

# If this is not a Bash payload, ignore it.
if [ -n "$TOOL_NAME" ] && [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

# Fail closed for Bash payloads we cannot parse.
if [ -z "$COMMAND" ]; then
  mtk_deny "BLOCKED: Unable to parse Bash command from hook payload. Re-run the command after fixing the hook payload shape."
fi

# Reduce a command to the parts that could actually EXECUTE something.
#
# A search or print command MENTIONS text, it does not run it: `grep -rn '<delete>'`
# and `echo "never run <delete>"` are safe, and denying them is expensive — a
# PreToolUse deny forces the model to re-plan and re-issue, costing a whole extra
# turn. Split on the shell's own separators and drop segments whose command word is
# a read-only tool; everything else is judged exactly as before.
#
# A segment containing a command substitution is NEVER exempt: `grep "$(<delete>)"`
# reads as a grep but runs the inner command. Splitting on `|` can also cut a quoted
# regex in half — that only ever produces extra fragments to judge, never fewer.
mtk_executable_text() {
  # `|| [ -n "$_mtk_seg" ]`: the input has no trailing newline, so the final (often
  # only) segment leaves `read` at EOF with a non-zero status. Without this the loop
  # body never runs and the function returns nothing — which reads as "no executable
  # text", i.e. the gate silently allows everything.
  printf '%s' "${1-}" | tr ';|&' '\n\n\n' | while IFS= read -r _mtk_seg || [ -n "$_mtk_seg" ]; do
    case "$_mtk_seg" in
      *'$('*|*'`'*) printf '%s\n' "$_mtk_seg"; continue ;;
    esac
    # First word, skipping any leading VAR=value assignments.
    _mtk_rest="${_mtk_seg#"${_mtk_seg%%[![:space:]]*}"}"
    _mtk_word="${_mtk_rest%%[[:space:]]*}"
    while [ -n "$_mtk_word" ]; do
      case "$_mtk_word" in
        *=*) _mtk_rest="${_mtk_rest#"$_mtk_word"}"
             _mtk_rest="${_mtk_rest#"${_mtk_rest%%[![:space:]]*}"}"
             _mtk_word="${_mtk_rest%%[[:space:]]*}" ;;
        *)   break ;;
      esac
    done
    case "${_mtk_word##*/}" in
      grep|egrep|fgrep|rg|ack|ag|echo|printf|cat|head|tail|less|more|strings|wc) ;;
      *) printf '%s\n' "$_mtk_seg" ;;
    esac
  done
}

# The destructive-SQL pattern lives in one place so the command text and any file the
# command executes are judged by identical rules.
mtk_has_destructive_sql() {
  printf '%s' "${1-}" \
    | grep -qiE '(DROP\s+(TABLE|DATABASE|SCHEMA)|TRUNCATE\s+TABLE|DELETE\s+FROM\s+\S+\s*;?\s*$)'
}

# Files this command would execute or feed to a database client.
#
# Matching the command text alone is not enough: `bash rebuild.sh` and `psql -f drop.sql`
# contain no SQL themselves, so a DROP SCHEMA sitting in the file sails straight through.
# That is not hypothetical — it is how one got past this gate on 2026-08-10 minutes after
# the same statements had been blocked when typed inline.
# Only paths the command actually runs count. Matching every .sh/.sql path mentioned
# anywhere would block `git add rebuild.sh` and `cat drop.sql`, which execute nothing —
# reading and staging a file is not running it.
mtk_referenced_files() {
  local _cmd="${1-}"
  {
    # An interpreter runs it: bash x.sh, sh ./x.sh, source x.sh, . x.sh
    printf '%s' "$_cmd" | grep -oiE '(^|[;&|(]|[[:space:]])(bash|sh|zsh|source|\.)[[:space:]]+[A-Za-z0-9_.:@~/+-]+' || true
    # It is executed directly: ./x.sh, /opt/x.bash. Anchored to command position — after a
    # separator, not after a space — because `git add /tmp/x.sh` passes an absolute path as an
    # argument and that is not execution.
    printf '%s' "$_cmd" | grep -oE '(^|[;&|(])[[:space:]]*\.?/[A-Za-z0-9_.:@~/+-]+\.(sh|bash|zsh)' || true
    # A database client reads it: psql -f x.sql, mysql --file=x.sql
    printf '%s' "$_cmd" | grep -oiE '(-f|--file)[=[:space:]]+[A-Za-z0-9_.:@~/+-]+' || true
  } 2>/dev/null \
    | grep -oE '[A-Za-z0-9_.:@~/+-]+$' \
    | sort -u
}

# Block: database destructive operations
if mtk_has_destructive_sql "$(mtk_executable_text "$COMMAND")"; then
  mtk_deny "BLOCKED: Destructive database operation detected. Use a migration instead."
fi

# A file under the repo's own tests/ tree carries destructive statements as fixtures, not
# as work to run: tests/hooks/test-security-gate.sh asserts that `DROP SCHEMA` is blocked,
# so it must contain the string to test for it. Scanning it makes the gate block its own
# regression suite — `bash tests/hooks/test-security-gate.sh` was denied outright. Scoped
# to tests/ inside this repo and resolved by device+inode (S1.17), so a destructive script
# anywhere else, or a tests/ path in some other checkout, is still read and still caught.
mtk_is_repo_test_file() {
  local _f="${1-}" _abs _root _rel
  _root="$(mtk_repo_root 2>/dev/null || true)"
  [ -n "$_root" ] || return 1
  case "$_f" in
    /*) _abs="$_f" ;;
    *)  _abs="$PWD/$_f" ;;
  esac
  _rel="$(mtk_repo_relative_path "$_abs" "$_root" 2>/dev/null || true)"
  [ -n "$_rel" ] || return 1
  case "$_rel" in tests/*) return 0 ;; esac
  return 1
}

# Block: the same, hidden one level down in a script or .sql file the command runs.
# Only existing regular files are read, and only their first 200 KB, so this stays cheap
# on every Bash call. This narrows the gap rather than closing it — a heredoc, a file
# generated at run time, or `curl … | bash` still carries SQL this never sees. Defence in
# depth, not a wall.
while IFS= read -r _mtk_ref; do
  [ -n "$_mtk_ref" ] || continue
  [ -f "$_mtk_ref" ] || continue
  mtk_is_repo_test_file "$_mtk_ref" && continue
  # Strip `#` comment lines from anything that is not a .sql file: a comment executes
  # nothing, and prose describing the blocked statements is exactly what this hook's
  # own source (and any doc-commented migration wrapper) contains. sed, not the bash
  # loop above, because this runs over up to 200 KB on every Bash call.
  case "$_mtk_ref" in
    *.sql|*.SQL) _mtk_body="$(head -c 200000 "$_mtk_ref" 2>/dev/null || true)" ;;
    *)           _mtk_body="$(head -c 200000 "$_mtk_ref" 2>/dev/null | sed 's/[[:space:]]*#.*$//' || true)" ;;
  esac
  if mtk_has_destructive_sql "$_mtk_body"; then
    mtk_deny "BLOCKED: Destructive database operation found in ${_mtk_ref}. Use a migration instead."
  fi
done <<MTK_REFS
$(mtk_referenced_files "$COMMAND")
MTK_REFS

# Block: force push to main/master
if mtk_executable_text "$COMMAND" | grep -qE 'git\s+push\s+.*--(force|force-with-lease)\s+.*\b(main|master)\b'; then
  mtk_deny "BLOCKED: Force push to main/master is not allowed."
fi

# Block: rm -rf on project root or broad paths
if mtk_executable_text "$COMMAND" | grep -qE 'rm\s+-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*\s+(\.|/|~|\$HOME)'; then
  mtk_deny "BLOCKED: Recursive force-delete on broad path. Be more specific."
fi

# Allow everything else
exit 0
