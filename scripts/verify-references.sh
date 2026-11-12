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
#      Placeholder segments — `<name>`, `{name}` (not `{a,b}` alternation),
#      `$VAR` / `${VAR}`, `YYYY-MM-DD` and `…` / `...` — become `*`, and a
#      token with `*` or `?` is a pattern: it resolves when any path matches
#      (root, src/, or the git index at any depth). A bare `name/` directory
#      resolves when a tracked directory of that name exists at any depth.
#      Unresolved tokens that git ignores (runtime state such as `.mtk/`) are
#      skipped. Authors opt a token out with `<!-- verify-references: ignore -->`
#      on its line, or a glob in `.claude/verify-references.ignore` (one per
#      line, `#` comments). The skipped count goes to stderr.
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
  # Both constitution spellings: AGENTS.md is canonical post-inversion, CLAUDE.md
  # is either a legacy constitution or a shim. Non-existent entries are filtered
  # below, so listing both is safe in either repo shape. Verifying only CLAUDE.md
  # here would scan an 11-line shim and silently skip every path claim in the
  # real constitution.
  FILES=(AGENTS.md CLAUDE.md .claude/references/architecture-principles.md)
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
SKIPPED=0

# Known-optional references: paths that are legitimately referenced-but-absent
# (gitignored, created lazily on first use, or never checked in) — never STALE.
KNOWN_OPTIONAL='^(\.claude/settings\.local\.json|\.claude\.local\.md|tasks/todo\.md|\.claude/review-config\.local\.json)$'

# Author opt-outs: one glob per line in the ignore file (`#` comments), or the
# marker comment on the line that carries the token.
IGNORE_MARKER='<!-- verify-references: ignore -->'
IGNORE_GLOBS=()
if [ -f .claude/verify-references.ignore ]; then
  while IFS= read -r g || [ -n "$g" ]; do
    g="${g#"${g%%[![:space:]]*}"}"; g="${g%"${g##*[![:space:]]}"}"   # trim
    case "$g" in ''|'#'*) continue ;; esac
    IGNORE_GLOBS+=("$g")
  done < .claude/verify-references.ignore
fi

opted_out() { # $1 = token, $2 = token without trailing slash
  local g
  for g in ${IGNORE_GLOBS[@]+"${IGNORE_GLOBS[@]}"}; do
    # shellcheck disable=SC2254  # $g is a glob by design
    case "$1" in $g) return 0 ;; esac
    # shellcheck disable=SC2254
    case "$2" in $g) return 0 ;; esac
  done
  return 1
}

# Placeholder segments → `*`. `${…}` first so `${VAR:-x}` is one placeholder;
# `{a,b}` alternation (has a comma) is left alone.
to_pattern() {
  printf '%s\n' "$1" | LC_ALL=C sed -E \
    -e 's/\$\{[^{}]*\}/*/g' -e 's/\$[A-Za-z_][A-Za-z0-9_]*/*/g' \
    -e 's/\{[^{},\/]+\}/*/g' -e 's/<[^<>\/]+>/*/g' \
    -e 's/…/*/g' -e 's/\.\.\.+/*/g' -e 's/YYYY(-?MM(-?DD)?)?/*/g'
}

# Plain path: root, src/, or the git index (a tracked file or directory). A
# bare `name/` (no inner separator) is subtree-relative in running text — e.g.
# `lib/` right after `hooks/` — so a tracked `name/` at any depth resolves it.
path_resolves() {
  [ -e "$1" ] || [ -e "src/$1" ] && return 0
  git ls-files --error-unmatch -- "$1" >/dev/null 2>&1 && return 0
  case "$1" in */*) return 1 ;; esac
  [ -n "$(git ls-files -- "*/$1/*" 2>/dev/null)" ]
}

# Pattern: any match at root, under src/, or anywhere in the git index. A
# leading placeholder (`$ROOT/…`, `<repo>/…`) is an unknown root, so the rest
# is also tried from the repo root.
glob_resolves() {
  local pat="$1" alt="" m
  case "$pat" in '*/'*) alt="${pat#\*/}" ;; esac
  # Unquoted on purpose: these expand as globs (tokens never contain spaces).
  for m in $pat src/$pat ${alt:+$alt}; do [ -e "$m" ] && return 0; done
  [ -n "$(git ls-files -- "$pat" "*/$pat" ${alt:+"$alt"} 2>/dev/null)" ]
}

# Backtick spans per line as `<opted-out 0|1><TAB><token>`.
extract_tokens() {
  awk -v marker="$IGNORE_MARKER" '{
    ign = index($0, marker) ? 1 : 0
    s = $0
    while (match(s, /`[^`]+`/)) {
      print ign "\t" substr(s, RSTART + 1, RLENGTH - 2)
      s = substr(s, RSTART + RLENGTH)
    }
  }' "$1" 2>/dev/null | sort -u || true
}

# --- Check 1: path / directory claims (near-zero false positives) ------------
# Only path-like tokens INSIDE backtick code spans count (never prose), and a
# token is declared stale only after it fails to resolve at the root, under
# src/, AND in the git index. This avoids the broad-regex noise (prose slashes
# like `I/O`, npm scopes, subtree-relative paths) that buried real stale refs.
for file in "${EXISTING[@]}"; do
  while IFS=$'\t' read -r ign tok; do
    [ -z "$tok" ] && continue
    case "$tok" in *" "*|http*|ftp*|@*) continue ;; esac   # prose / URL / npm scope
    tok="${tok%%:*}"                                        # strip path:line / path:Symbol citation suffix
    echo "$tok" | grep -qE '/' || continue                 # must have a separator
    # path-like = known prefix OR dot-extension. A bare trailing-slash acronym
    # (REST/, SQS/) is prose, NOT a directory claim — excluded to keep FPs near zero.
    echo "$tok" | grep -qE '(^(src|apps|packages|libs|services|tests?|lib)/|\.[A-Za-z0-9]+$)' || continue
    p="${tok%/}"
    echo "$p" | grep -qE "$KNOWN_OPTIONAL" && continue    # known-optional: legitimately referenced-but-absent
    if [ "$ign" = 1 ] || opted_out "$tok" "$p"; then SKIPPED=$((SKIPPED + 1)); continue; fi
    case "$p" in
      *'<'*'>'*|*'{'*'}'*|*'$'*|*'...'*|*'…'*|*YYYY*) pat="$(to_pattern "$p")" ;;
      *) pat="$p" ;;
    esac
    case "$pat" in
      *'*'*|*'?'*)
        glob_resolves "$pat" && continue
        probe="${pat//\*/x}"; probe="${probe//\?/x}"
        what="looks like a path pattern but matches nothing" ;;
      *)
        path_resolves "$p" && continue
        probe="$p"
        what="looks like a path but resolves nowhere" ;;
    esac
    # Git-ignored = runtime/generated state (e.g. `.mtk/`), present only at run
    # time. The trailing slash is kept so directory-only ignore rules match.
    case "$tok" in */) probe="$probe/" ;; esac
    if git check-ignore -q -- "$probe" 2>/dev/null; then SKIPPED=$((SKIPPED + 1)); continue; fi
    echo "STALE in $file: '$tok' $what (root, src/, or git index)"
    STALE=$((STALE + 1))
  done < <(extract_tokens "$file")
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
if [ "$SKIPPED" -gt 0 ]; then
  echo "verify-references: skipped $SKIPPED git-ignored or opted-out reference(s)" >&2
fi
if [ "$STALE" -gt 0 ]; then
  echo "verify-references: $STALE stale reference(s) found" >&2
  exit 3
fi
echo "verify-references: no stale references found"
exit 0
