#!/usr/bin/env bash
set -euo pipefail
# verify-references.sh — Check that directories, projects, and solution members
# referenced in MTK-generated docs actually exist on disk.
#
# This is the path-existence half of setup-bootstrap STEP 3.5a. It is distinct
# from verify-claims.sh: that one greps cited evidence anchors and downgrades
# rule tags in place; THIS one answers "does the referenced path exist?" and
# emits STALE advisories without modifying any file.
#
# Checks (parity with the former inline STEP 3.5a bash):
#   1. Directory claims — every `path/`-shaped token must `test -d`.
#      (Also covers the rules-file proper-noun scan: rules files are passed in.)
#   2. Project-file claims — each referenced `.csproj` must exist on disk.
#   3. Framework / version claims — informational dump of actual TargetFramework
#      / requires-python / engines so the caller can cross-check version claims.
#   4. Solution membership vs disk reality — each `.csproj` listed in a `.sln`
#      must exist (solution lists are not proof of existence).
#
# Side effects: none. Read-only. Prints STALE / INFO lines to stdout.
#
# Exit codes:
#   0 — no stale references found
#   3 — one or more stale references found (STALE lines printed)
#   2 — not in a git repo / no input files resolved
#
# Usage:
#   bash scripts/verify-references.sh CLAUDE.md .claude/rules/*.md \
#     .claude/references/architecture-principles.md
#   # With no args, defaults to the standard generated-file set.
#
# Spec: docs/specs/2026-05-29-setup-bootstrap-slimming-phase2.md

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "verify-references: not inside a git repository" >&2
  exit 2
}

# --- Resolve input files ----------------------------------------------------
if [ "$#" -gt 0 ]; then
  FILES=("$@")
else
  FILES=(CLAUDE.md .claude/references/architecture-principles.md)
  # Expand rules glob if present.
  for f in .claude/rules/*.md; do
    [ -f "$f" ] && FILES+=("$f")
  done
fi

# Keep only files that exist.
EXISTING=()
for f in "${FILES[@]}"; do
  [ -f "$f" ] && EXISTING+=("$f")
done
[ "${#EXISTING[@]}" -gt 0 ] || { echo "verify-references: no input files resolved" >&2; exit 2; }

STALE=0

# --- Check 1: path / directory claims (near-zero false positives) ------------
# Only path-like tokens INSIDE backtick code spans count (never prose), and a
# token is declared stale only after it fails to resolve at the root, under
# src/, AND in the git index. This avoids the broad-regex noise (prose slashes
# like `I/O`, npm scopes, subtree-relative paths) that buried real stale refs.
for file in "${EXISTING[@]}"; do
  while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    case "$tok" in *" "*|http*|ftp*|@*) continue ;; esac   # prose / URL / npm scope
    echo "$tok" | grep -qE '/' || continue                 # must have a separator
    # path-like = known prefix OR dot-extension. A bare trailing-slash acronym
    # (REST/, SQS/) is prose, NOT a directory claim — excluded to keep FPs near zero.
    echo "$tok" | grep -qE '(^(src|apps|packages|libs|services|tests?|lib)/|\.[A-Za-z0-9]+$)' || continue
    p="${tok%/}"
    # resolve subtree-relative before declaring stale: root, src/, then git index
    if [ -e "$p" ] || [ -e "src/$p" ] || git ls-files --error-unmatch "$p" >/dev/null 2>&1 || git ls-files "$p" 2>/dev/null | grep -qF "$p"; then
      continue
    fi
    echo "STALE in $file: '$tok' looks like a path but resolves nowhere (root, src/, or git index)"
    STALE=$((STALE + 1))
  done < <(grep -oE '`[^`]+`' "$file" 2>/dev/null | tr -d '`' | sort -u || true)
done

# --- Check 2: project-file claims (.csproj) ----------------------------------
for file in "${EXISTING[@]}"; do
  while IFS= read -r proj; do
    [ -z "$proj" ] && continue
    if ! find . -name "$proj" -not -path "*/bin/*" -not -path "*/obj/*" 2>/dev/null | grep -q .; then
      echo "STALE in $file: $proj not found"
      STALE=$((STALE + 1))
    fi
  done < <(grep -oE '[A-Za-z0-9._-]+\.csproj' "$file" 2>/dev/null | sort -u || true)
done

# --- Check 3: framework / version claims (informational) --------------------
# Cross-check version claims in the docs against these actual values by eye.
FW="$(grep -rh "TargetFramework" --include="*.csproj" . 2>/dev/null | sort -u || true)"
[ -n "$FW" ] && echo "INFO: actual .NET TargetFramework(s):" && printf '%s\n' "$FW"
[ -f .python-version ] && echo "INFO: .python-version: $(cat .python-version)"
PYREQ="$(grep -h "requires-python" pyproject.toml 2>/dev/null || true)"
[ -n "$PYREQ" ] && echo "INFO: pyproject requires-python: $PYREQ"

# --- Check 4: solution membership vs disk reality ----------------------------
while IFS= read -r proj; do
  [ -z "$proj" ] && continue
  if [ ! -f "$proj" ]; then
    echo "STALE: solution references $proj but file does not exist"
    STALE=$((STALE + 1))
  fi
done < <(grep -h 'Project(' ./*.sln 2>/dev/null | grep -oE '"[^"]+\.csproj"' | tr -d '"' | tr '\\' '/' | sort -u || true)

# --- Report -----------------------------------------------------------------
if [ "$STALE" -gt 0 ]; then
  echo "verify-references: $STALE stale reference(s) found" >&2
  exit 3
fi
echo "verify-references: no stale references found"
exit 0
