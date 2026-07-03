#!/usr/bin/env bash
set -euo pipefail

# Test: scripts/setup-detect.sh (F2 — mechanized stack/package-manager/
# React-Native/monorepo detection for setup-bootstrap). Builds fixture repos
# in mktemp dirs and asserts the JSON contract from
# docs/specs/2026-07-03-v719-setup-improvements.md (F2) and
# docs/plans/2026-07-03-v719-setup-improvements.md (## B1):
#   (a) dotnet single (x.sln + one csproj) -> stacks=["dotnet"],
#       primary_candidate="dotnet"
#   (b) typescript + pnpm-lock.yaml + app.json + "expo" dep in package.json
#       -> package_manager="pnpm", react_native.detected=true, expo=true
#   (c) pnpm-workspace monorepo with 3 packages -> monorepo.is_monorepo=true,
#       3 entries in monorepo.packages
#   (d) mixed ts+dotnet -> stacks length 2, primary_candidate="",
#       monorepo.ambiguous=true, monorepo.signals=[] (T-F001; locked in by
#       running the script against this fixture — neither the monorepo nor
#       the not-a-monorepo STEP 4.5 rule clearly matches it)
#   (e) nx.json only, non-conventional project dirs, no workspaces field
#       -> monorepo.is_monorepo=true with packages == [] (documented
#       limitation: turbo/nx/rush/lerna configs are classification signals
#       only, not package-enumeration glob sources)
#   (f) pnpm-workspace with 25 package dirs -> packages capped at 20,
#       packages_skipped=5 (T-F002)
#   (g) go.mod only -> go_detected=true (T-F003)
#   (h) typescript with both pnpm-lock.yaml and package-lock.json ->
#       multiple_lockfiles=true, package_manager="pnpm" (priority) (T-F003)
#   (i) S-F001 regression: malformed (trailing-comma) package.json whose
#       "scripts" block contains "react-native"/"expo" keys ->
#       react_native.detected=false (the scoped dependencies/devDependencies
#       fallback never sees the scripts block) and "package.json" is
#       recorded in the new parse_errors array
#   (j) DF-11 regression: root package.json (no RN) + non-monorepo sibling
#       mobile/package.json with an "expo" dep -> react_native.detected=true
#       and react_native.expo=true (nested first-level package dirs are now
#       scanned, not just the root package.json)
#
# Each fixture is a throwaway directory under mktemp — the script itself is
# invoked via its real path in THIS repo but with CWD set to the fixture, so
# detection only ever sees the fixture's files. Exit-1-on-failure style (no
# subshell pass/fail counters — lesson 2026-04-23).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DETECT="$REPO_ROOT/scripts/setup-detect.sh"

echo "=== setup-detect Test (F2) ==="
[ -f "$DETECT" ] || { echo "  FAIL  script not found: $DETECT" >&2; exit 1; }
[ -x "$DETECT" ] || { echo "  FAIL  script not executable: $DETECT" >&2; exit 1; }

declare -a FAILS=()

TMPDIR_FIXTURES="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_FIXTURES"; }
trap cleanup EXIT

# --- (a) dotnet single: x.sln + one csproj ----------------------------------
FIXTURE_A="$TMPDIR_FIXTURES/a-dotnet-single"
mkdir -p "$FIXTURE_A/Foo"
: > "$FIXTURE_A/x.sln"
cat > "$FIXTURE_A/Foo/Foo.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
</Project>
EOF

echo ""; echo "--- (a) dotnet single: stacks=[dotnet], primary_candidate=dotnet ---"
json_a="$(cd "$FIXTURE_A" && bash "$DETECT" --json)"
result_a="$(printf '%s' "$json_a" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(",".join(data["stacks"]))
print(data["primary_candidate"])
')"
stacks_a="$(printf '%s\n' "$result_a" | sed -n 1p)"
primary_a="$(printf '%s\n' "$result_a" | sed -n 2p)"
if [ "$stacks_a" = "dotnet" ] && [ "$primary_a" = "dotnet" ]; then
  echo "  PASS  stacks=[dotnet], primary_candidate=dotnet"
else
  FAILS+=("(a) expected stacks=[dotnet] primary_candidate=dotnet, got stacks=[$stacks_a] primary_candidate=[$primary_a]. JSON: $json_a")
fi

# --- (b) typescript + pnpm + expo -------------------------------------------
FIXTURE_B="$TMPDIR_FIXTURES/b-ts-pnpm-expo"
mkdir -p "$FIXTURE_B"
cat > "$FIXTURE_B/package.json" <<'EOF'
{
  "name": "expo-app",
  "dependencies": {
    "expo": "^49.0.0",
    "react": "^18.2.0"
  }
}
EOF
cat > "$FIXTURE_B/pnpm-lock.yaml" <<'EOF'
lockfileVersion: '6.0'
EOF
cat > "$FIXTURE_B/app.json" <<'EOF'
{
  "expo": {
    "name": "expo-app"
  }
}
EOF

echo ""; echo "--- (b) ts+pnpm+expo: package_manager=pnpm, react_native.detected+expo=true ---"
json_b="$(cd "$FIXTURE_B" && bash "$DETECT" --json)"
result_b="$(printf '%s' "$json_b" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data["package_manager"])
print(data["react_native"]["detected"])
print(data["react_native"]["expo"])
')"
pm_b="$(printf '%s\n' "$result_b" | sed -n 1p)"
rn_detected_b="$(printf '%s\n' "$result_b" | sed -n 2p)"
rn_expo_b="$(printf '%s\n' "$result_b" | sed -n 3p)"
if [ "$pm_b" = "pnpm" ] && [ "$rn_detected_b" = "True" ] && [ "$rn_expo_b" = "True" ]; then
  echo "  PASS  package_manager=pnpm, react_native.detected=true, react_native.expo=true"
else
  FAILS+=("(b) expected pm=pnpm detected=True expo=True, got pm=$pm_b detected=$rn_detected_b expo=$rn_expo_b. JSON: $json_b")
fi

# --- (c) pnpm-workspace monorepo with 3 packages ----------------------------
FIXTURE_C="$TMPDIR_FIXTURES/c-pnpm-workspace"
mkdir -p "$FIXTURE_C/packages/a" "$FIXTURE_C/packages/b" "$FIXTURE_C/packages/c"
cat > "$FIXTURE_C/package.json" <<'EOF'
{
  "name": "root",
  "private": true
}
EOF
cat > "$FIXTURE_C/pnpm-workspace.yaml" <<'EOF'
packages:
  - 'packages/*'
EOF
for p in a b c; do
  cat > "$FIXTURE_C/packages/$p/package.json" <<EOF
{ "name": "$p" }
EOF
done

echo ""; echo "--- (c) pnpm-workspace monorepo: is_monorepo=true, 3 packages ---"
json_c="$(cd "$FIXTURE_C" && bash "$DETECT" --json)"
result_c="$(printf '%s' "$json_c" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data["monorepo"]["is_monorepo"])
print(len(data["monorepo"]["packages"]))
')"
is_mono_c="$(printf '%s\n' "$result_c" | sed -n 1p)"
pkg_count_c="$(printf '%s\n' "$result_c" | sed -n 2p)"
if [ "$is_mono_c" = "True" ] && [ "$pkg_count_c" = "3" ]; then
  echo "  PASS  is_monorepo=true, 3 packages enumerated"
else
  FAILS+=("(c) expected is_monorepo=True packages=3, got is_monorepo=$is_mono_c packages=$pkg_count_c. JSON: $json_c")
fi

# --- (d) mixed ts + dotnet --------------------------------------------------
FIXTURE_D="$TMPDIR_FIXTURES/d-mixed"
mkdir -p "$FIXTURE_D"
cat > "$FIXTURE_D/package.json" <<'EOF'
{
  "name": "mixed",
  "dependencies": {}
}
EOF
: > "$FIXTURE_D/Legacy.csproj"

echo ""; echo "--- (d) mixed ts+dotnet: stacks length 2, primary_candidate empty ---"
json_d="$(cd "$FIXTURE_D" && bash "$DETECT" --json)"
result_d="$(printf '%s' "$json_d" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(len(data["stacks"]))
print(repr(data["primary_candidate"]))
print(data["monorepo"]["ambiguous"])
print(json.dumps(data["monorepo"]["signals"]))
')"
stacks_len_d="$(printf '%s\n' "$result_d" | sed -n 1p)"
primary_d="$(printf '%s\n' "$result_d" | sed -n 2p)"
ambiguous_d="$(printf '%s\n' "$result_d" | sed -n 3p)"
signals_d="$(printf '%s\n' "$result_d" | sed -n 4p)"
# T-F001: neither the "monorepo" nor the "not a monorepo" STEP 4.5 rule
# clearly matches a bare root package.json + a single root .csproj (no
# workspaces, but csproj_count isn't 0) — this is a genuine mixed-signal
# case, so ambiguous must be True. No monorepo/conventional-layout signal
# fires for this fixture, so signals is deterministically empty (locked in
# by running the script against this exact fixture).
if [ "$stacks_len_d" = "2" ] && [ "$primary_d" = "''" ] && [ "$ambiguous_d" = "True" ] && [ "$signals_d" = "[]" ]; then
  echo "  PASS  stacks length 2, primary_candidate empty, monorepo.ambiguous=true, signals=[]"
else
  FAILS+=("(d) expected stacks length 2, empty primary_candidate, ambiguous=True, signals=[], got length=$stacks_len_d primary=$primary_d ambiguous=$ambiguous_d signals=$signals_d. JSON: $json_d")
fi

# --- (e) nx.json only, non-conventional layout: monorepo, empty packages ----
FIXTURE_E="$TMPDIR_FIXTURES/e-nx-nonconventional"
mkdir -p "$FIXTURE_E/frontend" "$FIXTURE_E/backend"
cat > "$FIXTURE_E/nx.json" <<'EOF'
{
  "extends": "nx/presets/npm.json"
}
EOF
cat > "$FIXTURE_E/package.json" <<'EOF'
{
  "name": "nx-root",
  "private": true
}
EOF
cat > "$FIXTURE_E/frontend/package.json" <<'EOF'
{ "name": "frontend" }
EOF
cat > "$FIXTURE_E/backend/package.json" <<'EOF'
{ "name": "backend" }
EOF

echo ""; echo "--- (e) nx.json + non-conventional dirs: is_monorepo=true, packages=[] ---"
json_e="$(cd "$FIXTURE_E" && bash "$DETECT" --json)"
result_e="$(printf '%s' "$json_e" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data["monorepo"]["is_monorepo"])
print(len(data["monorepo"]["packages"]))
')"
is_mono_e="$(printf '%s\n' "$result_e" | sed -n 1p)"
pkg_count_e="$(printf '%s\n' "$result_e" | sed -n 2p)"
if [ "$is_mono_e" = "True" ] && [ "$pkg_count_e" = "0" ]; then
  echo "  PASS  is_monorepo=true with empty packages (nx.json is a signal, not an enumeration source)"
else
  FAILS+=("(e) expected is_monorepo=True packages=0, got is_monorepo=$is_mono_e packages=$pkg_count_e. JSON: $json_e")
fi

# --- (f) pnpm-workspace with 25 package dirs: cap at 20, skipped=5 ---------
FIXTURE_F="$TMPDIR_FIXTURES/f-pnpm-25-packages"
mkdir -p "$FIXTURE_F/packages"
for i in $(seq -w 1 25); do
  mkdir -p "$FIXTURE_F/packages/pkg$i"
done
cat > "$FIXTURE_F/package.json" <<'EOF'
{
  "name": "root",
  "private": true
}
EOF
cat > "$FIXTURE_F/pnpm-workspace.yaml" <<'EOF'
packages:
  - 'packages/*'
EOF

echo ""; echo "--- (f) pnpm-workspace with 25 packages: packages capped at 20, packages_skipped=5 ---"
json_f="$(cd "$FIXTURE_F" && bash "$DETECT" --json)"
result_f="$(printf '%s' "$json_f" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(len(data["monorepo"]["packages"]))
print(data["monorepo"]["packages_skipped"])
')"
pkg_len_f="$(printf '%s\n' "$result_f" | sed -n 1p)"
pkg_skipped_f="$(printf '%s\n' "$result_f" | sed -n 2p)"
if [ "$pkg_len_f" = "20" ] && [ "$pkg_skipped_f" = "5" ]; then
  echo "  PASS  len(packages)=20, packages_skipped=5"
else
  FAILS+=("(f) expected packages=20 skipped=5, got packages=$pkg_len_f skipped=$pkg_skipped_f. JSON: $json_f")
fi

# --- (g) go.mod repo: go_detected=true --------------------------------------
FIXTURE_G="$TMPDIR_FIXTURES/g-go-mod"
mkdir -p "$FIXTURE_G"
cat > "$FIXTURE_G/go.mod" <<'EOF'
module example.com/foo

go 1.22
EOF

echo ""; echo "--- (g) go.mod repo: go_detected=true ---"
json_g="$(cd "$FIXTURE_G" && bash "$DETECT" --json)"
go_detected_g="$(printf '%s' "$json_g" | python3 -c 'import json, sys; print(json.load(sys.stdin)["go_detected"])')"
if [ "$go_detected_g" = "True" ]; then
  echo "  PASS  go_detected=true"
else
  FAILS+=("(g) expected go_detected=True, got $go_detected_g. JSON: $json_g")
fi

# --- (h) ts repo with both pnpm-lock.yaml and package-lock.json: pnpm wins --
FIXTURE_H="$TMPDIR_FIXTURES/h-multi-lockfile"
mkdir -p "$FIXTURE_H"
cat > "$FIXTURE_H/package.json" <<'EOF'
{
  "name": "multi-lock",
  "dependencies": {}
}
EOF
cat > "$FIXTURE_H/pnpm-lock.yaml" <<'EOF'
lockfileVersion: '6.0'
EOF
: > "$FIXTURE_H/package-lock.json"

echo ""; echo "--- (h) pnpm-lock.yaml + package-lock.json: multiple_lockfiles=true, package_manager=pnpm ---"
json_h="$(cd "$FIXTURE_H" && bash "$DETECT" --json)"
result_h="$(printf '%s' "$json_h" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data["multiple_lockfiles"])
print(data["package_manager"])
')"
multi_h="$(printf '%s\n' "$result_h" | sed -n 1p)"
pm_h="$(printf '%s\n' "$result_h" | sed -n 2p)"
if [ "$multi_h" = "True" ] && [ "$pm_h" = "pnpm" ]; then
  echo "  PASS  multiple_lockfiles=true, package_manager=pnpm (priority)"
else
  FAILS+=("(h) expected multiple_lockfiles=True package_manager=pnpm, got multiple_lockfiles=$multi_h package_manager=$pm_h. JSON: $json_h")
fi

# --- (i) S-F001 regression: malformed package.json, scripts block has ------
#     "react-native"/"expo" keys -> must NOT false-positive, must record
#     the parse failure in parse_errors.
FIXTURE_I="$TMPDIR_FIXTURES/i-malformed-pkg-json"
mkdir -p "$FIXTURE_I"
cat > "$FIXTURE_I/package.json" <<'EOF'
{
  "name": "broken-app",
  "scripts": {
    "react-native": "react-native start",
    "expo": "expo start"
  },
  "dependencies": {
    "react": "^18.2.0",
  }
}
EOF

echo ""; echo "--- (i) S-F001 regression: malformed package.json, scripts block has react-native/expo keys ---"
json_i="$(cd "$FIXTURE_I" && bash "$DETECT" --json)"
result_i="$(printf '%s' "$json_i" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data["react_native"]["detected"])
print("package.json" in data["parse_errors"])
')"
rn_detected_i="$(printf '%s\n' "$result_i" | sed -n 1p)"
parse_err_i="$(printf '%s\n' "$result_i" | sed -n 2p)"
if [ "$rn_detected_i" = "False" ] && [ "$parse_err_i" = "True" ]; then
  echo "  PASS  react_native.detected=false, parse_errors includes package.json (malformed scripts block never guessed at)"
else
  FAILS+=("(i) expected react_native.detected=False and 'package.json' in parse_errors, got detected=$rn_detected_i parse_errors_has=$parse_err_i. JSON: $json_i")
fi

# --- (j) DF-11 regression: root package.json (no RN) + non-monorepo --------
#     mobile/package.json with "expo" dep -> detected+expo=true
FIXTURE_J="$TMPDIR_FIXTURES/j-nested-expo"
mkdir -p "$FIXTURE_J/mobile"
cat > "$FIXTURE_J/package.json" <<'EOF'
{
  "name": "root-app",
  "private": true,
  "dependencies": {
    "react": "^18.2.0"
  }
}
EOF
cat > "$FIXTURE_J/mobile/package.json" <<'EOF'
{
  "name": "mobile-app",
  "dependencies": {
    "expo": "^49.0.0",
    "react": "^18.2.0"
  }
}
EOF

echo ""; echo "--- (j) root pkg (no RN) + mobile/package.json with expo dep: detected+expo=true ---"
json_j="$(cd "$FIXTURE_J" && bash "$DETECT" --json)"
result_j="$(printf '%s' "$json_j" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data["react_native"]["detected"])
print(data["react_native"]["expo"])
print(data["monorepo"]["is_monorepo"])
')"
rn_detected_j="$(printf '%s\n' "$result_j" | sed -n 1p)"
rn_expo_j="$(printf '%s\n' "$result_j" | sed -n 2p)"
is_mono_j="$(printf '%s\n' "$result_j" | sed -n 3p)"
if [ "$rn_detected_j" = "True" ] && [ "$rn_expo_j" = "True" ] && [ "$is_mono_j" = "False" ]; then
  echo "  PASS  react_native.detected=true, react_native.expo=true (nested mobile/ package.json scanned, not classified as a monorepo)"
else
  FAILS+=("(j) expected detected=True expo=True is_monorepo=False, got detected=$rn_detected_j expo=$rn_expo_j is_monorepo=$is_mono_j. JSON: $json_j")
fi

# --- exit codes: 0 on empty repo, 2 on unknown flag -------------------------
FIXTURE_EMPTY="$TMPDIR_FIXTURES/empty"
mkdir -p "$FIXTURE_EMPTY"

echo ""; echo "--- exit 0 with valid JSON on an empty repo ---"
if json_empty="$(cd "$FIXTURE_EMPTY" && bash "$DETECT" --json 2>&1)"; then
  if printf '%s' "$json_empty" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["stacks"] == []
assert data["primary_candidate"] == ""
' 2>/dev/null; then
    echo "  PASS  empty repo -> exit 0, valid JSON, no stacks"
  else
    FAILS+=("empty-repo JSON did not parse or had unexpected content: $json_empty")
  fi
else
  FAILS+=("empty-repo run exited non-zero. Output: $json_empty")
fi

echo ""; echo "--- exit 2 on unknown flag ---"
rc_bad=0
bad_out="$(cd "$FIXTURE_EMPTY" && bash "$DETECT" --nope 2>&1)" || rc_bad=$?
if [ "$rc_bad" -eq 2 ]; then
  echo "  PASS  unknown flag exits 2"
else
  FAILS+=("expected exit 2 on unknown flag, got $rc_bad. Output: $bad_out")
fi

echo ""
if [ ${#FAILS[@]} -gt 0 ]; then
  printf '  FAIL  %s\n' "${FAILS[@]}" >&2
  exit 1
fi
echo "========================================"
echo "TEST PASSED — all F2 setup-detect assertions green"
