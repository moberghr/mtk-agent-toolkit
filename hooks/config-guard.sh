#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on unexpected non-zero exit (silent on
# success and on an intentional deny, exit 2).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 && $c -ne 2 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# PreToolUse guard for Edit | Write on linter / analyzer / formatter config.
# Exit 0 = allow, exit 2 = block.
#
# Denies ONLY edits that WEAKEN the config. Every other edit to a protected file
# passes silently — a guard that blocks version bumps or stricter rules gets
# switched off, and then it guards nothing.
#
# Weakening signals, each counted on the before and after text; the edit is
# denied iff after > before for any one of them:
#   W1  rule-ID-shaped tokens ([A-Za-z]{1,6}[0-9]{2,5}) on a suppression-list key
#       (NoWarn, WarningsNotAsErrors, ignore, extend-ignore, per-file-ignores,
#       disable, suppress) — including multi-line lists and suppression sections.
#   W2  disabled values: dotnet_diagnostic severity none|silent|suggestion, quoted
#       "off", TreatWarningsAsErrors/strict/... = false, AnalysisLevel/Mode none,
#       ignore_errors = true, "recommended": false, <WarningLevel>0,
#       <Nullable>disable.
#   W3  ignore files only: non-blank, non-comment, non-negation (!) lines.
#
# Deliberately NOT weakening: severity `warning`. Moving error -> warning keeps
# the diagnostic visible, and under TreatWarningsAsErrors still breaks the
# build; treating it as weakening would over-block routine tuning.
#
# Before/after text: Edit = old_string -> new_string; Write to an existing file =
# disk contents -> content; Write to a missing file is allowed (new config).
#
# Engineer approval list: .mtk/config-guard-allow (repo-relative path per line),
# honoured only when modified within the last 24h. The deny message tells the
# model to STOP and ask — like read-guard it never prints how to approve, and an
# Edit/Write to the list itself is always denied (matched by file identity after
# ./ ../ normalisation, so case variants and dot segments are caught; the
# approval lookup uses the same normalised path). A Bash write to the list is out
# of this hook's reach: it is a drift guard, not a defence against a determined
# adversary.
#
# Known limit: an Edit fragment that adds a code to a multi-line list without
# including the list's key line (or section header) is not attributed to W1.
#
# Fails OPEN on an empty or unparseable payload — drift guard, not a security gate.
#
# Kill-switch: MTK_CONFIG_GUARD=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

mtk_is_redundant_plugin_invocation "$0" && exit 0

[ "${MTK_CONFIG_GUARD:-1}" = "0" ] && exit 0

INPUT="$(mtk_read_payload)"
[ -n "$INPUT" ] || exit 0

TOOL_NAME=$(mtk_extract_tool_name "$INPUT" 2>/dev/null || echo "")
case "$TOOL_NAME" in
  Edit|Write) ;;
  "")
    # Some harnesses omit tool_name — infer from the fields present.
    if mtk_extract_json_string "$INPUT" "new_string" >/dev/null 2>&1; then
      TOOL_NAME="Edit"
    elif mtk_extract_json_string "$INPUT" "content" >/dev/null 2>&1; then
      TOOL_NAME="Write"
    else
      exit 0
    fi
    ;;
  *) exit 0 ;;
esac

FILE_PATH=$(mtk_extract_file_path "$INPUT" 2>/dev/null || echo "")
[ -n "$FILE_PATH" ] || exit 0

REPO_ROOT="$(mtk_repo_root 2>/dev/null || pwd)"

# Lexical normalisation: relative -> $PWD-anchored, and '', '.', '..' segments
# resolved as strings (the target need not exist yet). Pure bash, bash-3.2 safe.
normalize_path() {
  local p="$1" seg out="" n
  local -a parts stack
  stack=()
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  IFS=/ read -r -a parts <<<"$p"
  for seg in ${parts[@]+"${parts[@]}"}; do
    case "$seg" in
      ''|.) ;;
      ..) n=${#stack[@]}; [ "$n" -gt 0 ] && unset "stack[$((n - 1))]" && stack=(${stack[@]+"${stack[@]}"}) ;;
      *) stack+=("$seg") ;;
    esac
  done
  for seg in ${stack[@]+"${stack[@]}"}; do out="$out/$seg"; done
  printf '%s' "${out:-/}"
}
NORM_PATH="$(normalize_path "$FILE_PATH")"

# Spelling-robust repo-relative path (S1.17): never a bare prefix strip.
REL_PATH="$(mtk_repo_relative_path "$NORM_PATH" "$REPO_ROOT" 2>/dev/null || printf '%s' "$NORM_PATH")"
ALLOW_FILE="${REPO_ROOT}/.mtk/config-guard-allow"

# The approval list is the engineer's channel, not the model's. Matched by
# identity, not by string: on case-insensitive APFS '.MTK/Config-Guard-Allow'
# IS the list. Basename compared case-insensitively; parent compared with -ef
# against the real .mtk, or — when .mtk does not exist yet (or on a
# case-sensitive filesystem) — lexically: parent named .mtk (any case) whose
# own parent is the repo root.
is_allow_list() {
  local base parent pbase
  base="$(printf '%s' "${NORM_PATH##*/}" | tr '[:upper:]' '[:lower:]')"
  [ "$base" = "config-guard-allow" ] || return 1
  parent="${NORM_PATH%/*}"; [ -n "$parent" ] || parent="/"
  if [ -d "${REPO_ROOT}/.mtk" ] && [ -d "$parent" ] && [ "$parent" -ef "${REPO_ROOT}/.mtk" ]; then
    return 0
  fi
  pbase="$(printf '%s' "${parent##*/}" | tr '[:upper:]' '[:lower:]')"
  [ "$pbase" = ".mtk" ] || return 1
  parent="${parent%/*}"; [ -n "$parent" ] || parent="/"
  [ -d "$parent" ] && [ "$parent" -ef "$REPO_ROOT" ]
}
if is_allow_list; then
  mtk_deny "CONFIG-GUARD: '.mtk/config-guard-allow' is the engineer's approval list for config-weakening edits; it is not editable by the agent. STOP and ask the engineer — do not work around this guard." ""
fi

BASE_LC="$(basename "$FILE_PATH" | tr '[:upper:]' '[:lower:]')"

MODE=""
case "$BASE_LC" in
  .eslintignore|.prettierignore|.stylelintignore|.markdownlintignore) MODE="ignore" ;;
  .editorconfig|*.globalconfig|directory.build.props|directory.build.targets \
    |*.csproj|*.fsproj|*.vbproj|*.ruleset|stylecop.json) MODE="config" ;;
  .eslintrc*|eslint.config.*|biome.json|biome.jsonc|tsconfig.json|tsconfig.*.json|.stylelintrc*) MODE="config" ;;
  ruff.toml|.ruff.toml|pyproject.toml|setup.cfg|.flake8|tox.ini|mypy.ini|.mypy.ini|.pylintrc|pylintrc) MODE="config" ;;
  .shellcheckrc|.markdownlint*) MODE="config" ;;
esac
[ -n "$MODE" ] || exit 0

# --- Before / after text ------------------------------------------------------
if [ "$TOOL_NAME" = "Edit" ]; then
  BEFORE="$(mtk_extract_json_string "$INPUT" "old_string" 2>/dev/null)" || exit 0
  AFTER="$(mtk_extract_json_string "$INPUT" "new_string" 2>/dev/null)" || exit 0
else
  # New config file: nothing to weaken.
  [ -f "$FILE_PATH" ] || exit 0
  [ -r "$FILE_PATH" ] || exit 0
  AFTER="$(mtk_extract_json_string "$INPUT" "content" 2>/dev/null)" || exit 0
  BEFORE="$(cat "$FILE_PATH" 2>/dev/null)" || exit 0
fi

# Prints "w1 w2 w3" for the text on stdin.
count_signals() {
  awk -v mode="$MODE" '
    function is_code(t,   nl, nd) {
      if (t !~ /^[A-Za-z]+[0-9]+$/) return 0
      match(t, /[0-9]/); nl = RSTART - 1; nd = length(t) - nl
      return (nl >= 1 && nl <= 6 && nd >= 2 && nd <= 5)
    }
    function count_codes(s,   n, i, parts, c) {
      n = split(s, parts, /[^A-Za-z0-9]+/); c = 0
      for (i = 1; i <= n; i++) if (is_code(parts[i])) c++
      return c
    }
    function depth_of(s,   a, b, t) {
      t = s; a = gsub(/\[/, "", t)
      t = s; b = gsub(/\]/, "", t)
      return a - b
    }
    BEGIN { w1 = 0; w2 = 0; w3 = 0; cont = ""; depth = 0; sect = 0 }
    {
      raw = $0; l = tolower(raw)

      if (mode == "ignore") {
        if (l ~ /^[[:space:]]*$/) next
        if (l ~ /^[[:space:]]*#/) next
        if (l ~ /^[[:space:]]*!/) next
        w3++; next
      }

      # --- W2: disabled values (every line) ---
      if (l ~ /dotnet_(diagnostic|analyzer_diagnostic)[^=]*severity[[:space:]]*=[[:space:]]*(none|silent|suggestion)/) w2++
      t = l; w2 += gsub(/"off"|\047off\047/, "", t)
      if (l ~ /(^|[^a-z_])(treatwarningsaserrors|enforcecodestyleinbuild|runanalyzers|runanalyzersduringbuild|enablenetanalyzers|strict|noimplicitany|strictnullchecks|warn_unused_ignores|disallow_untyped_defs)["\047]?[[:space:]]*[:=>][[:space:]]*["\047]?false/) w2++
      if (l ~ /(^|[^a-z_])(analysislevel|analysismode)["\047]?[[:space:]]*[:=>][[:space:]]*["\047]?none([^a-z0-9_-]|$)/) w2++
      if (l ~ /ignore_errors[[:space:]]*=[[:space:]]*true/) w2++
      if (l ~ /"recommended"[[:space:]]*:[[:space:]]*false/) w2++
      if (l ~ /<warninglevel>[[:space:]]*0([^0-9]|$)/) w2++
      if (l ~ /<nullable>[[:space:]]*disable/) w2++

      # --- W1: suppression codes ---
      if (cont == "xml") {
        w1 += count_codes(raw)
        if (l ~ /<\/(nowarn|warningsnotaserrors)>/) cont = ""
        next
      }
      if (cont == "bracket") {
        w1 += count_codes(raw)
        depth += depth_of(l)
        if (depth <= 0) cont = ""
        next
      }
      if (cont == "indent") {
        if (raw ~ /^[[:space:]]+[^[:space:]]/) { w1 += count_codes(raw); next }
        cont = ""
      }

      # Section header (INI/TOML): a suppression-named section counts every line.
      if (l ~ /^[[:space:]]*\[[^=]*\][[:space:]]*$/) {
        sect = (l ~ /(ignore|disable|suppress)/) ? 1 : 0
        next
      }
      if (sect) { w1 += count_codes(raw); next }

      # XML suppression property.
      if (l ~ /<(nowarn|warningsnotaserrors)[[:space:]>]/) {
        w1 += count_codes(raw)
        if (l !~ /<\/(nowarn|warningsnotaserrors)>/) cont = "xml"
        next
      }

      # key = value / "key": value
      if (match(l, /[=:]/)) {
        key = substr(l, 1, RSTART - 1)
        val = substr(raw, RSTART + 1)
        if (key ~ /(nowarn|warningsnotaserrors|ignore|disable|suppress)/) {
          w1 += count_codes(val)
          d = depth_of(tolower(val))
          if (d > 0) { cont = "bracket"; depth = d }
          else if (val ~ /^[[:space:]]*$/) cont = "indent"
        }
      }
    }
    END { printf "%d %d %d\n", w1, w2, w3 }
  '
}

read -r B1 B2 B3 <<<"$(count_signals <<<"$BEFORE")"
read -r A1 A2 A3 <<<"$(count_signals <<<"$AFTER")"

SIGNAL=""
if [ "$A1" -gt "$B1" ]; then
  SIGNAL="W1 suppression codes: ${B1}→${A1}"
elif [ "$A2" -gt "$B2" ]; then
  SIGNAL="W2 disabled values: ${B2}→${A2}"
elif [ "$A3" -gt "$B3" ]; then
  SIGNAL="W3 ignore-file lines: ${B3}→${A3}"
fi
[ -n "$SIGNAL" ] || exit 0

# Engineer-granted approval (fresh within 24h, exact repo-relative path).
if [ -f "$ALLOW_FILE" ] \
  && [ -n "$(find "$ALLOW_FILE" -mmin -1440 2>/dev/null)" ] \
  && grep -qxF "$REL_PATH" "$ALLOW_FILE" 2>/dev/null; then
  exit 0
fi

# Deliberately no toggle hint and no approval recipe: the approval is the
# ENGINEER's decision, made out-of-band (read-guard precedent).
mtk_deny "CONFIG-GUARD: this edit weakens ${REL_PATH} (${SIGNAL}). Fix the code the analyzer flags instead of silencing it. If the engineer explicitly asked for this suppression, STOP and ask them to approve it — do not work around this guard." ""
