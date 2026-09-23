#!/usr/bin/env bash
set -euo pipefail

# config-guard.sh denies Edit/Write that WEAKEN linter/analyzer/formatter config
# (SC1), passes every non-weakening edit (SC2), and never teaches the model how
# to approve its own suppression (SC3).
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

# Runs the guard with payload $1; echoes the exit code.
# Here-string, not a pipe: the guard may exit before reading stdin (kill-switch),
# and a pipe would then fail the printf with EPIPE under pipefail.
run_guard() {
  "$GUARD" <<<"$1" >/dev/null 2>&1 && echo 0 || echo $?
}

expect() {
  local label="$1" want="$2" got="$3"
  if [ "$got" != "$want" ]; then
    printf 'FAIL: %s — expected exit %s, got %s\n' "$label" "$want" "$got" >&2
    fails=$((fails + 1))
  else
    printf '  PASS  %s\n' "$label"
  fi
}

P="$PROJ"
NL=$'\n'

# ============================ SC1: weakening edits deny ========================

# shellcheck disable=SC2016  # $(NoWarn) is literal MSBuild text, not a shell expansion
expect "NoWarn code added to Directory.Build.props" 2 "$(run_guard "$(edit_payload \
  "$P/Directory.Build.props" \
  '<NoWarn>$(NoWarn);CS1591</NoWarn>' \
  '<NoWarn>$(NoWarn);CS1591;CA2007</NoWarn>')")"

expect "editorconfig severity set to none" 2 "$(run_guard "$(edit_payload \
  "$P/.editorconfig" \
  'dotnet_diagnostic.CA1062.severity = error' \
  'dotnet_diagnostic.CA1062.severity = none')")"

expect "editorconfig severity set to suggestion" 2 "$(run_guard "$(edit_payload \
  "$P/.editorconfig" \
  'dotnet_diagnostic.IDE0055.severity = warning' \
  'dotnet_diagnostic.IDE0055.severity = suggestion')")"

expect "TreatWarningsAsErrors flipped to false in csproj" 2 "$(run_guard "$(edit_payload \
  "$P/src/App/App.csproj" \
  '<TreatWarningsAsErrors>true</TreatWarningsAsErrors>' \
  '<TreatWarningsAsErrors>false</TreatWarningsAsErrors>')")"

expect "eslint rule set to \"off\"" 2 "$(run_guard "$(edit_payload \
  "$P/eslint.config.mjs" \
  '"no-console": "error",' \
  '"no-console": "off",')")"

expect "ruff ignore code added (single line)" 2 "$(run_guard "$(edit_payload \
  "$P/pyproject.toml" \
  'ignore = ["E501"]' \
  'ignore = ["E501", "F401"]')")"

expect "ruff ignore code added (multi-line list)" 2 "$(run_guard "$(edit_payload \
  "$P/ruff.toml" \
  "ignore = [${NL}  \"E501\",${NL}]" \
  "ignore = [${NL}  \"E501\",${NL}  \"F401\",${NL}]")")"

expect ".eslintignore line added" 2 "$(run_guard "$(edit_payload \
  "$P/.eslintignore" \
  "dist/" \
  "dist/${NL}src/legacy/")")"

printf '<Project>\n  <PropertyGroup>\n    <Nullable>enable</Nullable>\n  </PropertyGroup>\n</Project>\n' \
  > "$P/Directory.Build.props"
expect "Write to existing props that adds NoWarn" 2 "$(run_guard "$(write_payload \
  "$P/Directory.Build.props" \
  "$(printf '<Project>\n  <PropertyGroup>\n    <Nullable>enable</Nullable>\n    <NoWarn>CS8618</NoWarn>\n  </PropertyGroup>\n</Project>\n')")")"

expect "uppercase DIRECTORY.BUILD.PROPS still protected" 2 "$(run_guard "$(edit_payload \
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
expect "extraction round-trip: escaped quote + multi-line, weakening on line 3" 2 \
  "$(run_guard "$rt_payload")"
# Control: same shape, non-weakening — proves the deny above is the line-3 value.
expect "extraction round-trip control (no weakening) allowed" 0 "$(run_guard "$(edit_payload \
  "$P/.editorconfig" "$RT_OLD" "${RT_OLD/indent_size = 4/indent_size = 2}")")"

# --- T1: the remaining W2 disabled-value signals, each with a non-weakening control.
# Each control keeps the same key and file so the deny above it can only come from
# the value flipping to its disabled form.
expect "AnalysisLevel set to none" 2 "$(run_guard "$(edit_payload \
  "$P/Directory.Build.props" \
  '<AnalysisLevel>latest</AnalysisLevel>' \
  '<AnalysisLevel>none</AnalysisLevel>')")"
expect "AnalysisLevel control: latest -> preview allowed" 0 "$(run_guard "$(edit_payload \
  "$P/Directory.Build.props" \
  '<AnalysisLevel>latest</AnalysisLevel>' \
  '<AnalysisLevel>preview</AnalysisLevel>')")"

expect "AnalysisMode set to None" 2 "$(run_guard "$(edit_payload \
  "$P/src/App/App.csproj" \
  '<AnalysisMode>All</AnalysisMode>' \
  '<AnalysisMode>None</AnalysisMode>')")"
expect "AnalysisMode control: Default -> All allowed" 0 "$(run_guard "$(edit_payload \
  "$P/src/App/App.csproj" \
  '<AnalysisMode>Default</AnalysisMode>' \
  '<AnalysisMode>All</AnalysisMode>')")"

expect "mypy ignore_errors = true" 2 "$(run_guard "$(edit_payload \
  "$P/mypy.ini" \
  'ignore_errors = false' \
  'ignore_errors = true')")"
expect "mypy ignore_errors control: true -> false allowed" 0 "$(run_guard "$(edit_payload \
  "$P/mypy.ini" \
  'ignore_errors = true' \
  'ignore_errors = false')")"

expect "biome \"recommended\": false" 2 "$(run_guard "$(edit_payload \
  "$P/biome.json" \
  '"recommended": true' \
  '"recommended": false')")"
expect "biome recommended control: false -> true allowed" 0 "$(run_guard "$(edit_payload \
  "$P/biome.json" \
  '"recommended": false' \
  '"recommended": true')")"

expect "WarningLevel set to 0" 2 "$(run_guard "$(edit_payload \
  "$P/src/App/App.csproj" \
  '<WarningLevel>4</WarningLevel>' \
  '<WarningLevel>0</WarningLevel>')")"
expect "WarningLevel control: 4 -> 9999 allowed (not a 0 prefix match)" 0 "$(run_guard "$(edit_payload \
  "$P/src/App/App.csproj" \
  '<WarningLevel>4</WarningLevel>' \
  '<WarningLevel>9999</WarningLevel>')")"

expect "Nullable set to disable" 2 "$(run_guard "$(edit_payload \
  "$P/Directory.Build.props" \
  '<Nullable>enable</Nullable>' \
  '<Nullable>disable</Nullable>')")"
expect "Nullable control: warnings -> enable allowed" 0 "$(run_guard "$(edit_payload \
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

printf 'Directory.Build.props\n' > "$P/.mtk/config-guard-allow"
touch -t 202001010000 "$P/.mtk/config-guard-allow"
expect "stale approval list (>24h) does not approve" 2 "$(run_guard "$(edit_payload \
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
check_msg "names the signal" 1 "W2 disabled values"
check_msg "says STOP and ask" 1 "STOP and ask"
check_msg "carries the continuation suffix" 1 "batched with it were CANCELLED"
check_msg "teaches no toggle" 0 "disable this guard"
check_msg "does not name the kill-switch" 0 "MTK_CONFIG_GUARD"
check_msg "does not print the approval list path" 0 "config-guard-allow"

# ============================ SC2: non-weakening edits pass ====================

expect "severity error -> warning is not weakening" 0 "$(run_guard "$(edit_payload \
  "$P/.editorconfig" \
  'dotnet_diagnostic.CA1062.severity = error' \
  'dotnet_diagnostic.CA1062.severity = warning')")"

expect "stricter rule added to editorconfig" 0 "$(run_guard "$(edit_payload \
  "$P/.editorconfig" \
  'dotnet_diagnostic.CA1062.severity = warning' \
  "dotnet_diagnostic.CA1062.severity = warning${NL}dotnet_diagnostic.CA2007.severity = error")")"

expect "WarningsAsErrors code added (stricter) allowed" 0 "$(run_guard "$(edit_payload \
  "$P/Directory.Build.props" \
  "<NoWarn>CS1591</NoWarn>" \
  "<NoWarn>CS1591</NoWarn>${NL}    <WarningsAsErrors>CS8600</WarningsAsErrors>")")"

expect "NoWarn code removed allowed" 0 "$(run_guard "$(edit_payload \
  "$P/Directory.Build.props" \
  '<NoWarn>CS1591;CA2007</NoWarn>' '<NoWarn>CS1591</NoWarn>')")"

expect "version bump in csproj" 0 "$(run_guard "$(edit_payload \
  "$P/src/App/App.csproj" \
  '<PackageReference Include="Serilog" Version="3.1.1" />' \
  '<PackageReference Include="Serilog" Version="4.0.2" />')")"

expect "eslint rule tightened warn -> error" 0 "$(run_guard "$(edit_payload \
  "$P/eslint.config.mjs" '"no-console": "warn",' '"no-console": "error",')")"

expect ".eslintignore negation line added (un-ignores)" 0 "$(run_guard "$(edit_payload \
  "$P/.eslintignore" "dist/" "dist/${NL}!dist/keep.js")")"

rm -f "$P/.editorconfig"
expect "new .editorconfig via Write to a missing path" 0 "$(run_guard "$(write_payload \
  "$P/.editorconfig" "$(printf 'root = true\n[*.cs]\ndotnet_diagnostic.CA1062.severity = none\n')")")"

expect "non-protected file (src/Foo.cs)" 0 "$(run_guard "$(edit_payload \
  "$P/src/Foo.cs" '// ok' '#pragma warning disable CA2007')")"

printf 'Directory.Build.props\n' > "$P/.mtk/config-guard-allow"
expect "path on a fresh approval list allowed" 0 "$(run_guard "$(edit_payload \
  "$P/Directory.Build.props" '<NoWarn></NoWarn>' '<NoWarn>CS1591</NoWarn>')")"
# The approval lookup normalises ./ and ../ too, so an approved path still matches.
expect "approved path spelled with ../ segment still allowed" 0 "$(run_guard "$(edit_payload \
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

killed="$(MTK_CONFIG_GUARD=0 "$GUARD" >/dev/null 2>&1 \
  <<<"$(edit_payload "$P/Directory.Build.props" '<NoWarn></NoWarn>' '<NoWarn>CS1591</NoWarn>')" \
  && echo 0 || echo $?)"
expect "MTK_CONFIG_GUARD=0 disables guard" 0 "$killed"

empty="$(printf '' | "$GUARD" >/dev/null 2>&1 && echo 0 || echo $?)"
expect "empty payload fails open" 0 "$empty"

garbage="$(printf 'not json at all {{{' | "$GUARD" >/dev/null 2>&1 && echo 0 || echo $?)"
expect "garbage payload fails open" 0 "$garbage"

expect "non-Edit/Write tool ignored" 0 "$(run_guard \
  "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$P/.editorconfig\"}}")"

# ============================ T4: wiring =========================================
# hooks.json + .claude/settings.json parsed as JSON, exact event key + matcher: a
# typo'd event key must fail this.
if command -v python3 >/dev/null 2>&1; then
  for wf in hooks/hooks.json .claude/settings.json; do
    got="$(python3 - "$REPO_ROOT/$wf" PreToolUse 'Edit|Write' config-guard.sh <<'PY'
import json, sys
path, event, matcher, base = sys.argv[1:5]
try:
    hooks = json.load(open(path)).get("hooks", {})
except (OSError, ValueError) as exc:
    print("unparseable: %s" % exc); sys.exit(0)
for m in hooks.get(event, []) or []:
    if (m.get("matcher") or "") == matcher and any(
            h.get("command", "").rstrip().endswith("/hooks/" + base) for h in m.get("hooks", []) or []):
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
