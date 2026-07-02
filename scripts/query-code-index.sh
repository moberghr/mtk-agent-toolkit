#!/usr/bin/env bash
set -euo pipefail

# query-code-index.sh — grep-friendly query companion for CODE_INDEX.md.
#
# CODE_INDEX.md (see .claude/references/code-index-template.md) is a static
# markdown capability table grouped by domain, with columns
# Capability / Entry point (`path/to/file:Symbol`) / Notes. This script is the
# structured text-query front door so prior-work-check and
# code-simplification --audit-duplicates stop grepping it ad hoc.
#
# It is NOT a semantic call-graph. `callers` is a TEXTUAL reference search only.
#
# Usage:
#   bash scripts/query-code-index.sh find <keyword> [--file <path>]
#       Case-insensitive search over CODE_INDEX.md table rows. Prints each
#       matching row prefixed with its enclosing "## <Domain>" section header:
#         [Domain] Capability -- path/to/file:Symbol -- Notes
#       --file <path> points at a CODE_INDEX.md elsewhere (default: CODE_INDEX.md
#       in the current working directory / repo root).
#
#   bash scripts/query-code-index.sh callers <symbol>
#       TEXTUAL reference search via `git grep -n` across the working tree
#       (respects .gitignore). Prints file:line: <matched line>. These are
#       textual matches, NOT verified call-sites — a semantic call-graph is out
#       of scope for this toolkit.
#
#   bash scripts/query-code-index.sh -h | --help
#       Print this usage.

usage() {
  grep '^# ' "$0" | head -33 | sed 's/^# \{0,1\}//'
}

cmd="${1:-}"
case "$cmd" in
  -h|--help|"")
    usage
    exit 0
    ;;
esac
shift

case "$cmd" in
  find)
    keyword=""
    file="CODE_INDEX.md"
    while [ $# -gt 0 ]; do
      case "$1" in
        --file)
          file="${2:-}"
          if [ -z "$file" ]; then
            echo "ERROR: --file requires a path argument" >&2
            exit 2
          fi
          shift 2
          ;;
        -h|--help)
          usage
          exit 0
          ;;
        *)
          if [ -z "$keyword" ]; then
            keyword="$1"
            shift
          else
            echo "ERROR: unexpected argument: $1" >&2
            exit 2
          fi
          ;;
      esac
    done

    if [ -z "$keyword" ]; then
      echo "ERROR: find requires a <keyword>" >&2
      echo "Usage: bash scripts/query-code-index.sh find <keyword> [--file <path>]" >&2
      exit 2
    fi
    if [ ! -f "$file" ]; then
      echo "ERROR: CODE_INDEX file not found: $file" >&2
      echo "(setup-bootstrap seeds CODE_INDEX.md at the repo root; pass --file to point elsewhere.)" >&2
      exit 1
    fi

    # Walk the file line by line, tracking the current "## <Domain>" section.
    # A table row is any line starting with "|" that is not the header
    # separator (|---|---|) and not the column-header row (Capability | ...).
    # Emit rows whose text matches <keyword> (case-insensitive), formatted as:
    #   [Domain] col1 -- col2 -- col3
    found=0
    section=""
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        '## '*)
          section="${line#'## '}"
          # Strip a trailing HTML comment (e.g. "<!-- EXAMPLE ... -->") and
          # trailing whitespace so the section label reads cleanly.
          section="${section%%<!--*}"
          section="$(printf '%s' "$section" | sed 's/[[:space:]]*$//')"
          ;;
        '|'*)
          # Skip separator rows like |---|---|---|
          case "$line" in
            *[!\|\ -:]*) : ;;  # has content beyond | - : space -> a real row
            *) continue ;;      # only separators -> skip
          esac
          # Skip the column-header row: match only when the FIRST cell is
          # literally "Capability" (case-insensitive), not any row whose text
          # happens to contain both words (e.g. a Notes cell mentioning them).
          first_cell="$(printf '%s' "$line" | sed 's/^[[:space:]]*|//' | awk -F'|' '{print $1}' \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
          case "$first_cell" in
            [Cc][Aa][Pp][Aa][Bb][Ii][Ll][Ii][Tt][Yy]) continue ;;
          esac
          if printf '%s' "$line" | grep -qiF -- "$keyword"; then
            # Split the markdown row into cells: strip leading/trailing pipe,
            # split on "|", trim each cell, join with " -- ".
            row="$(printf '%s' "$line" \
              | sed 's/^[[:space:]]*|//; s/|[[:space:]]*$//' \
              | awk -F'|' '{
                  out=""
                  for (i = 1; i <= NF; i++) {
                    cell=$i
                    gsub(/^[ \t]+/, "", cell)
                    gsub(/[ \t]+$/, "", cell)
                    if (i > 1) out = out " -- "
                    out = out cell
                  }
                  print out
                }')"
            printf '[%s] %s\n' "$section" "$row"
            found=1
          fi
          ;;
      esac
    done < "$file"

    if [ "$found" -eq 0 ]; then
      echo "No CODE_INDEX rows matched: $keyword" >&2
      exit 1
    fi
    ;;

  callers)
    symbol="${1:-}"
    if [ -z "$symbol" ]; then
      echo "ERROR: callers requires a <symbol>" >&2
      echo "Usage: bash scripts/query-code-index.sh callers <symbol>" >&2
      exit 2
    fi
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "ERROR: callers must run inside a git working tree" >&2
      exit 2
    fi
    # TEXTUAL reference search only — NOT a semantic call-graph. git grep
    # respects .gitignore and works from anywhere inside the repo.
    # git grep exits 1 specifically for "no matches" — a real tool error
    # (bad invocation, corrupted repo state, git failure) exits >=2 and must
    # be reported distinctly, not conflated with a clean empty result.
    set +e
    git grep -n -F -- "$symbol"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      :
    elif [ "$rc" -eq 1 ]; then
      echo "No textual references found for: $symbol" >&2
      exit 1
    else
      echo "ERROR: git grep failed (exit $rc) — this is a tool error, not \"no matches\"" >&2
      exit "$rc"
    fi
    ;;

  *)
    echo "ERROR: unknown subcommand: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
