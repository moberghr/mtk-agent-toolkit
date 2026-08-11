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
#   bash scripts/resolve-tech-stack.sh [--explain] [--check] [target-path...]
#   target-path defaults to $PWD; a file path resolves from its directory.
#
# `--check` compares the resolved stack against the extensions of the given
# paths and warns on stderr when they disagree (e.g. stack resolves `dotnet`
# but the paths are .tsx) — the polyglot-repo case where a root-only pin
# silently hands out the wrong build/test commands. Advisory only: it never
# blocks, never changes the resolved value, and never changes the exit code.
# Files with non-stack-bearing extensions (.md, .json, .sh) are ignored.
#
# No dependencies beyond coreutils + git (S3.3). git is used only to find the
# repo root; absence degrades to a filesystem-root walk.

explain=0
check=0
target=""
check_paths=""
while [ $# -gt 0 ]; do
  case "$1" in
    --explain) explain=1; shift ;;
    --check) check=1; shift ;;
    --) shift; target="${1:-}"; break ;;
    -*) echo "resolve-tech-stack: unknown flag: $1" >&2; exit 2 ;;
    *) target="$1"; check_paths="$check_paths$1
"; shift ;;
  esac
done
target="${target:-$PWD}"

# Map a file extension to the stack that owns it. Empty = not stack-bearing
# (.md, .json, .sh, .yml ...), which never triggers a mismatch warning.
_family_of() {
  case "$1" in
    cs|csproj|sln|razor|cshtml|fs|fsproj|vb|xaml|axaml) printf 'dotnet' ;;
    py|pyi|ipynb)                                       printf 'python' ;;
    ts|tsx|js|jsx|mjs|cjs|vue|svelte)                   printf 'typescript' ;;
    *)                                                  printf '' ;;
  esac
}

# --check: compare the resolved stack against the extensions actually being
# touched and warn on disagreement. ADVISORY ONLY — never blocks, never changes
# the resolved value or the exit code. A repo pinned `dotnet` at the root that
# is having its Vite subtree edited would otherwise silently hand out
# `dotnet build` for .tsx files.
_check_mismatch() { # $1=resolved stack
  [ "$check" -eq 1 ] || return 0
  [ -n "${1:-}" ] || return 0
  resolved="$1"
  mismatched=""; matched=0; mismatch_n=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    base="${p##*/}"
    case "$base" in *.*) ext="${base##*.}" ;; *) continue ;; esac
    fam="$(_family_of "$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')")"
    [ -n "$fam" ] || continue
    if [ "$fam" = "$resolved" ]; then
      matched=$((matched + 1))
    else
      mismatch_n=$((mismatch_n + 1))
      case " $mismatched " in *" $fam "*) : ;; *) mismatched="$mismatched $fam" ;; esac
    fi
  done <<EOF
$check_paths
EOF
  [ "$mismatch_n" -gt 0 ] || return 0
  printf 'resolve-tech-stack: WARNING — resolved stack is `%s`, but %d of the target file(s) look like%s.\n' \
    "$resolved" "$mismatch_n" "$(printf '%s' "$mismatched" | sed 's/ / `/g; s/$/`/')" >&2
  if [ "$matched" -eq 0 ]; then
    printf '  No target file matches `%s`. This is likely a polyglot repo whose subtree stack is undeclared.\n' "$resolved" >&2
  fi
  printf '  Declare the subtree: add `<subtree>/.claude/tech-stack`, or a root `.claude/tech-stack.map` line `<glob> <stack>`.\n' >&2
  printf '  Advisory only — resolution and exit code are unchanged.\n' >&2
}

_emit() { # $1=stack  $2=source
  [ "$explain" -eq 1 ] && printf 'resolve-tech-stack: %s (via %s)\n' "${1:-<none>}" "$2" >&2
  _check_mismatch "${1:-}"
  printf '%s' "${1:-}"
}

# Normalize target to an absolute PHYSICAL directory (a file resolves from its
# dir; a non-existent path from its lexical parent, else $PWD).
#
# `pwd -P` is required, not cosmetic: `repo_root` below comes from
# `git rev-parse --show-toplevel`, which always reports the physical path. With
# a logical `pwd` the two disagree whenever the root is reached through a
# symlink (/var -> /private/var on macOS, symlinked home or checkout dirs), the
# `${target_dir#"$root"/}` strip below silently no-ops, and every
# `.claude/tech-stack.map` glob then fails to match — the map degrades to "root
# default" with no diagnostic.
if [ -d "$target" ]; then
  target_dir="$(cd "$target" && pwd -P)"
elif [ -f "$target" ]; then
  target_dir="$(cd "$(dirname "$target")" && pwd -P)"
else
  target_dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P || printf '%s' "$PWD")"
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
