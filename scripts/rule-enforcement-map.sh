#!/usr/bin/env bash
set -euo pipefail

# rule-enforcement-map.sh — which rules are load-bearing, and which are hope?
#
# Classifies every numbered rule in .claude/rules/*.md and CLAUDE.md's
# Critical Rules by whether something actually enforces it:
#   WIRED   names an enforcer (hooks/x.sh, scripts/y.sh) that exists — and,
#           for hooks, is wired in hooks/hooks.json or .claude/settings.json
#   BROKEN  names an enforcer that does not exist, or a hook that exists but
#           is wired nowhere — the rule reads as enforced and is not
#   PROSE   names no enforcer — advisory by design or by omission (this is
#           not a failure; it is the honest label)
#
# Reverse check: every hook in hooks/*.sh should be mentioned by some rule or
# CLAUDE.md — an enforcer nothing documents is governance drift from the
# other side ("it works, and nothing says why").
#
# WARN-only: exit 0 always, --strict exits 1 on any BROKEN. A verdict tool
# that fails builds on PROSE would train people to delete rules, not wire them.
#
# Usage: bash scripts/rule-enforcement-map.sh [--strict] [--quiet]

ROOT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT_DIR"

STRICT=0
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    --quiet)  QUIET=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

wired=0; broken=0; prose=0
BROKEN_LIST=""

# Emit "<id>\t<rule text block>" per rule: the bold-id bullet plus its
# continuation lines up to the next bullet/heading.
extract_rules() { # $1 = file
  awk '
    /^- \*\*[SC][0-9]+\.[0-9]+[a-z]?\*\*/ {
      if (id != "") printf "%s\t%s\n", id, text
      id = $0; sub(/^- \*\*/, "", id); sub(/\*\*.*/, "", id)
      text = $0
      next
    }
    /^(- \*\*|#|\|)/ { if (id != "") { printf "%s\t%s\n", id, text; id = "" } next }
    { if (id != "") { gsub(/\t/, " "); text = text " " $0 } }
    END { if (id != "") printf "%s\t%s\n", id, text }
  ' "$1"
}

# All enforcer-shaped references in a text: hook/script filenames, with or
# without their directory prefix.
enforcers_in() { # $1 = text
  # awk, not grep -o: the token needs a real right boundary so
  # `checksums.sha256` never false-matches as `checksums.sh` (BSD grep's \b
  # support is unreliable). No-match is a PROSE verdict, not an error.
  printf '%s\n' "$1" | awk '
    {
      s = $0
      while (match(s, /(hooks\/(lib\/)?|scripts\/)?[a-z][a-z0-9-]+\.(sh|py)/)) {
        tok = substr(s, RSTART, RLENGTH)
        nxt = substr(s, RSTART + RLENGTH, 1)
        if (nxt !~ /[a-zA-Z0-9.]/) print tok
        s = substr(s, RSTART + RLENGTH)
      }
    }' | sort -u
}

hook_is_wired() { # $1 = basename
  grep -qF "hooks/$1" hooks/hooks.json 2>/dev/null && return 0
  grep -qF "hooks/$1" .claude/settings.json 2>/dev/null && return 0
  return 1
}

classify_rule() { # $1 = id, $2 = text, $3 = source file
  local id="$1" text="$2" src="$3"
  local refs found_live=0 found_broken=0 broken_ref=""
  refs="$(enforcers_in "$text")"
  if [ -z "$refs" ]; then
    prose=$((prose + 1))
    [ "$QUIET" -eq 1 ] || printf '  PROSE   %-7s (%s) — no named enforcer\n' "$id" "$src"
    return 0
  fi
  local ref base
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    base="${ref##*/}"
    # Resolve: explicit path, else probe hooks/ and scripts/.
    local resolved=""
    if [ -f "$ref" ]; then resolved="$ref"
    elif [ -f "hooks/$base" ]; then resolved="hooks/$base"
    elif [ -f "hooks/lib/$base" ]; then resolved="hooks/lib/$base"
    elif [ -f "scripts/$base" ]; then resolved="scripts/$base"
    fi
    if [ -z "$resolved" ]; then
      found_broken=1; broken_ref="$ref (file missing)"
      continue
    fi
    case "$resolved" in
      hooks/lib/*) found_live=1 ;;  # shared lib — sourced, not wired
      hooks/*)
        if hook_is_wired "$base"; then found_live=1
        else found_broken=1; broken_ref="$resolved (exists but wired nowhere)"; fi
        ;;
      *) found_live=1 ;;
    esac
  done <<EOF
$refs
EOF
  if [ "$found_broken" -eq 1 ] && [ "$found_live" -eq 0 ]; then
    broken=$((broken + 1))
    BROKEN_LIST="${BROKEN_LIST}  ${id} (${src}): ${broken_ref}"$'\n'
    [ "$QUIET" -eq 1 ] || printf '  BROKEN  %-7s (%s) — %s\n' "$id" "$src" "$broken_ref"
  else
    wired=$((wired + 1))
    if [ "$found_broken" -eq 1 ]; then
      # partially broken: live enforcer exists, but a named sibling is dead
      BROKEN_LIST="${BROKEN_LIST}  ${id} (${src}): stale ref ${broken_ref} (rule still wired elsewhere)"$'\n'
      broken=$((broken + 1))
      [ "$QUIET" -eq 1 ] || printf '  WIRED*  %-7s (%s) — live enforcer + stale ref: %s\n' "$id" "$src" "$broken_ref"
    else
      [ "$QUIET" -eq 1 ] || printf '  WIRED   %-7s (%s)\n' "$id" "$src"
    fi
  fi
}

for f in .claude/rules/*.md CLAUDE.md; do
  [ -f "$f" ] || continue
  case "$f" in *INDEX.md) continue ;; esac
  while IFS="$(printf '\t')" read -r id text; do
    [ -n "$id" ] || continue
    classify_rule "$id" "$text" "$f"
  done < <(extract_rules "$f")
done

# Reverse check: enforcers nothing documents.
undocumented=0
UNDOC_LIST=""
for h in hooks/*.sh; do
  [ -f "$h" ] || continue
  base="${h##*/}"
  # Stem match, hyphenated or spaced: rules legitimately name hooks without
  # the .sh suffix ("the scope-guard hard deny") or in prose ("the security
  # gate") — both count as documentation.
  stem="${base%.sh}"
  spaced="$(printf '%s' "$stem" | tr '-' ' ')"
  if ! grep -rqiF "$stem" .claude/rules/ CLAUDE.md 2>/dev/null \
     && ! grep -rqiF "$spaced" .claude/rules/ CLAUDE.md 2>/dev/null; then
    undocumented=$((undocumented + 1))
    UNDOC_LIST="${UNDOC_LIST}  ${h}"$'\n'
    [ "$QUIET" -eq 1 ] || printf '  UNDOC   %s — enforces behavior no rule documents\n' "$h"
  fi
done

echo "rule-enforcement-map: $wired wired, $broken broken ref(s), $prose prose, $undocumented undocumented hook(s)"
if [ "$STRICT" -eq 1 ] && { [ "$broken" -gt 0 ] || [ "$undocumented" -gt 0 ]; }; then
  exit 1
fi
exit 0
