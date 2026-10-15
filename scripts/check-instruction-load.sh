#!/usr/bin/env bash
set -euo pipefail

# check-instruction-load.sh — find instruction files that a harness silently
# drops, truncates or ignores. Every check is a fact about how a harness LOADS
# the file, not about what the file says (that is verify-references /
# verify-commands / the instructions audit).
#
# Codes (one finding per line in text mode: `<CODE> <path>: <detail>`):
#   CODEX-BYTES      For each directory holding an AGENTS.md (or
#                    AGENTS.override.md), the root -> that-dir chain Codex
#                    concatenates (AGENTS.override.md preferred over AGENTS.md
#                    at each level) exceeds MTK_CODEX_DOC_MAX_BYTES (default
#                    32768). Codex truncates past the limit without saying so.
#   SHADOWED-AGENTS  A root AGENTS.md exists but resolve-constitution.sh
#                    --loaded resolves to CLAUDE.md: Claude Code's default mode
#                    reads CLAUDE.md and never AGENTS.md. The resolver owns the
#                    rule (shim = a bare `@AGENTS.md` line); it is not restated.
#   GLOBS-NOT-PATHS  A .claude/rules/**/*.md whose frontmatter has `globs:` and
#                    no `paths:` — `globs:` is the Cursor key; Claude Code
#                    ignores it and loads the rule never (or always).
#   LOCAL-UNIGNORED  CLAUDE.local.md exists and `git check-ignore` says it is
#                    not ignored, so personal notes are one `git add .` from
#                    being committed. Skipped outside a git repo.
#
# Skipped directories: .git, node_modules, .mtk, .claude/worktrees, and any
# nested directory holding its own `.git` entry (another worktree, submodule or
# checkout — its instruction chain is its own).
#
# Usage:
#   bash scripts/check-instruction-load.sh [--json] [--root DIR]
#   --json      print a JSON array of {code, path, detail} instead of lines
#   --root DIR  repo to check (default: git top level of $PWD, else $PWD)
#
# Exit: 0 clean · 1 findings · 2 usage / bad env / resolver missing, or a
#       sub-check could not run and nothing was found. Each sub-check that could
#       not run prints one `check-instruction-load: <reason>; <CODE> not
#       checked` line on stderr — with findings too (the exit then stays 1).
# Paths are relative to the root. No deps beyond coreutils/find/awk/git (S3.3).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() { sed -n '3,39p' "$0" | sed 's/^# \{0,1\}//'; }

json=0
root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json=1; shift ;;
    --root)
      [ $# -ge 2 ] || { echo "check-instruction-load: --root needs a directory" >&2; exit 2; }
      root="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "check-instruction-load: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$root" ]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
[ -d "$root" ] || { echo "check-instruction-load: not a directory: $root" >&2; exit 2; }
root="$(cd "$root" && pwd)"

max_bytes="${MTK_CODEX_DOC_MAX_BYTES:-32768}"
case "$max_bytes" in
  ''|*[!0-9]*) echo "check-instruction-load: MTK_CODEX_DOC_MAX_BYTES must be a positive integer (got '$max_bytes')" >&2; exit 2 ;;
esac
[ "$max_bytes" -gt 0 ] || { echo "check-instruction-load: MTK_CODEX_DOC_MAX_BYTES must be > 0" >&2; exit 2; }

resolver="$SCRIPT_DIR/resolve-constitution.sh"
[ -f "$resolver" ] || resolver="${CLAUDE_PLUGIN_ROOT:-}/scripts/resolve-constitution.sh"
[ -f "$resolver" ] || { echo "check-instruction-load: resolve-constitution.sh not found next to this script or under CLAUDE_PLUGIN_ROOT" >&2; exit 2; }

F_CODE=(); F_PATH=(); F_DETAIL=()
add() { F_CODE+=("$1"); F_PATH+=("$2"); F_DETAIL+=("$3"); }
unchecked=0
not_checked() { # $1 = code, $2 = reason — one stderr line; the run can no longer exit 0
  echo "check-instruction-load: $2; $1 not checked" >&2
  unchecked=$((unchecked + 1))
}

# --- CODEX-BYTES ------------------------------------------------------------
# Candidate directories: every dir (relative, `.` = root) holding an AGENTS.md
# or AGENTS.override.md, minus pruned trees.
# An unreadable subtree makes find exit non-zero; that must not abort the scan.
cand_dirs="$(cd "$root" && { find . \
  \( -name .git -o -name node_modules -o -name .mtk -o -path ./.claude/worktrees \) -prune \
  -o -type f \( -name AGENTS.md -o -name AGENTS.override.md \) -print 2>/dev/null || true; } \
  | sed 's|/[^/]*$||' | sort -u)"

# The file Codex reads at one level: override first, else AGENTS.md, else none.
level_file() { # $1 = dir relative to root ("." for root)
  if [ -f "$root/$1/AGENTS.override.md" ]; then printf '%s' "$1/AGENTS.override.md"
  elif [ -f "$root/$1/AGENTS.md" ]; then printf '%s' "$1/AGENTS.md"
  fi
}

while IFS= read -r d; do
  [ -n "$d" ] || continue
  rel="${d#./}"; [ "$d" = "." ] && rel=""
  # Levels root -> d. A nested `.git` entry on the way means another checkout.
  levels=(".")
  nested=0
  if [ -n "$rel" ]; then
    acc="."
    IFS='/' read -r -a parts <<<"$rel"
    for p in "${parts[@]}"; do
      acc="$acc/$p"
      if [ -e "$root/$acc/.git" ]; then nested=1; break; fi
      levels+=("$acc")
    done
  fi
  [ "$nested" -eq 0 ] || continue
  total=0; chain=""; last=""
  for lv in "${levels[@]}"; do
    f="$(level_file "$lv")"
    [ -n "$f" ] || continue
    b="$(wc -c <"$root/$f" | tr -d ' ')"
    total=$((total + b))
    f="${f#./}"; last="$f"
    chain="${chain:+$chain + }$f"
  done
  [ -n "$last" ] || continue
  if [ "$total" -gt "$max_bytes" ]; then
    add CODEX-BYTES "$last" "chain $chain is $total bytes, over the $max_bytes-byte limit (MTK_CODEX_DOC_MAX_BYTES); Codex truncates the rest silently"
  fi
done <<<"$cand_dirs"

# --- SHADOWED-AGENTS --------------------------------------------------------
# --loaded answers "which file does Claude Code actually read" — the question
# this check asks. Canonical mode would also flag a generator-marked AGENTS.md
# in a repo with no CLAUDE.md at all, which loads fine.
if [ -f "$root/AGENTS.md" ]; then
  loaded_rc=0
  loaded="$(bash "$resolver" --loaded "$root" 2>/dev/null)" || loaded_rc=$?
  if [ "$loaded_rc" -ne 0 ]; then
    not_checked SHADOWED-AGENTS "resolve-constitution.sh --loaded failed (exit $loaded_rc)"
  elif [ "$loaded" = "$root/CLAUDE.md" ]; then
    add SHADOWED-AGENTS "AGENTS.md" "CLAUDE.md exists and does not import it with a bare @AGENTS.md line, so Claude Code's default mode reads CLAUDE.md and never AGENTS.md"
  fi
fi

# --- GLOBS-NOT-PATHS --------------------------------------------------------
if [ -d "$root/.claude/rules" ]; then
  rule_files="$(cd "$root" && { find .claude/rules -type f -name '*.md' 2>/dev/null || true; } | sort)"
  while IFS= read -r rf; do
    [ -n "$rf" ] || continue
    keys="$(awk '
      NR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit; next }
      /^---[[:space:]]*$/ { exit }
      /^globs:/ { g = 1 }
      /^paths:/ { p = 1 }
      END { printf "%d %d", g, p }
    ' "$root/$rf")"
    if [ "$keys" = "1 0" ]; then
      add GLOBS-NOT-PATHS "$rf" "frontmatter has globs: (the Cursor key) and no paths:, so Claude Code ignores the path scope; rename the key to paths:"
    fi
  done <<<"$rule_files"
fi

# --- LOCAL-UNIGNORED --------------------------------------------------------
if [ -f "$root/CLAUDE.local.md" ] && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  rc=0
  git -C "$root" check-ignore -q CLAUDE.local.md 2>/dev/null || rc=$?
  if [ "$rc" -eq 1 ]; then
    add LOCAL-UNIGNORED "CLAUDE.local.md" "personal instruction file is not git-ignored (or is tracked); add CLAUDE.local.md to .gitignore"
  elif [ "$rc" -ne 0 ]; then
    not_checked LOCAL-UNIGNORED "git check-ignore failed (exit $rc)"
  fi
fi

# --- Output -------------------------------------------------------------------
n="${#F_CODE[@]}"

json_str() { # escape \ " and control chars for a JSON string body
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

if [ "$json" -eq 1 ]; then
  printf '['
  i=0
  while [ "$i" -lt "$n" ]; do
    [ "$i" -gt 0 ] && printf ','
    printf '{"code":"%s","path":"%s","detail":"%s"}' \
      "$(json_str "${F_CODE[$i]}")" "$(json_str "${F_PATH[$i]}")" "$(json_str "${F_DETAIL[$i]}")"
    i=$((i + 1))
  done
  printf ']\n'
else
  i=0
  while [ "$i" -lt "$n" ]; do
    printf '%s %s: %s\n' "${F_CODE[$i]}" "${F_PATH[$i]}" "${F_DETAIL[$i]}"
    i=$((i + 1))
  done
fi

[ "$n" -gt 0 ] && exit 1
[ "$unchecked" -gt 0 ] && exit 2
exit 0
