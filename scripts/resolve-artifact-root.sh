#!/usr/bin/env bash
set -euo pipefail

# resolve-artifact-root.sh — resolve where workflow artifacts (docs/specs,
# docs/plans) live for a given path.
#
# Polyglot-monorepo aware, and the sibling of resolve-tech-stack.sh: the two use
# the same "closest declaration wins" idea so they are learnable as one thing.
# A subtree that owns its own specs (its own docs/specs/ plus a CLAUDE.md
# declaring it authoritative) keeps them, instead of having MTK write to the
# repo root alongside a different project's artifacts.
#
# Resolution order (first hit wins):
#   1. $MTK_ARTIFACT_ROOT env var — explicit session override, always wins.
#   2. Nearest ancestor carrying `<dir>/.claude/artifact-root` — an explicit
#      opt-in marker. Contents are ignored; presence is the declaration. This
#      also lets a subtree opt IN before it has a CLAUDE.md, and lets the repo
#      root opt out of rule 3 by claiming itself.
#   3. Nearest ancestor STRICTLY BELOW the repo root holding BOTH `CLAUDE.md`
#      and a `docs/specs/` directory. Two independent signals are required so
#      that neither a stray docs/specs/ nor a stray CLAUDE.md alone can hijack
#      resolution.
#   4. The repo root — the long-standing default.
#
# Backward compatible by construction: a repo with no qualifying subtree falls
# through to step 4 and behaves exactly as before.
#
# Prints an ABSOLUTE path to stdout. `--explain` prints the resolution source to
# stderr. Exit 0 always (a repo root is always resolvable, worst case $PWD).
#
# Usage:
#   bash scripts/resolve-artifact-root.sh [--explain] [target-path]
#   target-path defaults to $PWD; a file path resolves from its directory.
#
# No dependencies beyond coreutils + git (S3.3). git is used only to find the
# repo root; absence degrades to treating the target's own tree as the ceiling.

explain=0
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --explain) explain=1; shift ;;
    --) shift; target="${1:-}"; break ;;
    -*) echo "resolve-artifact-root: unknown flag: $1" >&2; exit 2 ;;
    *) target="$1"; shift ;;
  esac
done
target="${target:-$PWD}"

_emit() { # $1=absolute root  $2=source
  [ "$explain" -eq 1 ] && printf 'resolve-artifact-root: %s (via %s)\n' "$1" "$2" >&2
  printf '%s' "$1"
  exit 0
}

# Normalise the target to an absolute PHYSICAL directory. `pwd -P` matters for
# the same reason it does in resolve-tech-stack.sh: repo_root below comes from
# git, which always reports the physical path, and the walk compares the two.
if [ -d "$target" ]; then
  target_dir="$(cd "$target" && pwd -P)"
elif [ -f "$target" ]; then
  target_dir="$(cd "$(dirname "$target")" && pwd -P)"
else
  target_dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P || printf '%s' "$PWD")"
fi

# 1. Explicit env override.
if [ -n "${MTK_ARTIFACT_ROOT:-}" ]; then
  _emit "$MTK_ARTIFACT_ROOT" "MTK_ARTIFACT_ROOT env"
fi

repo_root="$(cd "$target_dir" && git rev-parse --show-toplevel 2>/dev/null || true)"

# 2 + 3. ONE walk from the target upward, testing both declarations at each
# level, so the CLOSEST declaration wins regardless of which kind it is. Running
# the marker rule as its own full walk first would let a distant repo-root
# marker outrank a nearer qualifying subtree — the opposite of closest-wins.
#
# Within a single level the explicit marker is checked first: an author who
# wrote `.claude/artifact-root` outranks the inferred CLAUDE.md + docs/specs
# signal for that same directory.
dir="$target_dir"
while :; do
  if [ -e "$dir/.claude/artifact-root" ]; then
    _emit "$dir" "marker $dir/.claude/artifact-root"
  fi
  # The two-signal rule applies only STRICTLY below the repo root — at the root
  # itself it would be trivially true for any MTK repo and would just restate
  # the default. Requires BOTH signals: docs/specs/ (it has artifacts) and
  # CLAUDE.md (it declares itself a project). Either alone is too weak — plenty
  # of repos have a docs/ tree or a nested CLAUDE.md without a spec workflow.
  if [ -n "$repo_root" ] && [ "$dir" != "$repo_root" ] &&
     [ -d "$dir/docs/specs" ] && [ -f "$dir/CLAUDE.md" ]; then
    _emit "$dir" "subproject $dir (CLAUDE.md + docs/specs)"
  fi
  [ -n "$repo_root" ] && [ "$dir" = "$repo_root" ] && break
  parent="$(dirname "$dir")"
  [ "$parent" = "$dir" ] && break
  dir="$parent"
done

# 4. Repo root default.
if [ -n "$repo_root" ]; then
  _emit "$repo_root" "repo root"
fi
_emit "$target_dir" "no git repo — target dir"
