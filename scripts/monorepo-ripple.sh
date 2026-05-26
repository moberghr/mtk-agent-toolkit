#!/usr/bin/env bash
set -euo pipefail
# monorepo-ripple.sh — Detect monorepo and list cross-package ripples for input files.
#
# Usage:
#   bash scripts/monorepo-ripple.sh <file>...
#
# Behavior:
# - Non-monorepo: exits 0 with no output.
# - Monorepo: identifies which package each file belongs to, then prints
#   downstream packages that reference that package as
#     RIPPLE <pkg>: affects <downstream-pkg>
# - Always exits 0 (advisory). Errors go to stderr.
#
# Supported flavors: pnpm-workspace.yaml, npm/yarn "workspaces" in package.json,
# Maven aggregator <modules>, dotnet (>=2 *.csproj), Python libs/ with pyproject.toml.

[[ $# -eq 0 ]] && exit 0

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

# --- Detect monorepo type and collect package roots ------------------------

PACKAGE_ROOTS=()   # absolute or repo-relative directories that are packages
FLAVOR=""

if [[ -f pnpm-workspace.yaml ]]; then
  FLAVOR="pnpm"
  # Naive parse: lines like "  - 'packages/*'" or "  - libs/*"
  while IFS= read -r pat; do
    pat=$(echo "$pat" | sed -E "s/^[[:space:]]*-[[:space:]]*['\"]?//; s/['\"]?[[:space:]]*$//")
    [[ -z "$pat" ]] && continue
    # Expand glob: only handle trailing /* (most common)
    base="${pat%/\*}"
    if [[ "$base" != "$pat" ]] && [[ -d "$base" ]]; then
      for d in "$base"/*/; do
        [[ -d "$d" ]] && PACKAGE_ROOTS+=("${d%/}")
      done
    elif [[ -d "$pat" ]]; then
      PACKAGE_ROOTS+=("$pat")
    fi
  done < <(awk '/^packages:/{flag=1;next} /^[a-z]/{flag=0} flag' pnpm-workspace.yaml)
elif [[ -f package.json ]] && grep -q '"workspaces"' package.json; then
  FLAVOR="npm"
  PATTERNS=$(python3 -c '
import json, sys
try:
    d = json.load(open("package.json"))
    ws = d.get("workspaces", [])
    if isinstance(ws, dict):
        ws = ws.get("packages", [])
    for p in ws: print(p)
except Exception:
    pass
')
  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    base="${pat%/\*}"
    if [[ "$base" != "$pat" ]] && [[ -d "$base" ]]; then
      for d in "$base"/*/; do
        [[ -d "$d" ]] && PACKAGE_ROOTS+=("${d%/}")
      done
    elif [[ -d "$pat" ]]; then
      PACKAGE_ROOTS+=("$pat")
    fi
  done <<< "$PATTERNS"
elif [[ -f pom.xml ]] && grep -q '<modules>' pom.xml; then
  FLAVOR="maven"
  while IFS= read -r mod; do
    [[ -n "$mod" ]] && [[ -d "$mod" ]] && PACKAGE_ROOTS+=("$mod")
  done < <(awk '/<modules>/,/<\/modules>/' pom.xml | grep -oE '<module>[^<]+' | sed 's/<module>//')
elif [[ -d libs ]] && find libs -maxdepth 2 -name 'pyproject.toml' 2>/dev/null | grep -q .; then
  FLAVOR="python-libs"
  while IFS= read -r f; do
    PACKAGE_ROOTS+=("$(dirname "$f")")
  done < <(find libs -maxdepth 2 -name 'pyproject.toml' -type f 2>/dev/null)
else
  # dotnet: only treat as monorepo when >= 2 csproj files exist
  CSPROJ_COUNT=$(find . -maxdepth 4 -name '*.csproj' -type f 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$CSPROJ_COUNT" -ge 2 ]]; then
    FLAVOR="dotnet"
    while IFS= read -r f; do
      PACKAGE_ROOTS+=("$(dirname "$f")")
    done < <(find . -maxdepth 4 -name '*.csproj' -type f 2>/dev/null)
  fi
fi

if [[ ${#PACKAGE_ROOTS[@]} -lt 2 ]]; then
  # Not a monorepo (or only one package). No-op.
  exit 0
fi

# --- Identify owning packages for each input file -------------------------

# longest-prefix match
owner_of() {
  local file="$1"
  local best=""
  local best_len=0
  for pkg in "${PACKAGE_ROOTS[@]}"; do
    local pkg_norm="${pkg#./}"
    if [[ "$file" == "$pkg_norm"/* ]] || [[ "$file" == "$pkg_norm" ]]; then
      local len=${#pkg_norm}
      if [[ "$len" -gt "$best_len" ]]; then
        best="$pkg_norm"
        best_len="$len"
      fi
    fi
  done
  echo "$best"
}

declare -a TOUCHED_PKGS=()
for f in "$@"; do
  f="${f#./}"
  owner=$(owner_of "$f")
  if [[ -n "$owner" ]]; then
    TOUCHED_PKGS+=("$owner")
  fi
done

# Dedup
if [[ ${#TOUCHED_PKGS[@]} -eq 0 ]]; then
  exit 0
fi
UNIQUE_PKGS=$(printf "%s\n" "${TOUCHED_PKGS[@]}" | sort -u)

# --- Compute ripples ------------------------------------------------------

# For each touched package, grep its name across OTHER packages.
# Heuristic: package name = basename of its directory. Match in imports/refs.

pkg_basename() {
  basename "$1"
}

while IFS= read -r touched; do
  [[ -z "$touched" ]] && continue
  name=$(pkg_basename "$touched")
  # name must be at least 3 chars to avoid false positives ("ui", "fs")
  [[ ${#name} -lt 3 ]] && continue
  # Search across other package roots for references to this name.
  for other in "${PACKAGE_ROOTS[@]}"; do
    other="${other#./}"
    [[ "$other" == "$touched" ]] && continue
    # Use grep -r with file types that import other packages.
    # Quote patterns vary by language; use a broad reference + path check.
    if grep -rIql --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
        --include="*.py" --include="*.java" --include="*.kt" --include="*.cs" \
        --include="*.json" --include="*.toml" --include="*.xml" \
        -e "$name" "$other" 2>/dev/null | head -1 | grep -q .; then
      echo "RIPPLE $touched: affects $other"
    fi
  done
done <<< "$UNIQUE_PKGS"
