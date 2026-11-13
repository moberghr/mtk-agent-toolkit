#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on unexpected non-zero exit (silent on
# success and on an intentional deny, exit 2).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 && $c -ne 2 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# PreToolUse guard for Edit | Write | MultiEdit | NotebookEdit on linter /
# analyzer / formatter config. Exit 0 = allow, exit 2 = block.
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
#       <Nullable>disable; in ESLint files only, a numeric rule severity 0
#       ("rule": 0, "rule": [0, …]) on a rule-shaped key (hyphen or plugin
#       slash, or a single-word core rule), so option values such as
#       "ignore": [0, 1] are not severities. Also W2: a strictness setting
#       removed or commented out — the same boolean keys set true, counted on
#       non-comment lines, denied when that count drops. The "strict" umbrella
#       is counted apart: folding noImplicitAny/strictNullChecks into
#       "strict": true is not a removal; dropping "strict" itself always is.
#   W3  ignore files only: non-blank, non-comment, non-negation (!) lines.
#
# Deliberately NOT weakening: severity `warning`. Moving error -> warning keeps
# the diagnostic visible, and under TreatWarningsAsErrors still breaks the
# build; treating it as weakening would over-block routine tuning.
#
# Before/after text: Edit = old_string -> new_string; MultiEdit = every edits[]
# old_string -> every new_string (one edit of one file, judged as a whole like an
# Edit spanning the same regions; entries share no list/section state); Write to
# an existing file = disk contents -> content; Write to a missing file is allowed
# (new config). NotebookEdit: a notebook is neither config nor a test-class code
# file, so only the approval-list protection below applies to it.
#
# Engineer approval list: .mtk/config-guard-allow (repo-relative path per line),
# honoured only when modified within the last 24h. "Repo" is the edited file's
# own git work tree, so a nested worktree (.claude/worktrees/<name>/) has its own
# list and paths are relative to the worktree root. The deny message tells the
# model to STOP and ask — it never prints how to approve, and an
# Edit/Write to the list itself is always denied (matched by file identity after
# ./ ../ normalisation, so case variants and dot segments are caught; the
# approval lookup uses the same normalised path). A target path holding a control
# character (newline, tab, …) is denied outright, whatever file it names. A Bash
# write to the list is out of this hook's reach: it is a drift guard, not a
# defence against a determined adversary.
#
# Known limit: an Edit fragment that adds a code to a multi-line list without
# including the list's key line (or section header) is not attributed to W1.
#
# --- Two classes: CLASS=config | test ------------------------------------------
# config  the linter/analyzer/formatter files above (W1-SUPPRESS, W2-DISABLED,
#         W3-IGNORE). Mode MTK_CONFIG_GUARD_ENFORCE=off|shadow|active, default
#         active (behaviour unchanged).
# test    a code file (.cs .fs .vb .py .ts .tsx .js .jsx) whose REPO-RELATIVE
#         path is test-shaped: basename *Tests.cs, *Test.cs, test_*.py,
#         *_test.py, *.test.*, *.spec.*; or a directory segment named tests,
#         test or __tests__ (any case), or ending .Tests / .Test. Only the
#         repo-relative path is read, so a repo checked out under ~/tests/ is
#         not all tests. Config class wins on overlap (Foo.Tests/Foo.Tests.csproj
#         is config). Mode MTK_TEST_GUARD_ENFORCE=off|shadow|active, default
#         shadow: a signal is logged to .mtk/metrics/enforcement-shadow.jsonl
#         and the call is allowed with no model-visible output.
# Test signals, counted on the same before/after text as the config class:
#   T1-SKIP           skip/focus markers added ([Fact(Skip=…)], Skip =, [Ignore],
#                     pytest/unittest skip, it/describe/test.skip(, xit(, .only().
#   T2-SUPPRESS       suppressions added. Analyzer and linter silences:
#                     #pragma warning disable, F# #nowarn, @ts-ignore,
#                     @ts-expect-error, @ts-nocheck, eslint-disable,
#                     biome-ignore[-all|-start], # noqa, # type: ignore,
#                     # pylint: disable|skip-file, # pyright: ignore,
#                     [SuppressMessage], [UnconditionalSuppressMessage].
#                     Scanner silences: NOSONAR, nosemgrep / nosem, nosec,
#                     gitleaks:allow. Coverage exclusions:
#                     [ExcludeFromCodeCoverage], # pragma: no cover|branch,
#                     istanbul ignore, c8 / v8 ignore (not "ignore stop",
#                     which closes a region). The comment markers count in
#                     any case and only after a comment opener (//, /*, #,
#                     (*) on the same line, so an identifier or a string such
#                     as nosonarMode or "nosonar" is not one; gitleaks:allow
#                     counts anywhere on the line, as gitleaks reads it. Each
#                     occurrence counts, so x // nosec // nosec is two, and a
#                     c8 / v8 start or next with its stop on the same line is
#                     one. An attribute counts with or without the Attribute
#                     suffix, a namespace or global:: prefix, a target
#                     (assembly:, module:, …), F# [< >] brackets, or a place
#                     later in its attribute list (after "," or F# ";"); a
#                     list counts once, so a second tracked attribute added to
#                     the same list is not seen.
#                     Deliberately not counted: VB <Attr> syntax (a generic
#                     type argument reads the same), formatter markers
#                     (prettier-ignore, fmt: off), and ReSharper disable
#                     comments (routine in test files for test-name style).
#   T3-FEWER-TESTS    fewer test declarations ([Fact], [Theory], [Test],
#                     [TestMethod], [InlineData/TestCase/DataRow( rows,
#                     def test_, it(, test().
#   T4-FEWER-ASSERTS  fewer assertions (Assert., .Should(), assert, expect(,
#                     self.assertX) with no T3 drop.
#   T5-WEAKENED       an argument of a strong assertion (Assert.Equal/Same/
#                     StrictEqual/Throws, toEqual/toBe/toStrictEqual,
#                     assert x == y) now appears only in a weak one
#                     (Assert.NotNull/True, toBeDefined/toBeTruthy,
#                     assert x is not None). Assert.Equal(true|false, x) is
#                     treated as a boolean check, so → Assert.True(x) passes.
# Every token is anchored on an explicit boundary class (awk has no \b), so
# split( / emit( / latest( are not tests and [IgnoreDataMember] is not a skip.
# Test-class limits: Bash writes are out of reach; a test moved to a new file
# reads as T3-FEWER-TESTS on the old file — the approval list above is the
# escape (it covers test files too). Text is not parsed, so a marker quoted
# in a string (a source-generator test's expected output) counts as added.
# For the same reason a comment opener inside a string or URL counts as one:
# 'https://nosonar.example.com/x' reads as a NOSONAR comment. An earlier
# attribute that holds a "]", or a list that breaks across lines, hides a
# later tracked attribute in the same list ([Fact, Trait("a", "[x]"),
# SuppressMessage(…)] is not seen). HTML (<!-- -->), SQL (--) and VB (')
# comments are not read, so a marker in one of those forms is not seen.
# Production code is out of reach by design: T2 reads test-shaped files only,
# while coverage exclusions and analyzer attributes mostly land in production
# code. A class for every code file would, even in shadow mode, log each
# routine production #pragma or # noqa — a default-behaviour change for every
# install — so there is none; the silent-failure-hunter review lane, whose
# Silenced Diagnostics list is this list's twin, is what sees those files.
# Both classes go through the mode-gated deny; the approval-list protection
# above stays a plain, unconditional deny that no MTK_*_ENFORCE value changes.
#
# Fails OPEN on an empty or unparseable payload — drift guard, not a security gate.
#
# Kill-switch: MTK_CONFIG_GUARD=0 (both classes)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"
source "${SCRIPT_DIR}/lib/guard-mode.sh"
source "${SCRIPT_DIR}/lib/normalize-path.sh"

[ "${MTK_CONFIG_GUARD:-1}" = "0" ] && exit 0
mtk_hook_seen config-guard.sh

INPUT="$(mtk_read_payload)"
[ -n "$INPUT" ] || exit 0

TOOL_NAME=$(mtk_extract_tool_name "$INPUT" 2>/dev/null || echo "")
case "$TOOL_NAME" in
  Edit|Write|MultiEdit|NotebookEdit) ;;
  "")
    # Some harnesses omit tool_name — infer from the fields present. A quoted
    # "edits" can only be a key: inside a JSON string its quotes are escaped.
    case "$INPUT" in
      *'"edits"'*) TOOL_NAME="MultiEdit" ;;
      *)
        if mtk_extract_json_string "$INPUT" "new_string" >/dev/null 2>&1; then
          TOOL_NAME="Edit"
        elif mtk_extract_json_string "$INPUT" "content" >/dev/null 2>&1; then
          TOOL_NAME="Write"
        elif mtk_extract_json_string "$INPUT" "notebook_path" >/dev/null 2>&1; then
          TOOL_NAME="NotebookEdit"
        else
          exit 0
        fi
        ;;
    esac
    ;;
  *) exit 0 ;;
esac

if [ "$TOOL_NAME" = "NotebookEdit" ]; then
  FILE_PATH=$(mtk_extract_tool_field "$INPUT" notebook_path 2>/dev/null || echo "")
else
  FILE_PATH=$(mtk_extract_file_path "$INPUT" 2>/dev/null || echo "")
fi
[ -n "$FILE_PATH" ] || exit 0

# A control character (newline, tab, CR, …) in the target path is hostile: no
# real config or source path holds one, and line-oriented handling of it is how
# `src/x<LF>/../../.mtk/config-guard-allow` once read as `src/x` and reached the
# approval list. Hard guard: denied outright, for every tool and any file, with
# no toggle — and the path is not echoed back. Builtin match: runs on every edit.
case "$FILE_PATH" in
  *[[:cntrl:]]*)
    mtk_deny "CONFIG-GUARD: the target path contains a control character (newline, tab, carriage return or similar); no edit is made to such a path. Use the file's real path." ""
    ;;
esac

REPO_ROOT="$(mtk_repo_root 2>/dev/null || pwd)"

# Lexical normalisation (hooks/lib/normalize-path.sh): relative -> $PWD-anchored,
# and '', '.', '..' segments resolved as strings (the target need not exist yet).
mtk_normalize_path_var NORM_PATH "$FILE_PATH"

# The edited file belongs to its own git work tree, which is not always the
# session's project: a worktree nested under it (.claude/worktrees/<name>/) is a
# separate checkout. Resolve the root from the file's nearest existing directory,
# so the reported path and the approval list (and its protection) are that work
# tree's. Outside git, keep the project root.
file_work_tree() {
  local d="${NORM_PATH%/*}"
  while [ -n "$d" ] && [ ! -d "$d" ]; do d="${d%/*}"; done
  [ -n "$d" ] || d="/"
  git -C "$d" rev-parse --show-toplevel 2>/dev/null
}
FILE_ROOT="$(file_work_tree || true)"
[ -n "$FILE_ROOT" ] && REPO_ROOT="$FILE_ROOT"

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
# A notebook is neither a config file nor a test-class code file.
[ "$TOOL_NAME" = "NotebookEdit" ] && exit 0

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
# ESLint numeric severities are read only in ESLint's own files: elsewhere a
# "key": 0 is an ordinary setting (stylelint "max-nesting-depth": 0 is stricter).
ESLINT=0
case "$BASE_LC" in .eslintrc*|eslint.config.*) ESLINT=1 ;; esac

# Test-shaped repo-relative path of a code extension (see header).
is_test_file() {
  local rel="$REL_PATH" base dir seg
  local -a segs
  case "$rel" in /*|'') return 1 ;; esac   # outside the work tree: no relative path to read
  base="${rel##*/}"
  case "$base" in *.cs|*.fs|*.vb|*.py|*.ts|*.tsx|*.js|*.jsx) ;; *) return 1 ;; esac
  case "$base" in *Tests.cs|*Test.cs|test_*.py|*_test.py|*.test.*|*.spec.*) return 0 ;; esac
  dir="${rel%/*}"
  [ "$dir" != "$rel" ] || return 1
  IFS=/ read -r -a segs <<<"$dir"
  for seg in ${segs[@]+"${segs[@]}"}; do
    case "$seg" in
      [Tt][Ee][Ss][Tt][Ss]|[Tt][Ee][Ss][Tt]|__[Tt][Ee][Ss][Tt][Ss]__|*.Tests|*.Test) return 0 ;;
    esac
  done
  return 1
}

# Config class wins on overlap.
if [ -n "$MODE" ]; then
  CLASS="config"
  GUARD_KNOB="CONFIG_GUARD"
  GUARD_DEFAULT="active"
elif is_test_file; then
  CLASS="test"
  GUARD_KNOB="TEST_GUARD"
  GUARD_DEFAULT="shadow"
else
  exit 0
fi
GUARD_MODE="$(mtk_guard_mode "$GUARD_KNOB" "$GUARD_DEFAULT")"
# Neither class has an advisory mode. Treating `advisory` as off would let a
# plausible-looking value silently disable a guard that is on by default, so
# it falls back to the class default with the same signal as any unknown value.
if [ "$GUARD_MODE" = "advisory" ]; then
  printf '[mtk] MTK_%s_ENFORCE=advisory not supported by config-guard; using %s\n' "$GUARD_KNOB" "$GUARD_DEFAULT" >&2 || true
  GUARD_MODE="$GUARD_DEFAULT"
fi
case "$GUARD_MODE" in shadow|active) ;; *) exit 0 ;; esac

# --- Before / after text ------------------------------------------------------
# A line that separates MultiEdit entries; count_signals resets its multi-line
# list / section state on it, so one entry's open list never spills into the next.
EDIT_SEP=$'\034mtk-edit-boundary\034'

# Every string value of key $2 in payload $1, in document order, one EDIT_SEP
# line between values; exit 1 when the key is absent. Decodes each value exactly
# like mtk_extract_json_string (hook-io.sh), which stops at the first one; the
# per-line piece split and emit_value are copies of the ones there (see that
# function for why), so keep the two in step. The piece index only moves
# forward from one value to the next, so decoding stays linear in the payload
# size.
extract_json_strings() {
  printf '%s' "$1" | awk -v key="$2" -v sep="$EDIT_SEP" '
    # Prints the string value whose body starts at buffer position start, and
    # returns the position of its closing quote, or len + 1 when the buffer
    # ends first. Reads the pieces in part[1..n], where nl[i] is set when piece
    # i follows a line break rather than a backslash. On entry part[k] holds
    # start and begins at buffer position b; on return k and b name the piece
    # that holds the closing quote.
    function emit_value(   p, pb, q, c, skip) {
      p = substr(part[k], start - b + 1); pb = start; skip = 0
      for (;;) {
        q = index(p, "\"")
        if (q) { printf "%s", substr(p, 1, q - 1); return pb + q - 1 }
        printf "%s", p
        if (k >= n) return len + 1
        # p is the tail of part[k], so pb + length(p) is the separator after it.
        b = pb + length(p) + 1; k++
        p = part[k]; pb = b
        # The separator before this piece was the escaped character of the
        # previous escape and is already printed.
        if (skip) { skip = 0; continue }
        # A line break inside the value is plain text.
        if (nl[k]) { printf "%s", "\n"; continue }
        # An empty piece means the escaped character is the separator after
        # it: a backslash, or a line break that is kept with its backslash.
        if (p == "") {
          if (k >= n) return len + 1
          if (nl[k + 1]) printf "%s%s", "\\", "\n"
          else printf "%s", "\\"
          skip = 1; continue
        }
        c = substr(p, 1, 1); p = substr(p, 2); pb++
        if (c == "n") printf "%s", "\n"
        else if (c == "t") printf "%s", "\t"
        else if (c == "r") printf "%s", "\r"
        else if (c == "\"") printf "%s", "\""
        else if (c == "\\") printf "%s", "\\"
        else if (c == "/") printf "%s", "/"
        else if (c == "b") printf "%s", "\b"
        else if (c == "f") printf "%s", "\f"
        else printf "%s%s", "\\", c
      }
    }
    # The first line is split straight into part; later lines are appended.
    NR == 1 { buf = $0; n = split($0, part, "\\"); if (n == 0) { n = 1; part[1] = "" } }
    NR > 1 {
      buf = buf "\n" $0
      nl[n + 1] = 1
      m = split($0, piece, "\\")
      if (m == 0) { m = 1; piece[1] = "" }
      for (j = 1; j <= m; j++) part[++n] = piece[j]
    }
    END {
      pattern = "\"" key "\"[[:space:]]*:[[:space:]]*\""
      len = length(buf); pos = 1; nv = 0; k = 1; b = 1
      while (pos <= len && match(substr(buf, pos), pattern)) {
        start = pos + RSTART + RLENGTH - 1
        while (k < n && start > b + (l = length(part[k]))) { b += l + 1; k++ }
        if (nv++) printf "%s", "\n" sep "\n"
        pos = emit_value() + 1
      }
      if (nv == 0) exit 1
      printf "\n"
    }
  '
}

if [ "$TOOL_NAME" = "Edit" ]; then
  BEFORE="$(mtk_extract_json_string "$INPUT" "old_string" 2>/dev/null)" || exit 0
  AFTER="$(mtk_extract_json_string "$INPUT" "new_string" 2>/dev/null)" || exit 0
elif [ "$TOOL_NAME" = "MultiEdit" ]; then
  # Every edits[] entry: a weakening in any one of them counts, as it would in
  # an Edit spanning the same regions.
  BEFORE="$(extract_json_strings "$INPUT" "old_string" 2>/dev/null)" || exit 0
  AFTER="$(extract_json_strings "$INPUT" "new_string" 2>/dev/null)" || exit 0
else
  # New config file: nothing to weaken.
  [ -f "$FILE_PATH" ] || exit 0
  [ -r "$FILE_PATH" ] || exit 0
  AFTER="$(mtk_extract_json_string "$INPUT" "content" 2>/dev/null)" || exit 0
  BEFORE="$(cat "$FILE_PATH" 2>/dev/null)" || exit 0
fi

# Prints "w1 w2 w3 su ss" for the text on stdin: the W1–W3 counts, then the
# strictness settings that are on — the "strict" umbrella (su) and the other
# boolean keys (ss) — for the removed-strictness check.
count_signals() {
  awk -v mode="$MODE" -v eslint="$ESLINT" -v sep="$EDIT_SEP" '
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
    # ESLint rules set to numeric severity 0 on lower-cased line s: a rule-shaped
    # key (hyphen or plugin slash, or a single-word core rule) whose value, or
    # the first element of whose array value, is 0. Option keys ("ignore",
    # "code", camelCase) are not rule-shaped, so their 0 values do not count.
    function eslint_zero(s,   c, k) {
      c = 0
      while (match(s, /[@a-z0-9_\/-]+["\047]?[[:space:]]*:[[:space:]]*(\[[[:space:]]*)?0([^0-9.x]|$)/)) {
        k = substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
        sub(/["\047]?[[:space:]]*:.*$/, "", k)
        if (k ~ /[-\/]/ || k ~ /^(camelcase|complexity|curly|eqeqeq|indent|quotes|radix|semi|strict|yoda)$/) c++
      }
      return c
    }
    BEGIN { w1 = 0; w2 = 0; w3 = 0; su = 0; ss = 0; cont = ""; depth = 0; sect = 0 }
    {
      raw = $0; l = tolower(raw)

      # MultiEdit entry boundary: nothing carries over from the previous entry.
      if (raw == sep) { cont = ""; depth = 0; sect = 0; next }

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
      if (eslint == 1) w2 += eslint_zero(l)

      # --- strictness settings that are on (a drop is a removal, see W2) ---
      # Comment lines do not count, so commenting a setting out removes it.
      if (l !~ /^[[:space:]]*(\/\/|#|;|<!--)/) {
        t = l; su += gsub(/(^|[^a-z_])strict["\047]?[[:space:]]*[:=>][[:space:]]*["\047]?true/, "", t)
        t = l; ss += gsub(/(^|[^a-z_])(treatwarningsaserrors|enforcecodestyleinbuild|runanalyzers|runanalyzersduringbuild|enablenetanalyzers|noimplicitany|strictnullchecks|warn_unused_ignores|disallow_untyped_defs)["\047]?[[:space:]]*[:=>][[:space:]]*["\047]?true/, "", t)
      }

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
    END { printf "%d %d %d %d %d\n", w1, w2, w3, su, ss }
  '
}

# Test class. Reads the before text (fd 3) and after text (fd 4) and prints
# "b1 b2 b3 b4 a1 a2 a3 a4 t5 t5b t5a t5arg": T1–T4 counts before and after,
# then T5 (0|1), the strong-assertion count on the weakened argument before and
# after, and that argument (whitespace-squashed, capped). Separate from
# count_signals, which is keyed to the config modes.
count_test_signals() {
  awk '
    function cnt(s, re,   t) { t = s; return gsub(re, "", t) }
    function squash(s) { gsub(/[[:space:]]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s }
    # Argument list whose "(" is at position p of s: fills A[1..n] with the
    # top-level comma-separated arguments (squashed) and returns n; PEND is the
    # position after the matching ")". 0 when unbalanced within the cap.
    function args(s, p,   i, n, ch, depth, q, cur, lim) {
      n = 0; depth = 0; q = ""; cur = ""; PEND = 0
      lim = p + 4000; if (lim > length(s)) lim = length(s)
      for (i = p + 1; i <= lim; i++) {
        ch = substr(s, i, 1)
        if (q != "") {
          cur = cur ch
          if (ch == "\\") { i++; cur = cur substr(s, i, 1); continue }
          if (ch == q) q = ""
          continue
        }
        if (ch == "\"" || ch == "\047" || ch == "`") { q = ch; cur = cur ch; continue }
        if (ch == "(" || ch == "[" || ch == "{") depth++
        else if (ch == ")" || ch == "]" || ch == "}") {
          if (depth == 0) {
            if (ch != ")") return 0
            A[++n] = squash(cur); PEND = i + 1; return n
          }
          depth--
        } else if (ch == "," && depth == 0) { A[++n] = squash(cur); cur = ""; continue }
        cur = cur ch
      }
      return 0
    }
    # T2 markers beyond the first six (see header), counted on s: the comment
    # markers of the table built in BEGIN on the lower-cased text, line by
    # line and once per occurrence; attribute lists on the original text.
    # Markers are found with index() and split(), and a regex only ever runs
    # on a short window that starts at a marker, so the cost stays linear in
    # the text however many comment openers or brackets a line holds. Text
    # with no marker costs one index() per table row.
    function supp(s,   t, c, i, j, n, e, ln, LN, PK, np) {
      t = tolower(s); c = 0; np = 0
      for (j = 1; j <= NK; j++) if (index(t, KG[j])) PK[++np] = j
      if (np) {
        n = split(t, LN, "\n")
        for (i = 1; i <= n; i++) {
          ln = LN[i]; e = -1
          for (j = 1; j <= np; j++) if (index(ln, KG[PK[j]])) {
            if (e < 0) e = opener(ln)
            c += occ(ln, PK[j], e)
          }
        }
      }
      if (index(s, "SuppressMessage") || index(s, "ExcludeFromCodeCoverage")) c += attrs(s)
      return c
    }
    # End position of the comment opener (//, /*, #, (*) that ends first on
    # line ln; 0 when the line has none.
    function opener(ln,   e, i) {
      e = 0
      if ((i = index(ln, "#"))) e = i
      if ((i = index(ln, "//")) && (!e || i + 1 < e)) e = i + 1
      if ((i = index(ln, "/*")) && (!e || i + 1 < e)) e = i + 1
      if ((i = index(ln, "(*")) && (!e || i + 1 < e)) e = i + 1
      return e
    }
    # Occurrences of table row k on line ln: places where anchor KA[k] starts,
    # no KB[k] character stands just before, a comment opener ends earlier on
    # the line when KC[k] is set (e: see opener), and the window from there
    # matches KR[k] but not KX[k]. A window cut short of the line end gets an
    # identifier character appended, so its end never passes for the line end.
    function occ(ln, k, e,   P, n, i, p, w, ch, c, len) {
      n = split(ln, P, KA[k]); c = 0; p = 1; len = length(ln)
      for (i = 1; i < n; i++) {
        p += length(P[i])
        ch = (p > 1) ? substr(ln, p - 1, 1) : ""
        if ((ch == "" || !index(KB[k], ch)) && (!KC[k] || (e && e < p))) {
          w = substr(ln, p, 80); if (len - p >= 80) w = w "a"
          if (match(w, KR[k]) && (KX[k] == "" || !match(w, KX[k]))) c++
        }
        p += length(KA[k])
      }
      return c
    }
    # Tracked attributes on s: every "[" opens a piece, and a piece counts once
    # when, after an optional F# "<", a target (assembly:, module:, ...) and
    # earlier attributes of the same list (each closed by "," or F# ";"), it
    # names one, with global:: and a namespace allowed. A piece ends at the
    # next "[", and the regex stops at "]" or a line break. The separator is a
    # regex on purpose: BSD awk also splits on newline for a one-character
    # string separator, which would start a piece at every line.
    function attrs(s,   P, n, i, c) {
      n = split(s, P, /\[/); c = 0
      for (i = 2; i <= n; i++)
        if ((index(P[i], "SuppressMessage") || index(P[i], "ExcludeFromCodeCoverage")) && match(P[i], AR)) c++
      return c
    }
    # One row of the comment-marker table (see BEGIN).
    function mk(g, a, r, x, b, cm) {
      NK++; KG[NK] = g; KA[NK] = a; KR[NK] = "^" r; KX[NK] = (x == "") ? "" : "^" x
      KB[NK] = b; KC[NK] = cm
    }
    function strong(f, x) { if (x != "") S[f, x]++ }
    function weak(f, x) { if (x != "") W[f, x]++ }
    # Records strong-assertion arguments in S[f, arg] and weak-assertion
    # subjects in W[f, arg] for text s of side f.
    function scan(s, f,   pos, e, n, i, k, x, y, rest, line, isbool, ns, sa) {
      # xUnit strong: every argument (Equal(expected, actual) asserts on both).
      pos = 1
      while (match(substr(s, pos), B "Assert\\.(Equal|Same|StrictEqual|Throws|ThrowsAsync|ThrowsAny|ThrowsAnyAsync)(<[^>()]*>)?\\(")) {
        e = pos + RSTART + RLENGTH - 2
        n = args(s, e); isbool = 0
        for (i = 1; i <= n; i++) if (A[i] == "true" || A[i] == "false") isbool = 1
        if (!isbool) { ns = 0; for (i = 1; i <= n; i++) sa[++ns] = A[i]
          for (i = 1; i <= ns; i++) { for (k = 1; k < i; k++) if (sa[k] == sa[i]) break
            if (k == i) strong(f, sa[i]) } }
        pos = e
      }
      # xUnit weak: first argument.
      pos = 1
      while (match(substr(s, pos), B "Assert\\.(NotNull|True)\\(")) {
        e = pos + RSTART + RLENGTH - 2
        if (args(s, e) >= 1) weak(f, A[1])
        pos = e
      }
      # Jest: expect(x).matcher(y).
      pos = 1
      while (match(substr(s, pos), B "expect\\(")) {
        e = pos + RSTART + RLENGTH - 2
        pos = e
        if (args(s, e) < 1 || PEND == 0) continue
        x = A[1]; rest = substr(s, PEND, 200)
        if (match(rest, /^[[:space:]]*\.(toEqual|toBe|toStrictEqual)\(/)) {
          strong(f, x)
          if (args(s, PEND + RLENGTH - 1) >= 1 && A[1] != x) strong(f, A[1])
        } else if (match(rest, /^[[:space:]]*\.(toBeDefined|toBeTruthy)\(/)) {
          weak(f, x)
        }
      }
      # Python: assert x == y / assert x is not None.
      pos = 1
      while (match(substr(s, pos), B "assert[ \t]+")) {
        e = pos + RSTART + RLENGTH - 2
        pos = e
        line = substr(s, e + 1, 400)
        k = index(line, "\n"); if (k) line = substr(line, 1, k - 1)
        k = index(line, "#"); if (k) line = substr(line, 1, k - 1)
        if ((k = index(line, " is not None")) > 0) {
          weak(f, squash(substr(line, 1, k - 1)))
        } else if ((k = index(line, "==")) > 0) {
          x = squash(substr(line, 1, k - 1)); y = substr(line, k + 2)
          i = index(y, ","); if (i) y = substr(y, 1, i - 1)
          y = squash(y)
          strong(f, x); if (y != x) strong(f, y)
        }
      }
    }
    BEGIN {
      B = "(^|[^A-Za-z0-9_.])"; fi = 0
      # supp() comment markers, lower case, one mk() row each: gate (an
      # index() hit on the text and on the line), anchor (where the marker
      # starts; the split point), regex and exclusion on the window from the
      # anchor, the characters that may not stand just before the anchor
      # (CB after a comment opener, LB elsewhere), and 1 when a comment opener
      # must end earlier on the line. R and RW end a token; they differ only
      # in whether "-" continues it. A c8/v8 "ignore stop" closes a region and
      # suppresses nothing itself, hence the exclusion.
      R = "([^a-z0-9_-]|$)"; RW = "([^a-z0-9_]|$)"
      CB = "abcdefghijklmnopqrstuvwxyz0123456789_.:-"; LB = "abcdefghijklmnopqrstuvwxyz0123456789_.-"
      NK = 0
      mk("nosonar", "nosonar", "nosonar" R, "", CB, 1)
      mk("nosem", "nosem", "nosem(grep)?" R, "", CB, 1)
      mk("nosec", "nosec", "nosec" R, "", CB, 1)
      mk("gitleaks:allow", "gitleaks:allow", "gitleaks:allow" R, "", LB, 0)
      mk("pylint:", "pylint:", "pylint:[ \t]*(disable|skip-file)" RW, "", CB, 1)
      mk("pyright:", "pyright:", "pyright:[ \t]*ignore" RW, "", CB, 1)
      mk("pragma", "#", "#[ \t]*pragma:?[ \t]*no[ \t]*(cover|branch)" R, "", "", 0)
      mk("#nowarn", "#nowarn", "#nowarn" R, "", LB, 0)
      mk("@ts-nocheck", "@ts-nocheck", "@ts-nocheck" R, "", CB, 1)
      mk("biome-ignore", "biome-ignore", "biome-ignore(-all|-start)?" R, "", CB, 1)
      mk("istanbul", "istanbul", "istanbul[ \t]+ignore" R, "", CB, 1)
      mk("c8", "c8", "c8[ \t]+ignore" R, "c8[ \t]+ignore[ \t]+stop" R, CB, 1)
      mk("v8", "v8", "v8[ \t]+ignore" R, "v8[ \t]+ignore[ \t]+stop" R, CB, 1)
      # attrs() regex, anchored at the character after a "[".
      AR = "^<?[ \t]*([A-Za-z]+[ \t]*:[ \t]*)?([^]\n]*[,;][ \t]*)?(global::)?([A-Za-z_][A-Za-z0-9_]*\\.)*" \
        "((Unconditional)?SuppressMessage|ExcludeFromCodeCoverage)(Attribute)?[ \t]*[](,>]"
    }
    FNR == 1 { fi++ }
    { T[fi] = T[fi] "\n" $0 }
    END {
      for (f = 1; f <= 2; f++) {
        s = T[f] "\n"
        c1[f] = cnt(s, B "Skip[ \t]*=[^=]") + cnt(s, "\\[Ignore(\\]|\\()") \
          + cnt(s, "@pytest\\.mark\\.skip") + cnt(s, B "pytest\\.skip\\(") + cnt(s, "@unittest\\.skip") \
          + cnt(s, B "(it|describe|test)\\.skip\\(") + cnt(s, B "x(it|describe|test)\\(") + cnt(s, "\\.only\\(")
        c2[f] = cnt(s, "#pragma[ \t]+warning[ \t]+disable") + cnt(s, "//[ \t]*@ts-ignore") \
          + cnt(s, "//[ \t]*@ts-expect-error") + cnt(s, "#[ \t]*noqa") \
          + cnt(s, "#[ \t]*type:[ \t]*ignore") + cnt(s, "eslint-disable") + supp(s)
        c3[f] = cnt(s, "\\[(Fact|Theory)(\\]|\\(|,)") + cnt(s, "\\[Test(\\]|\\(|,)") \
          + cnt(s, "\\[TestMethod(\\]|\\(|,)") + cnt(s, "\\[(InlineData|TestCase|DataRow)\\(") \
          + cnt(s, B "def[ \t]+test_") + cnt(s, B "(it|test)\\(")
        c4[f] = cnt(s, B "Assert\\.") + cnt(s, "\\.Should\\(\\)") + cnt(s, B "assert[ \t(]") \
          + cnt(s, B "expect\\(") + cnt(s, "\\.assert[A-Z]")
        scan(s, f)
      }
      t5 = 0; t5b = 0; t5a = 0; t5arg = ""
      for (k in W) {
        split(k, kp, SUBSEP)
        if (kp[1] != 2) continue
        x = kp[2]
        wb = ((1, x) in W) ? W[1, x] : 0
        sb = ((1, x) in S) ? S[1, x] : 0
        sa = ((2, x) in S) ? S[2, x] : 0
        if (W[2, x] > wb && sa < sb) { t5 = 1; t5b = sb; t5a = sa; t5arg = substr(x, 1, 80); break }
      }
      printf "%d %d %d %d %d %d %d %d %d %d %d %s\n", c1[1], c2[1], c3[1], c4[1], \
        c1[2], c2[2], c3[2], c4[2], t5, t5b, t5a, t5arg
    }
  ' /dev/fd/3 /dev/fd/4
}

SIGNAL=""
CODE=""
if [ "$CLASS" = "config" ]; then
  read -r B1 B2 B3 BU BS <<<"$(count_signals <<<"$BEFORE")"
  read -r A1 A2 A3 AU AS <<<"$(count_signals <<<"$AFTER")"
  if [ "$A1" -gt "$B1" ]; then
    SIGNAL="W1-SUPPRESS suppression codes: ${B1}→${A1}"; CODE="W1-SUPPRESS"
  elif [ "$A2" -gt "$B2" ]; then
    SIGNAL="W2-DISABLED disabled values: ${B2}→${A2}"; CODE="W2-DISABLED"
  elif [ "$AU" -lt "$BU" ]; then
    SIGNAL="W2-DISABLED strict setting removed: ${BU}→${AU}"; CODE="W2-DISABLED"
  elif [ "$AS" -lt "$BS" ] && [ "$AU" -eq 0 ]; then
    # Sub-flags dropped while the after text visibly turns "strict" on are folded
    # into the umbrella, not removed.
    SIGNAL="W2-DISABLED strictness settings removed: ${BS}→${AS}"; CODE="W2-DISABLED"
  elif [ "$A3" -gt "$B3" ]; then
    SIGNAL="W3-IGNORE ignore-file lines: ${B3}→${A3}"; CODE="W3-IGNORE"
  fi
else
  # Fail open on a failed scan, but visibly: one stderr line (not shown to the
  # model on exit 0, but in the hook log), never a silent pass.
  scan_failed() {
    printf '[mtk] config-guard: test-signal scan failed; test class not evaluated\n' >&2 || true
    exit 0
  }
  TS_OUT="$(count_test_signals 3<<<"$BEFORE" 4<<<"$AFTER" 2>/dev/null)" || scan_failed
  read -r TB1 TB2 TB3 TB4 TA1 TA2 TA3 TA4 T5 T5B T5A T5ARG <<<"$TS_OUT"
  # Anything but eleven plain counts is a failed scan too.
  case "${TB1:-x}${TB2:-x}${TB3:-x}${TB4:-x}${TA1:-x}${TA2:-x}${TA3:-x}${TA4:-x}${T5:-x}${T5B:-x}${T5A:-x}" in
    *[!0-9]*) scan_failed ;;
  esac
  if [ "$TA1" -gt "$TB1" ]; then
    SIGNAL="T1-SKIP skip/focus markers: ${TB1}→${TA1}"; CODE="T1-SKIP"
  elif [ "$TA2" -gt "$TB2" ]; then
    SIGNAL="T2-SUPPRESS suppressions: ${TB2}→${TA2}"; CODE="T2-SUPPRESS"
  elif [ "$TA3" -lt "$TB3" ]; then
    SIGNAL="T3-FEWER-TESTS test declarations: ${TB3}→${TA3}"; CODE="T3-FEWER-TESTS"
  elif [ "$TA4" -lt "$TB4" ]; then
    SIGNAL="T4-FEWER-ASSERTS assertions: ${TB4}→${TA4}"; CODE="T4-FEWER-ASSERTS"
  elif [ "$T5" = "1" ]; then
    SIGNAL="T5-WEAKENED strong assertions on '${T5ARG}': ${T5B}→${T5A}, now only a weak one"; CODE="T5-WEAKENED"
  fi
fi
[ -n "$SIGNAL" ] || exit 0

# Engineer-granted approval (fresh within 24h, exact repo-relative path).
if [ -f "$ALLOW_FILE" ] \
  && [ -n "$(find "$ALLOW_FILE" -mmin -1440 2>/dev/null)" ] \
  && grep -qxF "$REL_PATH" "$ALLOW_FILE" 2>/dev/null; then
  exit 0
fi

# Deliberately no toggle hint and no approval recipe: the approval is the
# ENGINEER's decision, made out-of-band. One literal code per call, so
# scripts/check-guard-twins.sh can pair each with its deny/allow tests. Every
# SIGNAL opens with its CODE, so the deny text reads "(<CODE> …)" and the tests
# bind each deny:<CODE> label to the code actually emitted.
if [ "$CLASS" = "config" ]; then
  REASON="CONFIG-GUARD: this edit weakens ${REL_PATH} (${SIGNAL}). Fix the code the analyzer flags instead of silencing it. If the engineer explicitly asked for this suppression, STOP and ask them to approve it — do not work around this guard."
else
  REASON="TEST-GUARD: this edit weakens the test ${REL_PATH} (${SIGNAL}). Make the test pass by fixing the code. If the engineer asked to remove or relax this test, STOP and ask them."
fi
case "$CODE" in
  W1-SUPPRESS) mtk_deny_gated "$GUARD_MODE" config-guard W1-SUPPRESS "$REASON" "" "$REL_PATH" ;;
  W2-DISABLED) mtk_deny_gated "$GUARD_MODE" config-guard W2-DISABLED "$REASON" "" "$REL_PATH" ;;
  W3-IGNORE) mtk_deny_gated "$GUARD_MODE" config-guard W3-IGNORE "$REASON" "" "$REL_PATH" ;;
  T1-SKIP) mtk_deny_gated "$GUARD_MODE" config-guard T1-SKIP "$REASON" "" "$REL_PATH" ;;
  T2-SUPPRESS) mtk_deny_gated "$GUARD_MODE" config-guard T2-SUPPRESS "$REASON" "" "$REL_PATH" ;;
  T3-FEWER-TESTS) mtk_deny_gated "$GUARD_MODE" config-guard T3-FEWER-TESTS "$REASON" "" "$REL_PATH" ;;
  T4-FEWER-ASSERTS) mtk_deny_gated "$GUARD_MODE" config-guard T4-FEWER-ASSERTS "$REASON" "" "$REL_PATH" ;;
  T5-WEAKENED) mtk_deny_gated "$GUARD_MODE" config-guard T5-WEAKENED "$REASON" "" "$REL_PATH" ;;
esac
exit 0
