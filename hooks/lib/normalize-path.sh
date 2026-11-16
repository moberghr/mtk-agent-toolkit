#!/usr/bin/env bash
set -euo pipefail

# Lexical path normalisation shared by the edit guards (scope-guard.sh,
# config-guard.sh). A guard that matches a path by string before collapsing
# its `..` segments can be walked past: `<root>/.mtk/../src/b.cs` reads as
# workflow state and `<root>/src/a.cs/../b.cs` as a file under a manifest
# entry. Normalise first, then exempt or match.
#
#   mtk_normalize_path <path> [base]
#     Prints <path> made absolute (a relative path is anchored at <base>,
#     default $PWD) with '', '.' and '..' segments resolved as strings. No
#     filesystem access, so the target need not exist; symlinks are not
#     resolved. `..` above / stays at /. Pure bash, bash-3.2 safe.
#   mtk_normalize_path_var <var> <path> [base]
#     The same, assigned to <var> instead of printed: no subshell, and a
#     trailing newline in the result survives (`$(…)` would strip it).
#
# Every byte but `/` is segment text. The split is a parameter-expansion loop,
# never `read` (which stops at the first newline: `/r/.mtk/x<LF>/../../src/b.cs`
# used to normalise to `/r/.mtk/x`) and never an unquoted expansion (which
# would split on IFS and glob-expand `*`, `?` and `[`).
#
# Windows: Claude Code on Windows sends drive-letter paths (`C:\repo\.editorconfig`)
# while Git Bash spells the same file `/c/repo/.editorconfig`, and
# `git rev-parse --show-toplevel` prints `C:/repo`. A drive-letter path is not
# `/`-prefixed, so it used to be anchored at $PWD as a relative path with its
# backslashes kept as segment text: the guard named `repo/C:\repo\.editorconfig`,
# an approved path never matched `.mtk/config-guard-allow`, and the approval
# list itself was not recognised as such. A path that opens with `<letter>:\`
# or `<letter>:/` is rewritten to the Git Bash form first: backslashes become
# `/` and the drive becomes `/<lowercase letter>`. Nothing else is touched, so
# on Linux and macOS a real path is unaffected (a drive-letter path is never an
# absolute path there).
#
#   mtk_windows_path_to_posix_var <var> <path>

mtk_windows_path_to_posix_var() {
  local _wp_var="${1:-}" _wp_p="${2:-}" _wp_drive
  case "$_wp_p" in
    [A-Za-z]:[\\/]*|[A-Za-z]:)
      _wp_drive="$(printf '%s' "${_wp_p:0:1}" | tr '[:upper:]' '[:lower:]')"
      _wp_p="/${_wp_drive}${_wp_p:2}"
      _wp_p="${_wp_p//\\//}"
      ;;
  esac
  printf -v "$_wp_var" '%s' "$_wp_p"
}

mtk_normalize_path_var() {
  local _np_var="${1:-}" _np_p="${2:-}" _np_base="${3:-$PWD}" _np_rest _np_seg _np_out="" _np_n
  local -a _np_stack
  _np_stack=()
  mtk_windows_path_to_posix_var _np_p "$_np_p"
  mtk_windows_path_to_posix_var _np_base "$_np_base"
  case "$_np_p" in /*) ;; *) _np_p="$_np_base/$_np_p" ;; esac
  # A trailing `/` makes every segment, the last included, slash-terminated.
  _np_rest="$_np_p/"
  while [ -n "$_np_rest" ]; do
    _np_seg="${_np_rest%%/*}"
    _np_rest="${_np_rest#*/}"
    case "$_np_seg" in
      ''|.) ;;
      # Only the last element is ever removed, so the array stays dense and the
      # next append lands at index ${#_np_stack[@]}.
      ..) _np_n=${#_np_stack[@]}; [ "$_np_n" -eq 0 ] || unset "_np_stack[$((_np_n - 1))]" ;;
      *) _np_stack[${#_np_stack[@]}]="$_np_seg" ;;
    esac
  done
  for _np_seg in ${_np_stack[@]+"${_np_stack[@]}"}; do _np_out="$_np_out/$_np_seg"; done
  printf -v "$_np_var" '%s' "${_np_out:-/}"
}

mtk_normalize_path() {
  local _np_result
  mtk_normalize_path_var _np_result "${1:-}" "${2:-$PWD}"
  printf '%s' "$_np_result"
}
