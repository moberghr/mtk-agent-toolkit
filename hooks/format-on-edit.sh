#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# Format the files Claude edited this turn — QUEUE at PostToolUse, FORMAT at Stop.
#
# Two modes, selected by argument (same shape as `rule-trigger.sh --rearm`):
#
#   (no argument)  PostToolUse  -> record the edited path in a per-session queue
#   --flush        Stop /       -> format every queued path, once, then clear
#                  SubagentStop
#
# WHY THE SPLIT. Formatting inside PostToolUse rewrites a file Claude has
# already read, so its next Edit against that file fails with "File has been
# modified since read" and the turn stalls on a retry loop. The queue defers
# every mutation until after Claude has stopped responding, which removes the
# race entirely. This is the same reason a formatter should never be wired as a
# bare PostToolUse mutation, and it is why BOTH hooks below must be wired — with
# only the PostToolUse half, files are queued and never formatted.
#
# Wired from the PLUGIN's hooks/hooks.json — PostToolUse (Edit|Write), Stop
# (--flush) and SubagentStop (--flush). NOT from a project .claude/settings.json:
# ${CLAUDE_PLUGIN_ROOT} is only defined for hooks a plugin declares itself, so the
# same command in a project file expands to `bash /hooks/format-on-edit.sh` and
# fails on every single edit (measured: 4,552 failures across 7 repos, with
# formatting never actually running). Project-scope opt-in is the
# `.claude/tech-stack` marker checked below, not a duplicated hook entry.
#
# Per-stack formatter is selected by file extension. Add new stacks by extending
# the case block in format_one / flush_dotnet. Failures are reported on stderr
# (so they surface in Claude Code's hook log) but never block.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

# This hook is wired from the plugin's own hooks/hooks.json, which is the only
# scope where ${CLAUDE_PLUGIN_ROOT} is defined. A repo bootstrapped before that
# change may still wire the same basename from its .claude/settings.json; the
# redundancy guard keeps the two registrations from double-firing.
mtk_is_redundant_plugin_invocation "$0" && exit 0

# Project opt-in. Plugin-scope registration means this hook is reachable in every
# repo the plugin is active in, including ones that never adopted MTK. Formatting
# is a mutation, so it stays opt-in: the `.claude/tech-stack` marker that
# setup-bootstrap writes is the opt-in signal. `MTK_FORMAT_ON_EDIT=1` forces it on
# for a repo that formats but has no marker; `=0` opts a bootstrapped repo out.
case "${MTK_FORMAT_ON_EDIT:-}" in
  0) exit 0 ;;
  1) ;;
  *) [ -f "$(mtk_repo_root)/.claude/tech-stack" ] || exit 0 ;;
esac

MODE="collect"
[ "${1:-}" = "--flush" ] && MODE="flush"

log_warn() {
  printf 'mtk format-on-edit: %s\n' "$1" >&2
}

# Extensions this hook knows how to format. Anything else is never queued, so
# the flush pass has no unformattable paths to skip.
is_formattable() {
  case "${1##*.}" in
    ts|tsx|js|jsx|mjs|cjs|py|cs) return 0 ;;
    *) return 1 ;;
  esac
}

# Queue path is per project AND per session: two concurrent sessions in the same
# repo must not flush each other's edits. Mirrors mtk_session_file's naming.
queue_file() {
  local payload="$1" session project_id
  session="$(mtk_extract_json_string "$payload" "session_id" 2>/dev/null || true)"
  [ -n "$session" ] || session="unknown"
  # Defend the filename against a hostile or unusual session id.
  session="$(printf '%s' "$session" | tr -c 'A-Za-z0-9._-' '_')"
  project_id="$(mtk_repo_root | cksum | cut -d' ' -f1)"
  printf '%s/mtk-format-queue-%s-%s\n' "${TMPDIR:-/tmp}" "$project_id" "$session"
}

INPUT="$(mtk_read_payload)"
QUEUE="$(queue_file "$INPUT")"

# ---------------------------------------------------------------- collect ----

if [ "$MODE" = "collect" ]; then
  FILE_PATH=$(mtk_extract_file_path "$INPUT" 2>/dev/null || true)
  [ -n "${FILE_PATH:-}" ] || exit 0
  [ -f "$FILE_PATH" ] || exit 0
  is_formattable "$FILE_PATH" || exit 0
  printf '%s\n' "$FILE_PATH" >>"$QUEUE" 2>/dev/null || true
  exit 0
fi

# ------------------------------------------------------------------ flush ----

[ -s "$QUEUE" ] || exit 0

# Dedupe, and drop anything deleted or moved since it was queued. Clear the
# queue before formatting so a formatter that hangs or crashes cannot leave
# entries behind to be reformatted on every subsequent turn.
FILES=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  FILES+=("$f")
done < <(sort -u "$QUEUE")
: >"$QUEUE"
[ "${#FILES[@]}" -gt 0 ] || exit 0

run_formatter() {
  local label="$1"; shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_warn "${label} failed (exit ${rc})"
    return 1
  fi
  return 0
}

# Nearest ancestor directory holding a build file of one of the given globs.
# Prints the directory, or nothing when the walk reaches / without a match.
nearest_dir_with() {
  local start="$1"; shift
  local d
  d="$(cd "$(dirname "$start")" 2>/dev/null && pwd -P)" || return 1
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    local pat
    for pat in "$@"; do
      # shellcheck disable=SC2086
      if compgen -G "$d"/$pat >/dev/null 2>&1; then printf '%s' "$d"; return 0; fi
    done
    d="$(dirname "$d")"
  done
  return 1
}

# dotnet is batched per workspace, not run per file, for two verified reasons:
#
#  1. `dotnet format --include` matches paths RELATIVE to the workspace
#     directory. Handed an absolute path it silently matches NOTHING and still
#     exits 0 (verified, dotnet 10.0.110) — which is what the previous
#     `--include "$FILE_PATH"` did: a no-op that reported success.
#  2. dotnet format loads the whole workspace before filtering, so one
#     invocation per file is pathological. Scoping to the containing .csproj
#     rather than the .sln is measurably faster (~7s vs ~11s on a mid-size
#     solution), so the project is preferred and the solution is the fallback.
flush_dotnet() {
  local -a cs=("$@")
  command -v dotnet >/dev/null 2>&1 || return 0

  # Group by workspace directory: "<dir>\t<file>" sorted, then one run per dir.
  local ws rel line dir
  local -a pairs=() includes=()
  for f in "${cs[@]}"; do
    ws="$(nearest_dir_with "$f" '*.csproj' || true)"
    [ -n "$ws" ] || ws="$(nearest_dir_with "$f" '*.sln' '*.slnx' || true)"
    if [ -z "$ws" ]; then
      log_warn "no .csproj/.sln above ${f} — skipped (refusing to format repo-wide)"
      continue
    fi
    rel="$(mtk_repo_relative_path "$f" "$ws" 2>/dev/null || true)"
    [ -n "$rel" ] || continue
    pairs+=("${ws}"$'\t'"${rel}")
  done
  [ "${#pairs[@]}" -gt 0 ] || return 0

  dir=""
  includes=()
  while IFS= read -r line; do
    local this_dir="${line%%$'\t'*}" this_rel="${line#*$'\t'}"
    if [ "$this_dir" != "$dir" ]; then
      [ -n "$dir" ] && dotnet_format_in "$dir" "${includes[@]}"
      dir="$this_dir"
      includes=()
    fi
    includes+=("$this_rel")
  done < <(printf '%s\n' "${pairs[@]}" | sort -u)
  # `includes` is never empty when `dir` is set — the append below the branch
  # above always runs for the group that set it — so the `set -u` expansion of
  # an empty array (a hard error on bash < 4.4) is unreachable here.
  [ -n "$dir" ] && dotnet_format_in "$dir" "${includes[@]}"
  return 0
}

# `--include` takes a LIST of paths, each relative to the directory dotnet
# format is invoked from — hence the subshell cd. They must be passed as
# separate argv entries, not joined into one word: a path containing a space
# ("My Folder/S.cs") that gets split becomes two include patterns, neither of
# which matches, and dotnet format then formats nothing and exits 0 — the exact
# silent no-op this function exists to fix. Verified on dotnet 10.0.100.
dotnet_format_in() {
  local dir="$1"; shift
  ( cd "$dir" && dotnet format --include "$@" --verbosity quiet ) >/dev/null 2>&1 \
    || log_warn "dotnet format failed in ${dir} ($*)"
}

format_one() {
  local f="$1"
  case "${f##*.}" in
    ts|tsx|js|jsx|mjs|cjs)
      command -v npx >/dev/null 2>&1 || return 0
      run_formatter "biome ${f}" npx --no-install biome format --write "$f" \
        || run_formatter "prettier ${f}" npx --no-install prettier --write --log-level=warn "$f" \
        || true
      ;;
    py)
      if command -v ruff >/dev/null 2>&1; then
        run_formatter "ruff format ${f}" ruff format "$f" || true
        run_formatter "ruff check --fix ${f}" ruff check --fix "$f" || true
      elif command -v black >/dev/null 2>&1; then
        run_formatter "black ${f}" black --quiet "$f" || true
      fi
      ;;
  esac
  return 0
}

CS=()
for f in "${FILES[@]}"; do
  if [ "${f##*.}" = "cs" ]; then CS+=("$f"); else format_one "$f"; fi
done
[ "${#CS[@]}" -gt 0 ] && flush_dotnet "${CS[@]}"

exit 0
