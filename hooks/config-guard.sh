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
# honoured only when modified within the last 24h. "Repo" is the edited file's
# own git work tree, so a nested worktree (.claude/worktrees/<name>/) has its own
# list and paths are relative to the worktree root. The deny message tells the
# model to STOP and ask — it never prints how to approve, and an
# Edit/Write to the list itself is always denied (matched by file identity after
# ./ ../ normalisation, so case variants and dot segments are caught; the
# approval lookup uses the same normalised path). A Bash write to the list is out
# of this hook's reach: it is a drift guard, not a defence against a determined
# adversary.
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
#   T2-SUPPRESS       suppressions added (#pragma warning disable, @ts-ignore,
#                     @ts-expect-error, # noqa, # type: ignore, eslint-disable).
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
# escape (it covers test files too).
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

[ "${MTK_CONFIG_GUARD:-1}" = "0" ] && exit 0
mtk_hook_seen config-guard.sh

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
    BEGIN { B = "(^|[^A-Za-z0-9_.])"; fi = 0 }
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
          + cnt(s, "#[ \t]*type:[ \t]*ignore") + cnt(s, "eslint-disable")
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
  read -r B1 B2 B3 <<<"$(count_signals <<<"$BEFORE")"
  read -r A1 A2 A3 <<<"$(count_signals <<<"$AFTER")"
  if [ "$A1" -gt "$B1" ]; then
    SIGNAL="W1-SUPPRESS suppression codes: ${B1}→${A1}"; CODE="W1-SUPPRESS"
  elif [ "$A2" -gt "$B2" ]; then
    SIGNAL="W2-DISABLED disabled values: ${B2}→${A2}"; CODE="W2-DISABLED"
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
