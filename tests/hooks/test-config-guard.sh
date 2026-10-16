#!/usr/bin/env bash
set -euo pipefail

# config-guard.sh denies Edit/Write that WEAKEN linter/analyzer/formatter config
# (SC1), passes every non-weakening edit (SC2), and never teaches the model how
# to approve its own suppression (SC3). Its test class (T1–T5) logs test-tamper
# signals in shadow mode (the default) and denies them when
# MTK_TEST_GUARD_ENFORCE=active (SC6).
#
# Gated cases are labelled deny:<CODE> / allow:<CODE> so
# scripts/check-guard-twins.sh can pair every mode-gated code with both.
#
# The allow cases matter as much as the denies: this is a hard deny, and a guard
# that blocks version bumps or stricter rules would get switched off.
#
# Every case runs against a mktemp -d sandbox project: CLAUDE_PROJECT_DIR and
# TMPDIR point into it, and file_path values name sandbox files, so the real
# repo's config files are never read or touched.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$REPO_ROOT/hooks/config-guard.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/proj/.mtk" "$SANDBOX/tmp"
PROJ="$SANDBOX/proj"
export CLAUDE_PROJECT_DIR="$PROJ"
export TMPDIR="$SANDBOX/tmp"
# Hermetic modes: config class default active, test class default shadow.
unset MTK_CONFIG_GUARD MTK_CONFIG_GUARD_ENFORCE MTK_TEST_GUARD_ENFORCE 2>/dev/null || true
cd "$PROJ"

fails=0

# JSON payload builders (python3 is S3.3 baseline) — exact escaping of quotes/newlines.
edit_payload() { # $1 path  $2 old  $3 new
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Edit",
                  "tool_input": {"file_path": sys.argv[1], "old_string": sys.argv[2],
                                 "new_string": sys.argv[3]}}))
PY
}
write_payload() { # $1 path  $2 content
  python3 - "$1" "$2" <<'PY'
import json, sys
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Write",
                  "tool_input": {"file_path": sys.argv[1], "content": sys.argv[2]}}))
PY
}

# Runs the guard with payload $1; echoes the exit code. Its stderr goes to
# $LAST_ERR, which the next expect reads (deny:<CODE> binding) and removes.
# Here-string, not a pipe: the guard may exit before reading stdin (kill-switch),
# and a pipe would then fail the printf with EPIPE under pipefail.
LAST_ERR="$SANDBOX/last-guard.err"
run_guard() {
  "$GUARD" <<<"$1" >/dev/null 2>"$LAST_ERR" && echo 0 || echo $?
}
# run_with <payload> VAR=value ...: run_guard with extra environment.
run_with() {
  local payload="$1"
  shift
  env "$@" "$GUARD" <<<"$payload" >/dev/null 2>"$LAST_ERR" && echo 0 || echo $?
}

# A "deny:<CODE> …" label expecting exit 2 is bound to the code the guard
# emitted: the deny text must carry "(<CODE> " (every SIGNAL opens with its
# code). $LAST_ERR is consumed by every expect, so a deny case whose run did not
# go through run_guard/run_with/run_active fails instead of reading a stale file.
expect() {
  local label="$1" want="$2" got="$3" code="" err=""
  case "$label" in deny:*) code="${label#deny:}"; code="${code%% *}" ;; esac
  [ -f "$LAST_ERR" ] && err="$(cat "$LAST_ERR")"
  rm -f "$LAST_ERR"
  if [ "$got" != "$want" ]; then
    printf 'FAIL: %s — expected exit %s, got %s\n' "$label" "$want" "$got" >&2
    fails=$((fails + 1))
  elif [ -n "$code" ] && [ "$want" = 2 ]; then
    case "$err" in
      *"($code "*) printf '  PASS  %s\n' "$label" ;;
      *) printf 'FAIL: %s — denied, but not with %s. Stderr: %s\n' "$label" "$code" "$err" >&2
         fails=$((fails + 1)) ;;
    esac
  else
    printf '  PASS  %s\n' "$label"
  fi
}

P="$PROJ"
NL=$'\n'

# ============================ SC1: weakening edits deny ========================

# shellcheck disable=SC2016  # $(NoWarn) is literal MSBuild text, not a shell expansion
expect "deny:W1-SUPPRESS NoWarn code added to Directory.Build.props" 2 "$(run_guard "$(edit_payload \
  "$P/Directory.Build.props" \
  '<NoWarn>$(NoWarn);CS1591</NoWarn>' \
  '<NoWarn>$(NoWarn);CS1591;CA2007</NoWarn>')")"

expect "deny:W2-DISABLED editorconfig severity set to none" 2 "$(run_guard "$(edit_payload \
  "$P/.editorconfig" \
  'dotnet_diagnostic.CA1062.severity = error' \
  'dotnet_diagnostic.CA1062.severity = none')")"

expect "deny:W2-DISABLED editorconfig severity set to suggestion" 2 "$(run_guard "$(edit_payload \
  "$P/.editorconfig" \
  'dotnet_diagnostic.IDE0055.severity = warning' \
  'dotnet_diagnostic.IDE0055.severity = suggestion')")"

expect "deny:W2-DISABLED TreatWarningsAsErrors flipped to false in csproj" 2 "$(run_guard "$(edit_payload \
  "$P/src/App/App.csproj" \
  '<TreatWarningsAsErrors>true</TreatWarningsAsErrors>' \
  '<TreatWarningsAsErrors>false</TreatWarningsAsErrors>')")"

expect "deny:W2-DISABLED eslint rule set to \"off\"" 2 "$(run_guard "$(edit_payload \
  "$P/eslint.config.mjs" \
  '"no-console": "error",' \
  '"no-console": "off",')")"

expect "deny:W1-SUPPRESS ruff ignore code added (single line)" 2 "$(run_guard "$(edit_payload \
  "$P/pyproject.toml" \
  'ignore = ["E501"]' \
  'ignore = ["E501", "F401"]')")"

expect "deny:W1-SUPPRESS ruff ignore code added (multi-line list)" 2 "$(run_guard "$(edit_payload \
  "$P/ruff.toml" \
  "ignore = [${NL}  \"E501\",${NL}]" \
  "ignore = [${NL}  \"E501\",${NL}  \"F401\",${NL}]")")"

expect "deny:W3-IGNORE .eslintignore line added" 2 "$(run_guard "$(edit_payload \
  "$P/.eslintignore" \
  "dist/" \
  "dist/${NL}src/legacy/")")"

printf '<Project>\n  <PropertyGroup>\n    <Nullable>enable</Nullable>\n  </PropertyGroup>\n</Project>\n' \
  > "$P/Directory.Build.props"
expect "deny:W1-SUPPRESS Write to existing props that adds NoWarn" 2 "$(run_guard "$(write_payload \
  "$P/Directory.Build.props" \
  "$(printf '<Project>\n  <PropertyGroup>\n    <Nullable>enable</Nullable>\n    <NoWarn>CS8618</NoWarn>\n  </PropertyGroup>\n</Project>\n')")")"

expect "deny:W1-SUPPRESS uppercase DIRECTORY.BUILD.PROPS still protected" 2 "$(run_guard "$(edit_payload \
  "$P/DIRECTORY.BUILD.PROPS" \
  '<NoWarn></NoWarn>' \
  '<NoWarn>CS1591</NoWarn>')")"

# Extraction round-trip: escaped quotes + \n-escaped multi-line strings, weakening on
# line 3. Proves mtk_extract_json_string decodes the escapes before line counting.
RT_OLD="[*.cs]${NL}# the \"core\" rules${NL}dotnet_diagnostic.CA2000.severity = error${NL}indent_size = 4"
RT_NEW="[*.cs]${NL}# the \"core\" rules${NL}dotnet_diagnostic.CA2000.severity = silent${NL}indent_size = 4"
rt_payload="$(edit_payload "$P/.editorconfig" "$RT_OLD" "$RT_NEW")"
case "$rt_payload" in
  *'\"core\"'*'\n'*) : ;;
  *) printf 'FAIL: round-trip payload not JSON-escaped as intended\n' >&2; fails=$((fails + 1)) ;;
esac
expect "deny:W2-DISABLED extraction round-trip: escaped quote + multi-line, weakening on line 3" 2 \
  "$(run_guard "$rt_payload")"
# Control: same shape, non-weakening — proves the deny above is the line-3 value.
expect "allow:W2-DISABLED extraction round-trip control (no weakening) allowed" 0 "$(run_guard "$(edit_payload \
  "$P/.editorconfig" "$RT_OLD" "${RT_OLD/indent_size = 4/indent_size = 2}")")"

# --- T1: the remaining W2 disabled-value signals, each with a non-weakening control.
# Each control keeps the same key and file so the deny above it can only come from
# the value flipping to its disabled form.
expect "deny:W2-DISABLED AnalysisLevel set to none" 2 "$(run_guard "$(edit_payload \
  "$P/Directory.Build.props" \
  '<AnalysisLevel>latest</AnalysisLevel>' \
  '<AnalysisLevel>none</AnalysisLevel>')")"
expect "allow:W2-DISABLED AnalysisLevel control: latest -> preview allowed" 0 "$(run_guard "$(edit_payload \
  "$P/Directory.Build.props" \
  '<AnalysisLevel>latest</AnalysisLevel>' \
  '<AnalysisLevel>preview</AnalysisLevel>')")"

expect "deny:W2-DISABLED AnalysisMode set to None" 2 "$(run_guard "$(edit_payload \
  "$P/src/App/App.csproj" \
  '<AnalysisMode>All</AnalysisMode>' \
  '<AnalysisMode>None</AnalysisMode>')")"
expect "allow:W2-DISABLED AnalysisMode control: Default -> All allowed" 0 "$(run_guard "$(edit_payload \
  "$P/src/App/App.csproj" \
  '<AnalysisMode>Default</AnalysisMode>' \
  '<AnalysisMode>All</AnalysisMode>')")"

expect "deny:W2-DISABLED mypy ignore_errors = true" 2 "$(run_guard "$(edit_payload \
  "$P/mypy.ini" \
  'ignore_errors = false' \
  'ignore_errors = true')")"
expect "allow:W2-DISABLED mypy ignore_errors control: true -> false allowed" 0 "$(run_guard "$(edit_payload \
  "$P/mypy.ini" \
  'ignore_errors = true' \
  'ignore_errors = false')")"

expect "deny:W2-DISABLED biome \"recommended\": false" 2 "$(run_guard "$(edit_payload \
  "$P/biome.json" \
  '"recommended": true' \
  '"recommended": false')")"
expect "allow:W2-DISABLED biome recommended control: false -> true allowed" 0 "$(run_guard "$(edit_payload \
  "$P/biome.json" \
  '"recommended": false' \
  '"recommended": true')")"

expect "deny:W2-DISABLED WarningLevel set to 0" 2 "$(run_guard "$(edit_payload \
  "$P/src/App/App.csproj" \
  '<WarningLevel>4</WarningLevel>' \
  '<WarningLevel>0</WarningLevel>')")"
expect "allow:W2-DISABLED WarningLevel control: 4 -> 9999 allowed (not a 0 prefix match)" 0 "$(run_guard "$(edit_payload \
  "$P/src/App/App.csproj" \
  '<WarningLevel>4</WarningLevel>' \
  '<WarningLevel>9999</WarningLevel>')")"

expect "deny:W2-DISABLED Nullable set to disable" 2 "$(run_guard "$(edit_payload \
  "$P/Directory.Build.props" \
  '<Nullable>enable</Nullable>' \
  '<Nullable>disable</Nullable>')")"
expect "allow:W2-DISABLED Nullable control: warnings -> enable allowed" 0 "$(run_guard "$(edit_payload \
  "$P/Directory.Build.props" \
  '<Nullable>warnings</Nullable>' \
  '<Nullable>enable</Nullable>')")"

# ============================ SC3: approval list integrity =====================

expect "Edit of the approval list itself denied" 2 "$(run_guard "$(edit_payload \
  "$P/.mtk/config-guard-allow" "" "Directory.Build.props")")"
expect "Write of the approval list itself denied" 2 "$(run_guard "$(write_payload \
  "$P/.mtk/config-guard-allow" "Directory.Build.props")")"
# Spelling variants of the approval list must also deny (F001): on case-insensitive
# APFS a case variant writes the real file, and ./ or ../ segments defeat an exact
# string compare.
expect "case-variant approval list path denied" 2 "$(run_guard "$(write_payload \
  "$P/.MTK/Config-Guard-Allow" "Directory.Build.props")")"
expect "approval list path with ./ segment denied" 2 "$(run_guard "$(write_payload \
  "$P/.mtk/./config-guard-allow" "Directory.Build.props")")"
expect "approval list path with ../ segment denied" 2 "$(run_guard "$(edit_payload \
  "$P/hooks/../.mtk/config-guard-allow" "" "Directory.Build.props")")"
expect "approval list path with // segment denied" 2 "$(run_guard "$(write_payload \
  "$P//.mtk//config-guard-allow" "Directory.Build.props")")"
# A symlink alias of .mtk: the lexical fallback sees a parent named "mtk-alias",
# so only the identity (-ef) branch of is_allow_list catches it.
ln -s .mtk "$P/mtk-alias"
expect "approval list reached through a symlink alias of .mtk denied (Write)" 2 "$(run_guard "$(write_payload \
  "$P/mtk-alias/config-guard-allow" "Directory.Build.props")")"
expect "approval list reached through a symlink alias of .mtk denied (Edit)" 2 "$(run_guard "$(edit_payload \
  "$P/mtk-alias/config-guard-allow" "" "Directory.Build.props")")"
rm -f "$P/mtk-alias"

printf 'Directory.Build.props\n' > "$P/.mtk/config-guard-allow"
touch -t 202001010000 "$P/.mtk/config-guard-allow"
expect "deny:W1-SUPPRESS stale approval list (>24h) does not approve" 2 "$(run_guard "$(edit_payload \
  "$P/Directory.Build.props" '<NoWarn></NoWarn>' '<NoWarn>CS1591</NoWarn>')")"

# Deny message: names the file + signal, tells the model to stop and ask, and never
# teaches a toggle or approval recipe.
msg="$("$GUARD" 2>&1 >/dev/null <<<"$(edit_payload "$P/src/App/App.csproj" \
  '<TreatWarningsAsErrors>true</TreatWarningsAsErrors>' \
  '<TreatWarningsAsErrors>false</TreatWarningsAsErrors>')" || true)"
check_msg() { # $1 label $2 must-contain(1)/must-not(0) $3 needle
  local hit=0
  case "$msg" in *"$3"*) hit=1 ;; esac
  if [ "$hit" != "$2" ]; then
    printf 'FAIL: deny message %s. Got: %s\n' "$1" "$msg" >&2
    fails=$((fails + 1))
  else
    printf '  PASS  deny message %s\n' "$1"
  fi
}
check_msg "names the file" 1 "src/App/App.csproj"
check_msg "names the signal" 1 "(W2-DISABLED disabled values: 0→1)"
check_msg "says STOP and ask" 1 "STOP and ask"
check_msg "carries the continuation suffix" 1 "batched with it were CANCELLED"
check_msg "teaches no toggle" 0 "disable this guard"
check_msg "does not name the kill-switch" 0 "MTK_CONFIG_GUARD"
check_msg "does not print the approval list path" 0 "config-guard-allow"

# ============================ SC2: non-weakening edits pass ====================

expect "allow:W2-DISABLED severity error -> warning is not weakening" 0 "$(run_guard "$(edit_payload \
  "$P/.editorconfig" \
  'dotnet_diagnostic.CA1062.severity = error' \
  'dotnet_diagnostic.CA1062.severity = warning')")"

expect "allow:W1-SUPPRESS stricter rule added to editorconfig" 0 "$(run_guard "$(edit_payload \
  "$P/.editorconfig" \
  'dotnet_diagnostic.CA1062.severity = warning' \
  "dotnet_diagnostic.CA1062.severity = warning${NL}dotnet_diagnostic.CA2007.severity = error")")"

expect "allow:W1-SUPPRESS WarningsAsErrors code added (stricter) allowed" 0 "$(run_guard "$(edit_payload \
  "$P/Directory.Build.props" \
  "<NoWarn>CS1591</NoWarn>" \
  "<NoWarn>CS1591</NoWarn>${NL}    <WarningsAsErrors>CS8600</WarningsAsErrors>")")"

expect "allow:W1-SUPPRESS NoWarn code removed allowed" 0 "$(run_guard "$(edit_payload \
  "$P/Directory.Build.props" \
  '<NoWarn>CS1591;CA2007</NoWarn>' '<NoWarn>CS1591</NoWarn>')")"

expect "version bump in csproj" 0 "$(run_guard "$(edit_payload \
  "$P/src/App/App.csproj" \
  '<PackageReference Include="Serilog" Version="3.1.1" />' \
  '<PackageReference Include="Serilog" Version="4.0.2" />')")"

expect "allow:W2-DISABLED eslint rule tightened warn -> error" 0 "$(run_guard "$(edit_payload \
  "$P/eslint.config.mjs" '"no-console": "warn",' '"no-console": "error",')")"

expect "allow:W3-IGNORE .eslintignore negation line added (un-ignores)" 0 "$(run_guard "$(edit_payload \
  "$P/.eslintignore" "dist/" "dist/${NL}!dist/keep.js")")"

rm -f "$P/.editorconfig"
expect "allow:W2-DISABLED new .editorconfig via Write to a missing path" 0 "$(run_guard "$(write_payload \
  "$P/.editorconfig" "$(printf 'root = true\n[*.cs]\ndotnet_diagnostic.CA1062.severity = none\n')")")"

expect "non-protected file (src/Foo.cs)" 0 "$(run_guard "$(edit_payload \
  "$P/src/Foo.cs" '// ok' '#pragma warning disable CA2007')")"

printf 'Directory.Build.props\n' > "$P/.mtk/config-guard-allow"
expect "allow:W1-SUPPRESS path on a fresh approval list allowed" 0 "$(run_guard "$(edit_payload \
  "$P/Directory.Build.props" '<NoWarn></NoWarn>' '<NoWarn>CS1591</NoWarn>')")"
# The approval lookup normalises ./ and ../ too, so an approved path still matches.
expect "allow:W1-SUPPRESS approved path spelled with ../ segment still allowed" 0 "$(run_guard "$(edit_payload \
  "$P/src/../Directory.Build.props" '<NoWarn></NoWarn>' '<NoWarn>CS1591</NoWarn>')")"
rm -f "$P/.mtk/config-guard-allow"

# .mtk not created yet: the lexical fallback (parent named .mtk, any case, directly
# under the repo root) still denies.
rmdir "$P/.mtk"
expect "approval list denied before .mtk exists (case variant)" 2 "$(run_guard "$(write_payload \
  "$P/.MTK/config-guard-allow" "Directory.Build.props")")"
expect "approval list denied before .mtk exists (../ segment)" 2 "$(run_guard "$(write_payload \
  "$P/src/../.mtk/config-guard-allow" "Directory.Build.props")")"
mkdir -p "$P/.mtk"

# ============================ SC6: test-tamper class ===========================
# Test files of a code extension at a test-shaped repo-relative path. Each signal
# is checked twice: denied with MTK_TEST_GUARD_ENFORCE=active, and in the default
# shadow mode allowed silently with exactly one enforcement-shadow.jsonl line.

SHADOW_LOG="$P/.mtk/metrics/enforcement-shadow.jsonl"
CS="$P/tests/Calc.Tests/CalcTests.cs"
PY="$P/tests/test_calc.py"
TSF="$P/src/calc.test.ts"

run_active() { # $1 payload — test class active (config class is active by default)
  MTK_TEST_GUARD_ENFORCE=active "$GUARD" <<<"$1" >/dev/null 2>"$LAST_ERR" && echo 0 || echo $?
}
shadow_lines() {
  if [ -f "$SHADOW_LOG" ]; then wc -l <"$SHADOW_LOG" | tr -d ' '; else echo 0; fi
}
# expect_shadow <label> <code> <payload> [VAR=value ...]: exit 0, no output,
# one new log line naming config-guard and <code>.
expect_shadow() {
  local label="$1" code="$2" payload="$3" before after out rc=0 last=""
  shift 3
  before="$(shadow_lines)"
  out="$(env ${1+"$@"} "$GUARD" <<<"$payload" 2>&1)" || rc=$?
  after="$(shadow_lines)"
  [ -f "$SHADOW_LOG" ] && last="$(tail -n 1 "$SHADOW_LOG")"
  case "$last" in
    *'"hook":"config-guard"'*"\"code\":\"$code\""*) ;;
    *) last="" ;;
  esac
  if [ "$rc" = 0 ] && [ -z "$out" ] && [ "$after" = "$((before + 1))" ] && [ -n "$last" ]; then
    printf '  PASS  %s\n' "$label"
  else
    printf 'FAIL: %s — rc=%s output=[%s] log %s→%s last=[%s]\n' "$label" "$rc" "$out" \
      "$before" "$after" "$(tail -n 1 "$SHADOW_LOG" 2>/dev/null || true)" >&2
    fails=$((fails + 1))
  fi
}
# expect_nolog <label> <payload> [VAR=value ...]: exit 0 and no new log line.
expect_nolog() {
  local label="$1" payload="$2" before after rc=0
  shift 2
  before="$(shadow_lines)"
  env ${1+"$@"} "$GUARD" <<<"$payload" >/dev/null 2>&1 || rc=$?
  after="$(shadow_lines)"
  if [ "$rc" = 0 ] && [ "$after" = "$before" ]; then
    printf '  PASS  %s\n' "$label"
  else
    printf 'FAIL: %s — rc=%s log %s→%s\n' "$label" "$rc" "$before" "$after" >&2
    fails=$((fails + 1))
  fi
}
# expect_silent <label> <payload> [VAR=value ...]: exit 0, no stdout/stderr at
# all, and no new log line (advisory mode emits nothing from either class).
expect_silent() {
  local label="$1" payload="$2" before after out rc=0
  shift 2
  before="$(shadow_lines)"
  out="$(env ${1+"$@"} "$GUARD" <<<"$payload" 2>&1)" || rc=$?
  after="$(shadow_lines)"
  if [ "$rc" = 0 ] && [ -z "$out" ] && [ "$after" = "$before" ]; then
    printf '  PASS  %s\n' "$label"
  else
    printf 'FAIL: %s — rc=%s output=[%s] log %s→%s\n' "$label" "$rc" "$out" "$before" "$after" >&2
    fails=$((fails + 1))
  fi
}
# tcase <code> <description> <payload>: the active run denies with exactly
# <code> (bound by expect), and the default shadow run logs one <code> line.
# These per-arm cases are not twin labels (the literal deny:/allow: expect
# lines below are); they pin each detector arm to the code it must emit.
tcase() {
  expect "deny:$1 $2" 2 "$(run_active "$3")"
  expect_shadow "shadow:$1 $2" "$1" "$3"
}

# --- T1-SKIP ---
p="$(edit_payload "$CS" '[Fact]' '[Fact(Skip = "flaky")]')"
expect "deny:T1-SKIP C# [Fact] -> [Fact(Skip = ...)]" 2 "$(run_active "$p")"
expect_shadow "shadow:T1-SKIP C# skip logged, call allowed" T1-SKIP "$p"
expect "deny:T1-SKIP C# NUnit [Ignore(...)] added" 2 "$(run_active "$(edit_payload "$CS" \
  '[Test]' "[Test]${NL}[Ignore(\"later\")]")")"
p="$(edit_payload "$PY" 'def test_add():' "@pytest.mark.skip(reason=\"flaky\")${NL}def test_add():")"
expect "deny:T1-SKIP Python @pytest.mark.skip added" 2 "$(run_active "$p")"
expect_shadow "shadow:T1-SKIP Python skip logged" T1-SKIP "$p"
p="$(edit_payload "$TSF" 'it("adds", () => {' 'it.skip("adds", () => {')"
expect "deny:T1-SKIP TS it( -> it.skip(" 2 "$(run_active "$p")"
expect_shadow "shadow:T1-SKIP TS skip logged" T1-SKIP "$p"
expect "deny:T1-SKIP TS it( -> it.only( (focus hides the rest)" 2 "$(run_active "$(edit_payload "$TSF" \
  'it("adds", () => {' 'it.only("adds", () => {')")"

# --- T2-SUPPRESS ---
p="$(edit_payload "$CS" 'var x = Calc.Add(1, 2);' "#pragma warning disable CS0219${NL}var x = Calc.Add(1, 2);")"
expect "deny:T2-SUPPRESS C# #pragma warning disable in a test" 2 "$(run_active "$p")"
expect_shadow "shadow:T2-SUPPRESS C# pragma logged" T2-SUPPRESS "$p"
p="$(edit_payload "$PY" 'from calc import add' 'from calc import add  # noqa: F401')"
expect "deny:T2-SUPPRESS Python # noqa added" 2 "$(run_active "$p")"
expect_shadow "shadow:T2-SUPPRESS Python noqa logged" T2-SUPPRESS "$p"
p="$(edit_payload "$TSF" 'const n: number = add(1, 2);' "// @ts-ignore${NL}const n: number = add(1, 2);")"
expect "deny:T2-SUPPRESS TS // @ts-ignore added" 2 "$(run_active "$p")"
expect_shadow "shadow:T2-SUPPRESS TS ts-ignore logged" T2-SUPPRESS "$p"
# Segment-shaped path (dir ending .Tests), plain basename.
expect "deny:T2-SUPPRESS C# file under a *.Tests directory is a test" 2 "$(run_active "$(edit_payload \
  "$P/src/Calc.Tests/Helpers.cs" 'var a = 1;' "#pragma warning disable CS0219${NL}var a = 1;")")"

# --- T3-FEWER-TESTS ---
CS_TWO="[Fact]${NL}public void Adds() { Assert.Equal(3, Calc.Add(1, 2)); }${NL}[Fact]${NL}public void Subs() { Assert.Equal(1, Calc.Sub(2, 1)); }"
CS_ONE="[Fact]${NL}public void Adds() { Assert.Equal(3, Calc.Add(1, 2)); }"
p="$(edit_payload "$CS" "$CS_TWO" "$CS_ONE")"
expect "deny:T3-FEWER-TESTS C# [Fact] method removed" 2 "$(run_active "$p")"
expect_shadow "shadow:T3-FEWER-TESTS C# removal logged" T3-FEWER-TESTS "$p"
expect "deny:T3-FEWER-TESTS C# [InlineData] row removed" 2 "$(run_active "$(edit_payload "$CS" \
  "[Theory]${NL}[InlineData(1, 2, 3)]${NL}[InlineData(2, 2, 4)]" \
  "[Theory]${NL}[InlineData(1, 2, 3)]")")"
mkdir -p "$P/tests/Calc.Tests"
printf 'public class CalcTests\n{\n%s\n}\n' "$CS_TWO" >"$CS"
p="$(write_payload "$CS" "$(printf 'public class CalcTests\n{\n%s\n}\n' "$CS_ONE")")"
expect "deny:T3-FEWER-TESTS Write over an existing test file drops a [Fact]" 2 "$(run_active "$p")"
expect_shadow "shadow:T3-FEWER-TESTS Write drop logged" T3-FEWER-TESTS "$p"
rm -f "$CS"
p="$(edit_payload "$PY" "def test_add():${NL}    assert add(1, 2) == 3${NL}${NL}def test_sub():${NL}    assert sub(2, 1) == 1" \
  "def test_add():${NL}    assert add(1, 2) == 3")"
expect "deny:T3-FEWER-TESTS Python def test_ removed" 2 "$(run_active "$p")"
expect_shadow "shadow:T3-FEWER-TESTS Python removal logged" T3-FEWER-TESTS "$p"
p="$(edit_payload "$TSF" "test(\"adds\", () => expect(add(1, 2)).toBe(3));${NL}test(\"subs\", () => expect(sub(2, 1)).toBe(1));" \
  'test("adds", () => expect(add(1, 2)).toBe(3));')"
expect "deny:T3-FEWER-TESTS TS test( removed" 2 "$(run_active "$p")"
expect_shadow "shadow:T3-FEWER-TESTS TS removal logged" T3-FEWER-TESTS "$p"

# --- T4-FEWER-ASSERTS ---
p="$(edit_payload "$CS" "Assert.Equal(3, sum);${NL}Assert.Equal(2, count);" 'Assert.Equal(3, sum);')"
expect "deny:T4-FEWER-ASSERTS C# Assert removed" 2 "$(run_active "$p")"
expect_shadow "shadow:T4-FEWER-ASSERTS C# removal logged" T4-FEWER-ASSERTS "$p"
p="$(edit_payload "$PY" "    assert total == 3${NL}    assert count == 2" '    assert total == 3')"
expect "deny:T4-FEWER-ASSERTS Python assert removed" 2 "$(run_active "$p")"
expect_shadow "shadow:T4-FEWER-ASSERTS Python removal logged" T4-FEWER-ASSERTS "$p"
p="$(edit_payload "$TSF" "expect(total).toBe(3);${NL}expect(count).toBe(2);" 'expect(total).toBe(3);')"
expect "deny:T4-FEWER-ASSERTS TS expect( removed" 2 "$(run_active "$p")"
expect_shadow "shadow:T4-FEWER-ASSERTS TS removal logged" T4-FEWER-ASSERTS "$p"

# --- T5-WEAKENED ---
p="$(edit_payload "$CS" 'Assert.Equal(expected, result);' 'Assert.NotNull(result);')"
expect "deny:T5-WEAKENED C# Assert.Equal(expected, result) -> Assert.NotNull(result)" 2 "$(run_active "$p")"
expect_shadow "shadow:T5-WEAKENED C# weakening logged" T5-WEAKENED "$p"
p="$(edit_payload "$PY" '    assert result == expected' '    assert result is not None')"
expect "deny:T5-WEAKENED Python == -> is not None" 2 "$(run_active "$p")"
expect_shadow "shadow:T5-WEAKENED Python weakening logged" T5-WEAKENED "$p"
p="$(edit_payload "$TSF" 'expect(result).toEqual(expected);' 'expect(result).toBeDefined();')"
expect "deny:T5-WEAKENED TS toEqual -> toBeDefined" 2 "$(run_active "$p")"
expect_shadow "shadow:T5-WEAKENED TS weakening logged" T5-WEAKENED "$p"

# --- Every remaining detector arm, one case each: denied (active) with exactly
# its own code, and logged with that code in shadow mode. Deleting an arm makes
# its case either pass silently or fall through to another code, and both fail.
# T1-SKIP
tcase T1-SKIP "TS it( -> xit(" "$(edit_payload "$TSF" 'it("adds", () => {' 'xit("adds", () => {')"
tcase T1-SKIP "TS describe( -> xdescribe(" \
  "$(edit_payload "$TSF" 'describe("calc", () => {' 'xdescribe("calc", () => {')"
tcase T1-SKIP "TS describe( -> describe.skip(" \
  "$(edit_payload "$TSF" 'describe("calc", () => {' 'describe.skip("calc", () => {')"
tcase T1-SKIP "TS describe( -> describe.only(" \
  "$(edit_payload "$TSF" 'describe("calc", () => {' 'describe.only("calc", () => {')"
tcase T1-SKIP "TS it( -> it.only( (focus hides the rest; T1 wins over the it( drop)" \
  "$(edit_payload "$TSF" 'it("adds", () => {' 'it.only("adds", () => {')"
tcase T1-SKIP "Python pytest.skip( added in a test body" \
  "$(edit_payload "$PY" '    result = add(1, 2)' "    pytest.skip(\"later\")${NL}    result = add(1, 2)")"
tcase T1-SKIP "Python @unittest.skip added" \
  "$(edit_payload "$PY" '    def test_add(self):' "    @unittest.skip(\"later\")${NL}    def test_add(self):")"
# T2-SUPPRESS
tcase T2-SUPPRESS "TS // @ts-expect-error added" \
  "$(edit_payload "$TSF" 'const n: number = add(1, 2);' "// @ts-expect-error${NL}const n: number = add(1, 2);")"
tcase T2-SUPPRESS "Python # type: ignore added" \
  "$(edit_payload "$PY" 'from calc import add' 'from calc import add  # type: ignore')"
tcase T2-SUPPRESS "TS /* eslint-disable */ added" \
  "$(edit_payload "$TSF" 'const n = add(1, 2);' "/* eslint-disable */${NL}const n = add(1, 2);")"
# T3-FEWER-TESTS
tcase T3-FEWER-TESTS "C# [Theory] removed" "$(edit_payload "$CS" \
  "[Theory]${NL}[InlineData(1)]${NL}public void Id(int x) { Assert.Equal(x, Calc.Id(x)); }" \
  "[InlineData(1)]${NL}public void Id(int x) { Assert.Equal(x, Calc.Id(x)); }")"
tcase T3-FEWER-TESTS "C# NUnit [Test] removed" "$(edit_payload "$CS" \
  "[Test]${NL}public void Adds() { Assert.That(Calc.Add(1, 2), Is.EqualTo(3)); }" \
  "public void Adds() { Assert.That(Calc.Add(1, 2), Is.EqualTo(3)); }")"
tcase T3-FEWER-TESTS "C# MSTest [TestMethod] removed" "$(edit_payload "$CS" \
  "[TestMethod]${NL}public void Adds() { Assert.AreEqual(3, Calc.Add(1, 2)); }" \
  "public void Adds() { Assert.AreEqual(3, Calc.Add(1, 2)); }")"
tcase T3-FEWER-TESTS "C# MSTest [DataRow( row removed" \
  "$(edit_payload "$CS" "[DataRow(1, 2)]${NL}[DataRow(2, 3)]" '[DataRow(1, 2)]')"
tcase T3-FEWER-TESTS "C# NUnit [TestCase( row removed" \
  "$(edit_payload "$CS" "[TestCase(1, 2)]${NL}[TestCase(2, 3)]" '[TestCase(1, 2)]')"
tcase T3-FEWER-TESTS "TS it( removed" "$(edit_payload "$TSF" \
  "it(\"adds\", () => expect(add(1, 2)).toBe(3));${NL}it(\"subs\", () => expect(sub(2, 1)).toBe(1));" \
  'it("adds", () => expect(add(1, 2)).toBe(3));')"
# T4-FEWER-ASSERTS
tcase T4-FEWER-ASSERTS "C# FluentAssertions .Should() removed" \
  "$(edit_payload "$CS" "sum.Should().Be(3);${NL}count.Should().Be(2);" 'sum.Should().Be(3);')"
tcase T4-FEWER-ASSERTS "Python self.assertEqual removed" "$(edit_payload "$PY" \
  "        self.assertEqual(total, 3)${NL}        self.assertEqual(count, 2)" '        self.assertEqual(total, 3)')"
# T5-WEAKENED
tcase T5-WEAKENED "TS toBe -> toBeTruthy" \
  "$(edit_payload "$TSF" 'expect(result).toBe(expected);' 'expect(result).toBeTruthy();')"
tcase T5-WEAKENED "TS toStrictEqual -> toBeDefined" \
  "$(edit_payload "$TSF" 'expect(result).toStrictEqual(expected);' 'expect(result).toBeDefined();')"
tcase T5-WEAKENED "C# Assert.Equal -> Assert.True (weak)" \
  "$(edit_payload "$CS" 'Assert.Equal(expected, result);' 'Assert.True(result);')"
tcase T5-WEAKENED "C# Assert.Throws (strong) -> Assert.NotNull" \
  "$(edit_payload "$CS" 'Assert.Throws<ArgumentException>(act);' 'Assert.NotNull(act);')"
tcase T5-WEAKENED "C# Assert.Same (strong) -> Assert.NotNull" \
  "$(edit_payload "$CS" 'Assert.Same(expected, result);' 'Assert.NotNull(result);')"

# Renaming a test is not removing one (T3 counts declarations, not names).
p="$(edit_payload "$PY" "def test_add():${NL}    assert add(1, 2) == 3" \
  "def test_add_returns_sum():${NL}    assert add(1, 2) == 3")"
expect "allow:T3-FEWER-TESTS renaming a Python test function" 0 "$(run_active "$p")"
expect_nolog "Python test rename logs nothing in shadow mode" "$p"
p="$(edit_payload "$TSF" 'it("adds", () => expect(add(1, 2)).toBe(3));' \
  'it("adds two numbers", () => expect(add(1, 2)).toBe(3));')"
expect "allow:T3-FEWER-TESTS renaming a TS it( test" 0 "$(run_active "$p")"
expect_nolog "TS test rename logs nothing in shadow mode" "$p"

# --- Deny message (active): names the signal and counts, says fix the code and
# STOP and ask, and teaches no toggle or approval recipe.
msg="$(MTK_TEST_GUARD_ENFORCE=active "$GUARD" 2>&1 >/dev/null <<<"$(edit_payload "$CS" "$CS_TWO" "$CS_ONE")" || true)"
check_msg "(test) names the file" 1 "tests/Calc.Tests/CalcTests.cs"
check_msg "(test) names the signal" 1 "T3-FEWER-TESTS"
check_msg "(test) names the counts" 1 "2→1"
check_msg "(test) says fix the code" 1 "Make the test pass by fixing the code."
check_msg "(test) says STOP and ask" 1 "If the engineer asked to remove or relax this test, STOP and ask them."
check_msg "(test) carries the continuation suffix" 1 "batched with it were CANCELLED"
check_msg "(test) teaches no toggle" 0 "disable this guard"
check_msg "(test) does not name the mode knob" 0 "MTK_TEST_GUARD"
check_msg "(test) does not print the approval list path" 0 "config-guard-allow"
msg="$(MTK_TEST_GUARD_ENFORCE=active "$GUARD" 2>&1 >/dev/null <<<"$(edit_payload "$CS" \
  'Assert.Equal(expected, result);' 'Assert.NotNull(result);')" || true)"
check_msg "(T5) names the weakened argument" 1 "'result'"

# --- Allow cases (test class active unless noted) ---
expect "allow:T1-SKIP new test file via Write to a missing path" 0 "$(run_active "$(write_payload \
  "$P/tests/NewTests.cs" "[Fact(Skip = \"wip\")]${NL}public void Later() { }")")"
expect "allow:T3-FEWER-TESTS adding a test" 0 "$(run_active "$(edit_payload "$CS" "$CS_ONE" "$CS_TWO")")"
expect "allow:T3-FEWER-TESTS renaming a test method" 0 "$(run_active "$(edit_payload "$CS" \
  "[Fact]${NL}public void Adds() { Assert.Equal(3, Calc.Add(1, 2)); }" \
  "[Fact]${NL}public void Add_ReturnsSum() { Assert.Equal(3, Calc.Add(1, 2)); }")")"
expect "allow:T4-FEWER-ASSERTS assertion moved, count equal" 0 "$(run_active "$(edit_payload "$CS" \
  "Assert.Equal(3, sum);${NL}var y = 2;" "var y = 2;${NL}Assert.Equal(3, sum);")")"
expect "allow:T5-WEAKENED Assert.Equal -> Assert.Equivalent" 0 "$(run_active "$(edit_payload "$CS" \
  'Assert.Equal(expected, result);' 'Assert.Equivalent(expected, result);')")"
expect "allow:T5-WEAKENED Assert.Equal(true, ok) -> Assert.True(ok) (boolean check)" 0 "$(run_active "$(edit_payload "$CS" \
  'Assert.Equal(true, ok);' 'Assert.True(ok);')")"
expect "allow:T5-WEAKENED strong assertion kept beside a new weak one" 0 "$(run_active "$(edit_payload "$CS" \
  'Assert.Equal(expected, result);' "Assert.NotNull(result);${NL}Assert.Equal(expected, result);")")"
expect "allow:T2-SUPPRESS non-test src/Foo.cs with #pragma warning disable (test guard active)" 0 \
  "$(run_active "$(edit_payload "$P/src/Foo.cs" '// ok' '#pragma warning disable CA2007')")"
expect_nolog "non-test src/Foo.cs in shadow mode logs nothing" \
  "$(edit_payload "$P/src/Foo.cs" '// ok' '#pragma warning disable CA2007')"
expect "allow:T3-FEWER-TESTS split( / emit( / latest( / commit( are not tests" 0 "$(run_active "$(edit_payload "$TSF" \
  "const parts = line.split(\",\");${NL}emit(parts);${NL}const v = latest(xs);${NL}commit(tx);" \
  'const parts = line.split(",");')")"
expect "allow:T1-SKIP [IgnoreDataMember] is not a skip" 0 "$(run_active "$(edit_payload "$CS" \
  'public string Name { get; set; }' "[IgnoreDataMember]${NL}public string Name { get; set; }")")"
expect "allow:T3-FEWER-TESTS tests/hooks/test-x.sh (bash) is not a code file" 0 "$(run_active "$(edit_payload \
  "$P/tests/hooks/test-x.sh" "it(\"a\")${NL}it(\"b\")" 'it("a")  # noqa')")"
expect "allow:T1-SKIP MTK_TEST_GUARD_ENFORCE=off" 0 "$(MTK_TEST_GUARD_ENFORCE=off "$GUARD" \
  <<<"$(edit_payload "$CS" '[Fact]' '[Fact(Skip = "flaky")]')" >/dev/null 2>&1 && echo 0 || echo $?)"
expect_nolog "MTK_TEST_GUARD_ENFORCE=off logs nothing" \
  "$(edit_payload "$CS" '[Fact]' '[Fact(Skip = "flaky")]')" MTK_TEST_GUARD_ENFORCE=off

# Approval list (fresh, exact repo-relative path) covers test files too.
printf 'tests/Calc.Tests/CalcTests.cs\n' >"$P/.mtk/config-guard-allow"
expect "allow:T1-SKIP path on a fresh approval list" 0 "$(run_active "$(edit_payload "$CS" \
  '[Fact]' '[Fact(Skip = "flaky")]')")"
expect_nolog "approved test path logs nothing in shadow mode" "$(edit_payload "$CS" '[Fact]' '[Fact(Skip = "flaky")]')"
rm -f "$P/.mtk/config-guard-allow"

# --- Classifier: one deny per test-path pattern, each on its own path, plus
# look-alikes that must stay outside the test class. Every case adds the same
# kind of suppression, so a deny can only come from the path being classified.
ts_sup() { edit_payload "$1" 'const n = add(1, 2);' "// @ts-ignore${NL}const n = add(1, 2);"; }
cs_sup() { edit_payload "$1" 'var a = 1;' "#pragma warning disable CS0219${NL}var a = 1;"; }
py_sup() { edit_payload "$1" 'from calc import add' 'from calc import add  # noqa: F401'; }
expect "deny:T2-SUPPRESS classifier *.spec.*: src/a.spec.ts" 2 "$(run_active "$(ts_sup "$P/src/a.spec.ts")")"
expect "deny:T2-SUPPRESS classifier *.test.* (.js): src/a.test.js" 2 "$(run_active "$(ts_sup "$P/src/a.test.js")")"
expect "deny:T2-SUPPRESS classifier *Test.cs: src/FooTest.cs" 2 "$(run_active "$(cs_sup "$P/src/FooTest.cs")")"
expect "deny:T2-SUPPRESS classifier *Tests.cs outside a tests dir: src/FooTests.cs" 2 \
  "$(run_active "$(cs_sup "$P/src/FooTests.cs")")"
expect "deny:T2-SUPPRESS classifier *_test.py: pkg/x_test.py" 2 "$(run_active "$(py_sup "$P/pkg/x_test.py")")"
expect "deny:T2-SUPPRESS classifier test_*.py outside a tests dir: pkg/test_x.py" 2 \
  "$(run_active "$(py_sup "$P/pkg/test_x.py")")"
expect "deny:T2-SUPPRESS classifier __tests__ segment: src/__tests__/a.ts" 2 \
  "$(run_active "$(ts_sup "$P/src/__tests__/a.ts")")"
expect "deny:T2-SUPPRESS classifier test segment: test/a.py" 2 "$(run_active "$(py_sup "$P/test/a.py")")"
expect "deny:T2-SUPPRESS classifier uppercase TESTS segment: TESTS/a.py" 2 "$(run_active "$(py_sup "$P/TESTS/a.py")")"
expect "deny:T2-SUPPRESS classifier *.Test segment: X.Test/a.cs" 2 "$(run_active "$(cs_sup "$P/X.Test/a.cs")")"
expect "allow:T2-SUPPRESS look-alike src/testing/x.ts is not a test" 0 "$(run_active "$(ts_sup "$P/src/testing/x.ts")")"
expect "allow:T2-SUPPRESS look-alike contest.py is not a test" 0 "$(run_active "$(py_sup "$P/contest.py")")"
expect "allow:T2-SUPPRESS look-alike latest.js is not a test" 0 "$(run_active "$(ts_sup "$P/latest.js")")"
expect_nolog "look-alike src/testing/x.ts logs nothing in shadow mode" "$(ts_sup "$P/src/testing/x.ts")"
expect_nolog "look-alike contest.py logs nothing in shadow mode" "$(py_sup "$P/contest.py")"
expect_nolog "look-alike latest.js logs nothing in shadow mode" "$(ts_sup "$P/latest.js")"

# --- Innocent edits on real test files: denied in neither mode (active: exit 0;
# shadow: exit 0 and no log line).
p="$(edit_payload "$CS" '[Fact(Skip="x")]' '[Fact]')"
expect "allow:T1-SKIP un-skipping [Fact(Skip=\"x\")] -> [Fact]" 0 "$(run_active "$p")"
expect_nolog "un-skipping logs nothing in shadow mode" "$p"
p="$(edit_payload "$CS" "[Fact(Skip = \"flaky\")]${NL}public void Adds() { Assert.Equal(3, Calc.Add(1, 2)); }" \
  "[Fact(Skip = \"flaky\")]${NL}public void Adds() { Assert.Equal(3, Calc.Add(2, 1)); }")"
expect "allow:T1-SKIP body edited while an existing skip stays" 0 "$(run_active "$p")"
expect_nolog "body edit beside an existing skip logs nothing in shadow mode" "$p"
p="$(edit_payload "$CS" "#pragma warning disable CS0219${NL}var x = Calc.Add(1, 2);" \
  "#pragma warning disable CS0219${NL}var x = Calc.Add(2, 1);")"
expect "allow:T2-SUPPRESS body edited while an existing #pragma stays" 0 "$(run_active "$p")"
expect_nolog "body edit beside an existing #pragma logs nothing in shadow mode" "$p"
mkdir -p "$P/tests/Calc.Tests"
printf 'public class CalcTests\n{\n%s\n}\n' "$CS_ONE" >"$CS"
p="$(write_payload "$CS" "$(printf 'public class CalcTests\n{\n%s\n}\n' "$CS_TWO")")"
expect "allow:T3-FEWER-TESTS Write over an existing test file that adds a [Fact]" 0 "$(run_active "$p")"
expect_nolog "Write that adds a test logs nothing in shadow mode" "$p"
SKIPPED="[Fact(Skip = \"flaky\")]${NL}public void Later() { }"
printf 'public class CalcTests\n{\n%s\n%s\n}\n' "$SKIPPED" "$CS_ONE" >"$CS"
p="$(write_payload "$CS" "$(printf 'public class CalcTests\n{\n%s\n%s\n}\n' "$SKIPPED" \
  "${CS_ONE/Adds()/Add_ReturnsSum()}")")"
expect "allow:T3-FEWER-TESTS Write over an existing test file that keeps every count (skip kept)" 0 "$(run_active "$p")"
expect_nolog "Write that keeps every count logs nothing in shadow mode" "$p"
rm -f "$CS"

# --- A failed test-signal scan fails open, but visibly: one stderr line, exit 0,
# no log line. An awk shim fails only the test-class scan (its program is the one
# using PEND), so every other awk call still runs.
SHIM="$SANDBOX/shim"
mkdir -p "$SHIM"
REAL_AWK="$(command -v awk)"
printf '#!/usr/bin/env bash\ncase "$*" in *PEND*) exit 2 ;; esac\nexec %q "$@"\n' "$REAL_AWK" >"$SHIM/awk"
chmod +x "$SHIM/awk"
p="$(edit_payload "$CS" '[Fact]' '[Fact(Skip = "flaky")]')"
before="$(shadow_lines)"
rc=0
err="$(PATH="$SHIM:$PATH" MTK_TEST_GUARD_ENFORCE=active "$GUARD" <<<"$p" 2>&1 >/dev/null)" || rc=$?
after="$(shadow_lines)"
if [ "$rc" = 0 ] && [ "$err" = "[mtk] config-guard: test-signal scan failed; test class not evaluated" ] \
  && [ "$after" = "$before" ]; then
  printf '  PASS  %s\n' "failed test-signal scan: exit 0, one stderr line, no log line"
else
  printf 'FAIL: failed test-signal scan — rc=%s stderr=[%s] log %s→%s\n' "$rc" "$err" "$before" "$after" >&2
  fails=$((fails + 1))
fi
rc=0
err="$(PATH="$SHIM:$PATH" "$GUARD" <<<"$p" 2>&1 >/dev/null)" || rc=$?
case "$rc:$err" in
  "0:[mtk] config-guard: test-signal scan failed; test class not evaluated")
    printf '  PASS  %s\n' "failed test-signal scan in shadow mode: same stderr line" ;;
  *) printf 'FAIL: failed test-signal scan (shadow) — rc=%s stderr=[%s]\n' "$rc" "$err" >&2; fails=$((fails + 1)) ;;
esac

# Config class wins on overlap: a csproj in a *.Tests directory is still config,
# so it denies with the test guard off.
expect "deny:W1-SUPPRESS Foo.Tests/Foo.Tests.csproj stays config class (test guard off)" 2 \
  "$(run_with "$(edit_payload "$P/Foo.Tests/Foo.Tests.csproj" \
    '<NoWarn></NoWarn>' '<NoWarn>CS1591</NoWarn>')" MTK_TEST_GUARD_ENFORCE=off)"
# Config class honours its own mode knob: shadow logs and allows.
expect_shadow "shadow:W1-SUPPRESS MTK_CONFIG_GUARD_ENFORCE=shadow logs a config weakening" W1-SUPPRESS \
  "$(edit_payload "$P/Directory.Build.props" '<NoWarn></NoWarn>' '<NoWarn>CS1591</NoWarn>')" \
  MTK_CONFIG_GUARD_ENFORCE=shadow
expect_shadow "shadow:W2-DISABLED MTK_CONFIG_GUARD_ENFORCE=shadow logs a disabled value" W2-DISABLED \
  "$(edit_payload "$P/.editorconfig" 'dotnet_diagnostic.CA1062.severity = error' \
    'dotnet_diagnostic.CA1062.severity = none')" \
  MTK_CONFIG_GUARD_ENFORCE=shadow
expect_shadow "shadow:W3-IGNORE MTK_CONFIG_GUARD_ENFORCE=shadow logs an ignore-file line" W3-IGNORE \
  "$(edit_payload "$P/.eslintignore" "dist/" "dist/${NL}src/legacy/")" \
  MTK_CONFIG_GUARD_ENFORCE=shadow

# Advisory mode: neither class has one. `advisory` must not silently disable a
# guard (it used to behave as off), so it falls back to the class default with
# one stderr line: the config class still denies, the test class still logs.
ADV_RC="$(run_with "$(edit_payload "$P/Directory.Build.props" '<NoWarn></NoWarn>' '<NoWarn>CS1591</NoWarn>')" \
  MTK_CONFIG_GUARD_ENFORCE=advisory)"
ADV_ERR="$(cat "$LAST_ERR" 2>/dev/null || true)"
case "$ADV_ERR" in
  *"MTK_CONFIG_GUARD_ENFORCE=advisory not supported by config-guard; using active"*)
    printf '  PASS  %s\n' "advisory (config class): stderr names the fallback to active" ;;
  *) printf 'FAIL: advisory (config class) — no fallback line. Stderr: %s\n' "$ADV_ERR" >&2
     fails=$((fails + 1)) ;;
esac
expect "deny:W1-SUPPRESS advisory falls back to active: config weakening still denied" 2 "$ADV_RC"

ADV_BEFORE="$(shadow_lines)"
ADV_RC=0
ADV_OUT="$(env MTK_TEST_GUARD_ENFORCE=advisory "$GUARD" <<<"$(edit_payload "$CS" '[Fact]' '[Fact(Skip = "flaky")]')" 2>&1)" || ADV_RC=$?
ADV_AFTER="$(shadow_lines)"
ADV_LAST="$(tail -n 1 "$SHADOW_LOG" 2>/dev/null || true)"
case "$ADV_RC|$ADV_OUT|$ADV_LAST" in
  "0|"*"MTK_TEST_GUARD_ENFORCE=advisory not supported by config-guard; using shadow"*'"code":"T1-SKIP"'*)
    if [ "$ADV_AFTER" = "$((ADV_BEFORE + 1))" ]; then
      printf '  PASS  %s\n' "advisory (test class): falls back to shadow, one T1-SKIP line logged"
    else
      printf 'FAIL: advisory (test class) — log %s→%s\n' "$ADV_BEFORE" "$ADV_AFTER" >&2
      fails=$((fails + 1))
    fi ;;
  *) printf 'FAIL: advisory (test class) — rc=%s out=[%s] last=[%s]\n' "$ADV_RC" "$ADV_OUT" "$ADV_LAST" >&2
     fails=$((fails + 1)) ;;
esac

# The approval list itself stays protected in every mode (R13).
for m in off shadow active; do
  got="$(MTK_TEST_GUARD_ENFORCE="$m" MTK_CONFIG_GUARD_ENFORCE="$m" "$GUARD" \
    <<<"$(write_payload "$P/.mtk/config-guard-allow" "tests/Calc.Tests/CalcTests.cs")" >/dev/null 2>&1 \
    && echo 0 || echo $?)"
  expect "approval list Write denied with every MTK_*_ENFORCE=$m" 2 "$got"
done

# Only the repo-relative path is read: a repo checked out under a parent named
# tests does not make src/Foo.cs a test (and its own tests/ still classify).
TR="$SANDBOX/tests/repo"
mkdir -p "$TR/src" "$TR/.mtk"
expect "allow:T2-SUPPRESS repo under a parent dir named tests: src/Foo.cs is not a test" 0 \
  "$(CLAUDE_PROJECT_DIR="$TR" MTK_TEST_GUARD_ENFORCE=active "$GUARD" <<<"$(edit_payload "$TR/src/Foo.cs" \
    '// ok' '#pragma warning disable CA2007')" >/dev/null 2>&1 && echo 0 || echo $?)"
expect "deny:T2-SUPPRESS repo under a parent dir named tests: its tests/FooTests.cs still is" 2 \
  "$(run_with "$(edit_payload "$TR/tests/FooTests.cs" '// ok' '#pragma warning disable CA2007')" \
    CLAUDE_PROJECT_DIR="$TR" MTK_TEST_GUARD_ENFORCE=active)"

# ============================ SC4: nested git worktree =========================
# A file in a worktree under the project (.claude/worktrees/<name>/) belongs to
# that worktree: its path is reported relative to the worktree root, and the
# approval list is the worktree's own .mtk/config-guard-allow. Before the fix the
# guard took the root from CLAUDE_PROJECT_DIR (the main checkout), so the
# approval had to name ".claude/worktrees/<name>/..." in the main checkout.
if command -v git >/dev/null 2>&1; then
  ( cd "$P" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
  ( cd "$P" && git worktree add -q .claude/worktrees/wt -b wt-branch )
  WT="$P/.claude/worktrees/wt"
  printf '<Project><PropertyGroup><NoWarn></NoWarn></PropertyGroup></Project>\n' > "$WT/Directory.Build.props"
  wt_edit="$(edit_payload "$WT/Directory.Build.props" '<NoWarn></NoWarn>' '<NoWarn>CS1591;CA1707</NoWarn>')"

  expect "deny:W1-SUPPRESS worktree: weakening edit denied" 2 "$(run_guard "$wt_edit")"
  wt_msg="$("$GUARD" <<<"$wt_edit" 2>&1 || true)"
  case "$wt_msg" in
    *"weakens Directory.Build.props"*) printf '  PASS  %s\n' "worktree: path reported relative to the worktree root" ;;
    *) printf 'FAIL: worktree path not worktree-relative: %s\n' "$wt_msg" >&2; fails=$((fails + 1)) ;;
  esac

  mkdir -p "$WT/.mtk"
  printf 'Directory.Build.props\n' > "$WT/.mtk/config-guard-allow"
  expect "allow:W1-SUPPRESS worktree: approval in the worktree's own .mtk allows" 0 "$(run_guard "$wt_edit")"
  rm -f "$WT/.mtk/config-guard-allow"

  printf '.claude/worktrees/wt/Directory.Build.props\n' > "$P/.mtk/config-guard-allow"
  expect "deny:W1-SUPPRESS worktree: approval in the main checkout does not leak into the worktree" 2 "$(run_guard "$wt_edit")"
  rm -f "$P/.mtk/config-guard-allow"

  expect "worktree: the worktree's approval list itself is protected" 2 "$(run_guard "$(write_payload \
    "$WT/.mtk/config-guard-allow" "Directory.Build.props")")"
else
  printf '  SKIP  nested-worktree assertions (git not available)\n'
fi

killed="$(MTK_CONFIG_GUARD=0 "$GUARD" >/dev/null 2>&1 \
  <<<"$(edit_payload "$P/Directory.Build.props" '<NoWarn></NoWarn>' '<NoWarn>CS1591</NoWarn>')" \
  && echo 0 || echo $?)"
expect "allow:W1-SUPPRESS MTK_CONFIG_GUARD=0 disables guard" 0 "$killed"

empty="$(printf '' | "$GUARD" >/dev/null 2>&1 && echo 0 || echo $?)"
expect "empty payload fails open" 0 "$empty"

garbage="$(printf 'not json at all {{{' | "$GUARD" >/dev/null 2>&1 && echo 0 || echo $?)"
expect "garbage payload fails open" 0 "$garbage"

expect "non-Edit/Write tool ignored" 0 "$(run_guard \
  "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$P/.editorconfig\"}}")"

# ============================ T4: wiring =========================================
# hooks.json (the only hook registration) parsed as JSON, exact event key + matcher: a
# typo'd event key must fail this.
if command -v python3 >/dev/null 2>&1; then
  for wf in hooks/hooks.json; do
    got="$(python3 - "$REPO_ROOT/$wf" PreToolUse 'Edit|Write' config-guard.sh <<'PY'
import json, sys
path, event, matcher, base = sys.argv[1:5]
try:
    hooks = json.load(open(path)).get("hooks", {})
except (OSError, ValueError) as exc:
    print("unparseable: %s" % exc); sys.exit(0)
for m in hooks.get(event, []) or []:
    if (m.get("matcher") or "") == matcher and any(
            h.get("command", "").rstrip().rstrip('"').endswith("/hooks/" + base) for h in m.get("hooks", []) or []):
        print("wired"); sys.exit(0)
print("missing")
PY
)"
    if [ "$got" = "wired" ]; then
      printf '  PASS  %s wires config-guard.sh under PreToolUse "Edit|Write"\n' "$wf"
    else
      printf 'FAIL: %s: config-guard.sh not wired under PreToolUse "Edit|Write" (%s)\n' "$wf" "$got" >&2
      fails=$((fails + 1))
    fi
  done
else
  printf '  SKIP  wiring assertions (python3 not available)\n'
fi

if [ "$fails" -ne 0 ]; then
  printf '\n%s assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf '\nconfig-guard: all assertions passed\n'
