#!/usr/bin/env bash
set -euo pipefail
# mtkignore.sh — shared loader for .mtkignore patterns.
#
# Public function:
#   mtk_load_ignore_patterns [--with-gitignore] <output_file>
#     Writes deduplicated, comment-stripped, blank-stripped patterns to
#     <output_file>, suitable for `find -X` / `grep -f` / similar consumers.
#     Sources, in precedence order:
#       1. .mtkignore (if present)
#       2. .gitignore (only when --with-gitignore is passed)
#       3. built-in defaults (always)
#
#     Built-in defaults: .git, node_modules, dist, bin, obj, .venv, venv,
#     __pycache__.
#
# Conventions:
#   - The loader resolves paths relative to $(git rev-parse --show-toplevel)
#     when available, else $PWD.
#   - Missing .mtkignore is non-fatal — silent fallback to defaults.

mtk_load_ignore_patterns() {
  local with_gitignore=0
  if [ "${1:-}" = "--with-gitignore" ]; then
    with_gitignore=1
    shift
  fi
  local out="${1:-}"
  if [ -z "$out" ]; then
    printf 'mtk_load_ignore_patterns: usage: [--with-gitignore] <output_file>\n' >&2
    return 2
  fi

  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

  : > "$out"

  if [ -f "$root/.mtkignore" ]; then
    grep -vE '^\s*(#|$)' "$root/.mtkignore" >> "$out" || true
  fi

  if [ "$with_gitignore" = "1" ] && [ -f "$root/.gitignore" ]; then
    grep -vE '^\s*(#|$)' "$root/.gitignore" >> "$out" || true
  fi

  cat >> "$out" <<'EOF'
.git/
node_modules/
dist/
bin/
obj/
.venv/
venv/
__pycache__/
EOF

  # Deduplicate while preserving order. Use awk for portability (no GNU-only flags).
  awk '!seen[$0]++' "$out" > "$out.dedup" && mv "$out.dedup" "$out"
}
