#!/usr/bin/env bash
set -euo pipefail

# check-guard-twins.sh — every mode-gated deny code has a deny AND an allow test.
#
# A hard deny that is only ever tested for denying drifts into blocking the
# innocent case too, and a guard that blocks innocent calls gets switched off.
# So every code passed as the 3rd argument to `mtk_deny_gated` in a hook must
# have, in tests/hooks/test-*.sh, at least one `expect` call whose label starts
# `deny:<code>` and at least one whose label starts `allow:<code>`.
#
# Only real calls count: the line must start (after indentation) with `expect`
# and the label must be its first argument. Comments, prose and near-miss
# codes (`allow:<code>-X`) do not count. A non-literal code (a variable) cannot
# be checked and is reported as a failure.
#
# Usage:  check-guard-twins.sh [--root DIR] [--quiet]
#   --root DIR  repository to check (default: this script's repository)
#   --quiet     print nothing on success
# Exit:   0 every code twinned (or no calls at all) · 1 missing twin(s), or 0
#         codes parsed while a hook still calls mtk_deny_gated · 2 usage error

usage() {
  printf 'usage: %s [--root DIR] [--quiet]\n' "$(basename "$0")" >&2
  exit 2
}

ROOT=""
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || usage; ROOT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) printf 'usage: %s [--root DIR] [--quiet]\n' "$(basename "$0")"; exit 0 ;;
    *) printf 'check-guard-twins: unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$ROOT/hooks" ] || { printf 'check-guard-twins: no hooks/ directory under %s\n' "$ROOT" >&2; exit 2; }

hook_files=()
for f in "$ROOT"/hooks/*.sh "$ROOT/hooks/session-start" "$ROOT/hooks/verify-completion"; do
  [ -f "$f" ] && hook_files+=("$f")
done
test_files=()
for f in "$ROOT"/tests/hooks/test-*.sh; do
  [ -f "$f" ] && test_files+=("$f")
done

# "<file>:<line>\t<code>" per mtk_deny_gated call. Backslash continuations are
# joined first, so a call split across lines still yields its 3rd argument.
# Comment lines and the function definition itself are skipped.
calls=""
if [ "${#hook_files[@]}" -gt 0 ]; then
  calls="$(awk -v root="$ROOT/" -v sq="'" '
    FNR == 1 { pending = ""; start = 0 }
    {
      line = $0
      if (pending != "") { line = pending " " line } else { start = FNR }
      if (line ~ /\\$/) { pending = substr(line, 1, length(line) - 1); next }
      pending = ""
      l = line
      sub(/^[[:space:]]+/, "", l)
      if (substr(l, 1, 1) == "#") next
      if (l ~ /mtk_deny_gated[[:space:]]*\(\)/) next
      while ((i = index(l, "mtk_deny_gated")) > 0) {
        rest = substr(l, i + length("mtk_deny_gated"))
        l = rest
        if (rest !~ /^[[:space:]]/) continue
        n = split(rest, f, /[[:space:]]+/)
        code = (n >= 4) ? f[4] : ""
        gsub("^[\"" sq "]+|[\"" sq ";]+$", "", code)
        name = FILENAME
        if (index(name, root) == 1) name = substr(name, length(root) + 1)
        printf "%s:%d\t%s\n", name, start, code
      }
    }
  ' "${hook_files[@]}")"
fi

# Parser self-check: zero parsed calls while a hook still names mtk_deny_gated
# means the parser missed every call, and "0 codes, all twinned" would be a
# silent pass. Count non-comment lines that name the function anywhere other
# than its definition (hooks/lib/hook-io.sh is not in the hook set).
if [ -z "$calls" ] && [ "${#hook_files[@]}" -gt 0 ]; then
  unparsed="$(awk '
    {
      l = $0
      sub(/^[[:space:]]+/, "", l)
      if (substr(l, 1, 1) == "#") next
      if (l ~ /mtk_deny_gated[[:space:]]*\(\)/) next
      if (l ~ /(^|[^A-Za-z0-9_])mtk_deny_gated([^A-Za-z0-9_]|$)/) n++
    }
    END { print n + 0 }
  ' "${hook_files[@]}")"
  if [ "$unparsed" -gt 0 ]; then
    printf 'check-guard-twins: parsed 0 codes but %d hook line(s) call mtk_deny_gated — the call parser missed them; fix the parser or the call shape\n' \
      "$unparsed" >&2
    exit 1
  fi
fi

# Every labelled expect call: "deny:<code>" / "allow:<code>", code taken greedily
# so a near-miss label never counts for a shorter code.
labels=""
if [ "${#test_files[@]}" -gt 0 ]; then
  labels="$(awk -v sq="'" '
    {
      l = $0
      sub(/^[[:space:]]+/, "", l)
      if (l !~ /^expect[[:space:]]/) next
      sub(/^expect[[:space:]]+/, "", l)
      c = substr(l, 1, 1)
      if (c == "\"" || c == sq) l = substr(l, 2)
      if (match(l, /^(deny|allow):[A-Za-z0-9_-]+/)) print substr(l, RSTART, RLENGTH)
    }
  ' "${test_files[@]}" | LC_ALL=C sort -u)"
fi

missing=0
ncodes=0
seen=""
while IFS=$'\t' read -r where code; do
  [ -n "$where" ] || continue
  case "$code" in
    [A-Z]*) case "$code" in *[!A-Z0-9_-]*) code="" ;; esac ;;
    *) code="" ;;
  esac
  if [ -z "$code" ]; then
    printf 'MISSING: %s passes a non-literal or malformed code to mtk_deny_gated — use an UPPER-CASE literal so its tests can be checked\n' "$where" >&2
    missing=$((missing + 1))
    continue
  fi
  case $'\n'"$seen"$'\n' in *$'\n'"$code"$'\n'*) continue ;; esac
  seen="${seen:+$seen$'\n'}$code"
  ncodes=$((ncodes + 1))
  for kind in deny allow; do
    if ! grep -qxF -- "$kind:$code" <<<"$labels"; then
      printf 'MISSING: %s twin for %s (%s) — add an `expect "%s:%s …"` case to tests/hooks/test-*.sh\n' \
        "$kind" "$code" "$where" "$kind" "$code" >&2
      missing=$((missing + 1))
    fi
  done
done <<<"$calls"

if [ "$missing" -gt 0 ]; then
  printf 'check-guard-twins: %d missing twin(s)\n' "$missing" >&2
  exit 1
fi
[ "$QUIET" -eq 1 ] || printf 'check-guard-twins: %d code(s), every one has deny and allow cases\n' "$ncodes"
exit 0
