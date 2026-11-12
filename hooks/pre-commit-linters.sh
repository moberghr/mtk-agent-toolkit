#!/usr/bin/env bash
#
# Pre-commit deterministic lint pass. Emits findings in the review-finding
# schema shape (see .claude/references/review-finding-schema.md) with
# source: "linter" and confidence: 100. Feeds into the AI review pass;
# does not replace it.

set -euo pipefail

# Resolve the script's real location (following symlinks) so pattern packs load
# from the plugin checkout even when this script is invoked via a symlinked git
# hook installed in a target repo. The diff, by contrast, runs against the
# current working directory (the invoking repo) — we deliberately do NOT cd.
mtk_realpath() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; sys.stdout.reconfigure(newline="\n"); print(os.path.realpath(sys.argv[1]))' "$1"
    return
  fi
  # Fallback: resolve symlinks manually (no readlink -f on stock macOS).
  local p="$1" target
  while [ -L "$p" ]; do
    target="$(readlink "$p")"
    case "$target" in
      /*) p="$target" ;;
      *)  p="$(cd "$(dirname "$p")" && pwd)/$target" ;;
    esac
  done
  printf '%s/%s\n' "$(cd "$(dirname "$p")" && pwd)" "$(basename "$p")"
}

SELF="$(mtk_realpath "$0")"
SCRIPT_ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"

PATTERNS_DIR="$SCRIPT_ROOT/hooks/linter-patterns"

# --- File classification -------------------------------------------------
# Code-shaped rules (raw-SQL interpolation, float money, console logging) are
# about what the program DOES. A documentation page that quotes a vulnerable
# line is describing it, not executing it — flagging that blocks a commit and
# pressures the author into paraphrasing the doc into something less accurate.
# Classify each changed file once, and let each pattern pack declare which
# class it applies to (see mtk_pack_scope below).
mtk_path_class() {
  local ext="${1##*/}"
  case "$ext" in
    *.*) ext="$(printf '%s' "${ext##*.}" | tr '[:upper:]' '[:lower:]')" ;;
    *)   ext="" ;;
  esac
  case "$ext" in
    md|mdx|markdown|rst|adoc|asciidoc|txt) printf 'prose\n' ;;
    *)                                     printf 'code\n' ;;
  esac
}

# A pack declares its scope with a header directive:
#   # scope: code   — skip prose files (default for stack/domain packs)
#   # scope: prose  — skip code files
#   # scope: all    — scan everything (secrets, docdrift)
# Packs with no directive default to `all`, so pre-existing and project-local
# packs keep their current behavior.
mtk_pack_scope() {
  local declared
  declared="$(sed -n 's/^#[[:space:]]*scope:[[:space:]]*\([a-z]*\).*/\1/p' "$1" | head -1)"
  case "$declared" in
    code|prose|all) printf '%s\n' "$declared" ;;
    *)              printf 'all\n' ;;
  esac
}

# --- Options ---
DIFF_SOURCE="cached"          # cached | head | range
DIFF_RANGE=""                 # git range expression when DIFF_SOURCE=range
STACK=""                      # auto-detect if empty
OUTPUT="json"                 # json | human

while [ $# -gt 0 ]; do
  case "$1" in
    --cached)  DIFF_SOURCE="cached"; shift ;;
    --head)    DIFF_SOURCE="head"; shift ;;
    --range)   DIFF_SOURCE="range"; DIFF_RANGE="${2:-}"; shift 2 ;;
    --stack)   STACK="${2:-}"; shift 2 ;;
    --human)   OUTPUT="human"; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: hooks/pre-commit-linters.sh [--cached | --head | --range <expr>] [--stack <name>] [--human]

Scans staged changes (--cached, default), HEAD changes (--head), or a git range
(--range base...HEAD) with deterministic patterns. The diff runs against the
current working directory; pattern packs load from the plugin checkout. Emits
JSON findings on stdout.

--cached      Scan staged changes (default)
--head        Scan working-tree changes vs HEAD
--range <e>   Scan the given git diff range (e.g. origin/main...HEAD)
--stack       Override tech stack detection (default resolves polyglot-aware via
              scripts/resolve-tech-stack.sh: subproject .claude/tech-stack, then
              root .claude/tech-stack.map, then root .claude/tech-stack)
--human       Human-readable output instead of JSON
EOF
      exit 0
      ;;
    *) printf 'Unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

if [ "$DIFF_SOURCE" = "range" ] && [ -z "$DIFF_RANGE" ]; then
  printf '%s\n' "--range requires a range expression (e.g. origin/main...HEAD)" >&2
  exit 1
fi

# --- Stack detection ---
# An explicit --stack always wins. Otherwise resolve polyglot-aware (subproject
# `.claude/tech-stack` → root `tech-stack.map` glob → root file) so a subtree
# with its own stack gets its own linter packs instead of the root's.
if [ -z "$STACK" ]; then
  _RTS="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/scripts/resolve-tech-stack.sh"
  [ -f "$_RTS" ] || _RTS="${CLAUDE_PLUGIN_ROOT:-.}/scripts/resolve-tech-stack.sh"
  if [ -f "$_RTS" ]; then
    STACK="$(bash "$_RTS" "$PWD" 2>/dev/null || true)"
  elif [ -f .claude/tech-stack ]; then
    STACK="$(tr -d '[:space:]' < .claude/tech-stack)"
  fi
fi

# --- Build pattern list from composable packs ---
# Pack discovery order: core/ → stack-{name}/ → domain-{name}/ → project/
# Falls back to flat files for backward compatibility with pre-6.2 layouts.
PATTERN_FILES=()

# Core packs (always active)
if [ -d "$PATTERNS_DIR/core" ]; then
  for f in "$PATTERNS_DIR"/core/*.txt; do
    [ -f "$f" ] && PATTERN_FILES+=("$f")
  done
else
  # Flat-file fallback (pre-6.2 layout)
  [ -f "$PATTERNS_DIR/shared.txt" ] && PATTERN_FILES+=("$PATTERNS_DIR/shared.txt")
  [ -f "$PATTERNS_DIR/slopwatch.txt" ] && PATTERN_FILES+=("$PATTERNS_DIR/slopwatch.txt")
fi

# Stack pack
if [ -n "$STACK" ]; then
  if [ -d "$PATTERNS_DIR/stack-$STACK" ]; then
    for f in "$PATTERNS_DIR"/stack-"$STACK"/*.txt; do
      [ -f "$f" ] && PATTERN_FILES+=("$f")
    done
  elif [ -f "$PATTERNS_DIR/$STACK.txt" ]; then
    # Flat-file fallback (pre-6.2 layout)
    PATTERN_FILES+=("$PATTERNS_DIR/$STACK.txt")
  fi
fi

# Domain packs (activated by the invoking repo's .claude/domains — one per line)
DOMAINS_FILE=".claude/domains"
if [ -f "$DOMAINS_FILE" ]; then
  while IFS= read -r domain || [ -n "$domain" ]; do
    domain="$(echo "$domain" | tr -d '[:space:]')"
    [ -z "$domain" ] && continue
    [[ "$domain" == \#* ]] && continue
    if [ -d "$PATTERNS_DIR/domain-$domain" ]; then
      for f in "$PATTERNS_DIR"/domain-"$domain"/*.txt; do
        [ -f "$f" ] && PATTERN_FILES+=("$f")
      done
    fi
  done < "$DOMAINS_FILE"
fi

# Project-local packs (gitignored, project-specific patterns)
if [ -d "$PATTERNS_DIR/project" ]; then
  for f in "$PATTERNS_DIR"/project/*.txt; do
    [ -f "$f" ] && PATTERN_FILES+=("$f")
  done
fi

# --- Get diff (runs against the current working directory / invoking repo) ---
# core.quotepath=off: by default git C-quotes any path with a non-ASCII byte
# (`+++ "b/\303\234ber.cs"`), which the header match below would miss, so a
# staged Über.cs went unscanned or had its findings pinned on the previous file.
case "$DIFF_SOURCE" in
  cached) DIFF_CMD=(git -c core.quotepath=off diff --cached -U0 --no-color) ;;
  range)  DIFF_CMD=(git -c core.quotepath=off diff "$DIFF_RANGE" -U0 --no-color) ;;
  *)      DIFF_CMD=(git -c core.quotepath=off diff HEAD -U0 --no-color) ;;
esac

# --- Extract file:line:content for added lines ---
# awk walks the unified diff. Hunk header @@ -a,b +c,d @@ gives new-side
# starting line c. We increment for each +line and each context-but-we-skip
# line (but -U0 means zero context; only +, -, and @@ lines appear).
# The `+++` file header is read only between `diff --git` and the first hunk;
# inside a hunk every `+` line is an added line, so one whose text starts with
# "++ " (shown as `+++ …`) is scanned and counted, never taken for a header, and
# an empty added line still advances the line number. Git ends that header with
# a tab when the name has a space, and still C-quotes a name holding `"`, `\` or
# a control character even with quotepath off; both are undone here.
#
# Record: <file>\t<line>\t<content>, where <file> is ALREADY JSON-escaped
# (jesc below, total: `\`, `"` and every control byte). A tab or newline from a
# file name therefore never reaches the tab/newline-separated record stream —
# unquoted raw, `tab<TAB>name.cs` split into file `tab`, line `name.cs`, and the
# emitted JSON failed to parse. The escaping adds no `/` or `.` and every escape
# holds a backslash, so mtk_path_class reads the same basename and extension on
# the escaped name as on the real one. LC_ALL=C: bytes in, the same bytes out
# (sprintf("%c") of a control code is one byte; names stay byte-exact).
added_lines() {
  "${DIFF_CMD[@]}" | LC_ALL=C awk '
    BEGIN {
      # git C-quote escapes; octal \ooo covers every other control byte.
      Q["a"] = sprintf("%c", 7); Q["b"] = sprintf("%c", 8); Q["t"] = "\t"
      Q["n"] = "\n"; Q["v"] = sprintf("%c", 11); Q["f"] = sprintf("%c", 12)
      Q["r"] = "\r"; Q["\""] = "\""; Q["\\"] = "\\"
      # JSON escapes: backslash, quote, and every control byte (and DEL).
      for (i = 1; i < 32; i++) J[sprintf("%c", i)] = sprintf("\\u%04x", i)
      J[sprintf("%c", 127)] = "\\u007f"
      J["\t"] = "\\t"; J["\n"] = "\\n"; J["\r"] = "\\r"
      J["\""] = "\\\""; J["\\"] = "\\\\"
    }
    function unquote(s,   out, i, c, n) {
      s = substr(s, 2, length(s) - 2)
      out = ""
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\" && i < n) {
          i++
          c = substr(s, i, 1)
          if (c ~ /[0-7]/ && i + 2 <= n) { c = sprintf("%c", (c * 64) + (substr(s, i + 1, 1) * 8) + substr(s, i + 2, 1)); i += 2 }
          else if (c in Q) c = Q[c]
        }
        out = out c
      }
      return out
    }
    function jesc(s,   out, i, c, n) {
      out = ""
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        out = out ((c in J) ? J[c] : c)
      }
      return out
    }
    /^diff --git / { in_hdr = 1; next }
    in_hdr && /^\+\+\+ / {
      f = substr($0, 5)
      sub(/\t$/, "", f)
      if (f == "/dev/null") { file = ""; next }
      if (substr(f, 1, 1) == "\"") f = unquote(f)
      file = jesc((substr(f, 1, 2) == "b/") ? substr(f, 3) : f)
      next
    }
    /^@@ / {
      in_hdr = 0
      # Parse +c,d — the part after the space-plus
      if (match($0, /\+[0-9]+/)) {
        line = substr($0, RSTART+1, RLENGTH-1) + 0 - 1
      } else { line = 0 }
      next
    }
    !in_hdr && /^\+/ {
      line++
      # Strip the leading +; an empty added line is counted but not emitted.
      content = substr($0, 2)
      if (file != "" && content != "") {
        # Skip binary markers
        if (content !~ /^Binary files /) {
          printf "%s\t%d\t%s\n", file, line, content
        }
      }
      next
    }
  '
}

# JSON string body for $1 (no surrounding quotes), escaped totally: `\`, `"`
# and every control character — a raw TAB or CR inside a JSON string makes the
# whole report unparseable. Parameter expansion only; the control-character
# pass runs only when one is present.
mtk_json_str() {
  local s="${1:-}" o c u
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  case "$s" in *[[:cntrl:]]*) ;; *) printf '%s' "$s"; return 0 ;; esac
  s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"
  for o in 001 002 003 004 005 006 007 010 013 014 016 017 020 021 022 023 \
    024 025 026 027 030 031 032 033 034 035 036 037 177; do
    printf -v c '%b' "\\0$o"
    case "$s" in
      # Pattern and replacement stay unquoted: bash 3.2 keeps nested quotes
      # literally, and $u (\u00XX) has no glob character or `&`, so bash 5.2's
      # patsub_replacement leaves it alone.
      *"$c"*) printf -v u '\\u%04x' "$((8#$o))"; s="${s//$c/$u}" ;;
    esac
  done
  printf '%s' "$s"
}

# --- Scan added lines against patterns ---
# Each pattern file line: RULE_ID|severity|regex|rationale|suggested_fix
finding_index=0
findings=()

scan() {
  local rule_id="$1" severity="$2" regex="$3" rationale="$4" fix="$5"
  # Use grep -E (ERE) against the tab-separated added-lines output
  # Field 3 is content; grep runs against the whole line but we match on
  # content boundaries by design.
  while IFS=$'\t' read -r file line content; do
    if printf '%s' "$content" | grep -qEi -- "$regex"; then
      finding_index=$((finding_index + 1))
      local fid
      fid=$(printf 'L%03d' "$finding_index")
      # JSON-escape content preview for rationale (file is escaped already)
      local preview
      preview="$(mtk_json_str "${content:0:120}")"
      findings+=("{\"id\":\"$fid\",\"severity\":\"$severity\",\"confidence\":100,\"source\":\"linter\",\"rule\":\"$rule_id\",\"file\":\"$file\",\"line\":$line,\"rationale\":\"$rationale\",\"suggested_fix\":\"$fix\",\"evidence\":\"$preview\"}")
    fi
  done < <(added_lines)
}

# --- Buffer added lines once (scanning multiple patterns would otherwise
# re-run git diff). ---
ADDED_LINES_CACHE="$(mktemp)"
CONTENT_CACHE="$(mktemp)"
trap 'rm -f "$ADDED_LINES_CACHE" "$CONTENT_CACHE"' EXIT
added_lines > "$ADDED_LINES_CACHE"

# Project the diff once into (a) parallel record arrays and (b) a content-only
# file, in the same order. This lets each rule run ONE grep over the whole diff
# instead of one grep per added line, and lets a grep hit index map back to its
# file/line without spawning anything. The projection deliberately reuses the
# same `IFS=$'\t' read -r file line content` split as the old per-line loop, so
# the string each regex sees is byte-for-byte what it saw before — a `cut -f3-`
# here would keep leading tabs that `read` coalesces and could shift matches on
# tab-indented code.
# REC_CLASS holds each record's file class (code|prose) so a scoped pack can
# drop its hits on files it does not apply to. Diff records are grouped by
# file, so caching the last classification keeps this to one call per file
# rather than one per added line.
REC_FILE=(); REC_LINE=(); REC_CONTENT=(); REC_CLASS=()
_last_file=""; _last_class=""
while IFS=$'\t' read -r file line content; do
  if [ "$file" != "$_last_file" ]; then
    _last_file="$file"
    _last_class="$(mtk_path_class "$file")"
  fi
  REC_FILE+=("$file"); REC_LINE+=("$line"); REC_CONTENT+=("$content")
  REC_CLASS+=("$_last_class")
  printf '%s\n' "$content"
done < "$ADDED_LINES_CACHE" > "$CONTENT_CACHE"

scan_cached() {
  local rule_id="$1" severity="$2" regex="$3" rationale="$4" fix="$5" scope="${6:-all}"
  local hits idx file line content fid preview
  # One grep per rule over the whole diff. The old shape ran a `grep` plus a
  # `sed` and a `cut` per added line per rule: at 30 active rules and a
  # 1,200-line diff that is ~72,000 processes and ~50s of pre-commit wall time.
  # grep -n numbers CONTENT_CACHE from 1, and that index is the record index.
  hits="$(grep -niE -- "$regex" "$CONTENT_CACHE" 2>/dev/null | cut -d: -f1)" || true
  [ -n "$hits" ] || return 0
  while IFS= read -r idx; do
    [ -n "$idx" ] || continue
    # Scope filter: a code-scoped pack ignores prose files and vice versa.
    case "$scope" in
      code)  [ "${REC_CLASS[idx-1]}" = "prose" ] && continue ;;
      prose) [ "${REC_CLASS[idx-1]}" = "code" ] && continue ;;
    esac
    # Already JSON-escaped by added_lines (any name git can stage).
    file="${REC_FILE[idx-1]}"
    line="${REC_LINE[idx-1]}"
    content="${REC_CONTENT[idx-1]}"
    finding_index=$((finding_index + 1))
    fid=$(printf 'L%03d' "$finding_index")
    # Cut first, then escape: cutting the escaped text could split a `\\` pair
    # and leave a lone `\` that escapes the closing quote.
    preview="$(mtk_json_str "${content:0:120}")"
    findings+=("{\"id\":\"$fid\",\"severity\":\"$severity\",\"confidence\":100,\"source\":\"linter\",\"rule\":\"$rule_id\",\"file\":\"$file\",\"line\":$line,\"rationale\":\"$rationale\",\"suggested_fix\":\"$fix\",\"evidence\":\"$preview\"}")
  done <<< "$hits"
}

for pattern_file in "${PATTERN_FILES[@]}"; do
  pack_scope="$(mtk_pack_scope "$pattern_file")"
  while IFS=$'\t' read -r rule_id severity regex rationale fix; do
    case "$rule_id" in
      \#*|"") continue ;;
    esac
    scan_cached "$rule_id" "$severity" "$regex" "$rationale" "$fix" "$pack_scope"
  done < "$pattern_file"
done

# --- Emit output ---
critical=0; warning=0; suggestion=0
for f in ${findings[@]+"${findings[@]}"}; do
  case "$f" in
    *'"severity":"critical"'*)   critical=$((critical + 1)) ;;
    *'"severity":"warning"'*)    warning=$((warning + 1)) ;;
    *'"severity":"suggestion"'*) suggestion=$((suggestion + 1)) ;;
  esac
done

verdict="PASS"
[ "$critical" -gt 0 ] && verdict="NEEDS_CHANGES"

if [ "$OUTPUT" = "human" ]; then
  printf 'Linter verdict: %s  (critical=%d warning=%d suggestion=%d)\n' \
    "$verdict" "$critical" "$warning" "$suggestion"
  for f in ${findings[@]+"${findings[@]}"}; do
    printf '%s\n' "$f"
  done
else
  joined=""
  first=1
  for f in ${findings[@]+"${findings[@]}"}; do
    if [ "$first" = 1 ]; then
      joined="$f"; first=0
    else
      joined="$joined,$f"
    fi
  done
  printf '{"source":"linter","verdict":"%s","summary":{"critical":%d,"warning":%d,"suggestion":%d},"findings":[%s]}\n' \
    "$verdict" "$critical" "$warning" "$suggestion" "$joined"
fi
