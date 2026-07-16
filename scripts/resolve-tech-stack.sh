#!/usr/bin/env bash
set -euo pipefail

# resolve-tech-stack.sh — resolve the active tech stack for a given path.
#
# Polyglot-monorepo aware: a TypeScript subproject under a .NET repo root
# resolves to `typescript` when work happens inside it, instead of the
# repo-root default. Consolidates the `tr -d '[:space:]' < .claude/tech-stack`
# read that consumers previously inlined (which was repo-root-only).
#
# Resolution order (first hit wins):
#   1. $MTK_STACK env var — explicit session override, always wins.
#   2. Nearest ancestor `.claude/tech-stack` STRICTLY BELOW the repo root,
#      walking up from the target path. A subproject with its own `.claude`
#      wins — "closest declaration wins", like .editorconfig / .gitignore.
#   3. Root `.claude/tech-stack.map` — lines `<path-glob><whitespace><stack>`,
#      matched against the target's repo-relative dir; first glob wins.
#      `#` comments and blank lines are ignored.
#   4. Root `.claude/tech-stack` — the long-standing single-stack default.
#
# Prints the resolved stack word to stdout (empty string + exit 0 if none
# resolves — callers treat empty as "unconfigured", same as a missing file).
# `--explain` prints the resolution source to stderr.
#
# Usage:
#   bash scripts/resolve-tech-stack.sh [--explain] [target-path]
#   target-path defaults to $PWD; a file path resolves from its directory.
#
# No dependencies beyond coreutils + git (S3.3). git is used only to find the
# repo root; absence degrades to a filesystem-root walk.

explain=0
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --explain) explain=1; shift ;;
    --) shift; target="${1:-}"; break ;;
    -*) echo "resolve-tech-stack: unknown flag: $1" >&2; exit 2 ;;
    *) target="$1"; shift ;;
  esac
done
target="${target:-$PWD}"

_emit() { # $1=stack  $2=source
  [ "$explain" -eq 1 ] && printf 'resolve-tech-stack: %s (via %s)\n' "${1:-<none>}" "$2" >&2
  printf '%s' "${1:-}"
}

# Normalize target to an absolute directory (a file resolves from its dir; a
# non-existent path from its lexical parent, else $PWD).
if [ -d "$target" ]; then
  target_dir="$(cd "$target" && pwd)"
elif [ -f "$target" ]; then
  target_dir="$(cd "$(dirname "$target")" && pwd)"
else
  target_dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd || printf '%s' "$PWD")"
fi

# 1. Explicit env override.
if [ -n "${MTK_STACK:-}" ]; then
  _emit "$(printf '%s' "$MTK_STACK" | tr -d '[:space:]')" "MTK_STACK env"
  exit 0
fi

# Repo root is the ceiling for the walk-up and the anchor for the map/default.
repo_root="$(cd "$target_dir" && git rev-parse --show-toplevel 2>/dev/null || true)"

# 2. Nearest subproject-local .claude/tech-stack, strictly below repo root.
#    (When repo_root is unknown, this loop still walks to the filesystem root
#    and returns the nearest sighting — graceful degrade to old behavior.)
dir="$target_dir"
while :; do
  if [ -n "$repo_root" ] && [ "$dir" = "$repo_root" ]; then
    break   # the root's own tech-stack is the step-4 default, not a subproject
  fi
  if [ -s "$dir/.claude/tech-stack" ]; then
    s="$(tr -d '[:space:]' < "$dir/.claude/tech-stack")"
    if [ -n "$s" ]; then _emit "$s" "subproject $dir/.claude/tech-stack"; exit 0; fi
  fi
  parent="$(dirname "$dir")"
  [ "$parent" = "$dir" ] && break
  dir="$parent"
done

root="${repo_root:-.}"

# 3. Root tech-stack.map glob match against the target's repo-relative dir.
map="$root/.claude/tech-stack.map"
if [ -f "$map" ]; then
  rel="${target_dir#"$root"/}"
  [ "$rel" = "$target_dir" ] && rel="."   # target_dir == root
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"                     # strip trailing comment
    # shellcheck disable=SC2086 # intentional word-split of "<glob> <stack>"
    set -- $line
    [ $# -ge 2 ] || continue
    glob="$1"; st="$2"
    case "$rel/" in
      $glob|$glob/*) _emit "$st" "tech-stack.map:$glob"; exit 0 ;;
    esac
  done < "$map"
fi

# 4. Root default.
if [ -s "$root/.claude/tech-stack" ]; then
  _emit "$(tr -d '[:space:]' < "$root/.claude/tech-stack")" "root .claude/tech-stack"
else
  _emit "" "unresolved"
fi
exit 0
