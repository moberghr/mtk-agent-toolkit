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

mtk_normalize_path_var() {
  local _np_var="${1:-}" _np_p="${2:-}" _np_base="${3:-$PWD}" _np_rest _np_seg _np_out="" _np_n
  local -a _np_stack
  _np_stack=()
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
