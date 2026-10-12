#!/usr/bin/env bash
set -euo pipefail
# shrink-guard.sh — refuse silent truncation of protected artifacts.
#
# Pattern borrowed from graphify's to_json() shrink-refusal: a bug in a
# regenerator (audit, references index, lessons append) can silently overwrite
# a 200-line file with 5 lines and the data is gone. This guard makes that loud.
#
# Public function:
#   mtk_guarded_write <target_path> <new_content_path>
#     Atomically replaces target with new content, but ONLY if the new content
#     is not a suspicious shrink. Prints a clear stderr refusal otherwise.
#
# Thresholds:
#   - Bytes:  new must be >= 50% of existing
#   - Lines:  new must be >= 80% of existing
# Either threshold violation refuses the write.
#
# Override:
#   MTK_SHRINK_GUARD_OVERRIDE=1  bypasses the guard for one write and emits
#                                a stderr warning naming the target.
#
# Exit codes:
#   0  write succeeded (or override applied)
#   1  refused (shrink threshold violated)
#   2  usage error (missing args, source path unreadable)

mtk_guarded_write() {
  local target="${1:-}"
  local source="${2:-}"

  if [ -z "$target" ] || [ -z "$source" ]; then
    printf 'mtk-shrink-guard: usage: mtk_guarded_write <target> <new_content_path>\n' >&2
    return 2
  fi

  if [ ! -r "$source" ]; then
    printf 'mtk-shrink-guard: source not readable: %s\n' "$source" >&2
    return 2
  fi

  # New target — never blocks creation.
  if [ ! -e "$target" ]; then
    mv "$source" "$target"
    return 0
  fi

  local old_bytes new_bytes old_lines new_lines
  old_bytes=$(wc -c < "$target" 2>/dev/null | tr -d ' ')
  new_bytes=$(wc -c < "$source" 2>/dev/null | tr -d ' ')
  old_lines=$(wc -l < "$target" 2>/dev/null | tr -d ' ')
  new_lines=$(wc -l < "$source" 2>/dev/null | tr -d ' ')

  old_bytes=${old_bytes:-0}
  new_bytes=${new_bytes:-0}
  old_lines=${old_lines:-0}
  new_lines=${new_lines:-0}

  # Empty existing target — anything is fine.
  if [ "$old_bytes" -eq 0 ] && [ "$old_lines" -eq 0 ]; then
    mv "$source" "$target"
    return 0
  fi

  # Threshold check uses integer math (POSIX).
  # bytes: refuse if new_bytes * 2 < old_bytes  (i.e., new < 50%)
  # lines: refuse if new_lines * 5 < old_lines * 4  (i.e., new < 80%)
  local bytes_violated=0 lines_violated=0
  if [ $((new_bytes * 2)) -lt "$old_bytes" ]; then
    bytes_violated=1
  fi
  if [ $((new_lines * 5)) -lt $((old_lines * 4)) ]; then
    lines_violated=1
  fi

  if [ "$bytes_violated" -eq 0 ] && [ "$lines_violated" -eq 0 ]; then
    mv "$source" "$target"
    return 0
  fi

  if [ "${MTK_SHRINK_GUARD_OVERRIDE:-0}" = "1" ]; then
    printf 'mtk-shrink-guard: WARNING — overriding shrink refusal for %s (bytes %s→%s, lines %s→%s)\n' \
      "$target" "$old_bytes" "$new_bytes" "$old_lines" "$new_lines" >&2
    mv "$source" "$target"
    return 0
  fi

  printf 'mtk-shrink-guard: refusing to shrink %s (bytes %s→%s, lines %s→%s). Set MTK_SHRINK_GUARD_OVERRIDE=1 to bypass.\n' \
    "$target" "$old_bytes" "$new_bytes" "$old_lines" "$new_lines" >&2
  rm -f "$source"
  return 1
}
