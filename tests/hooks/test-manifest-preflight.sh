#!/usr/bin/env bash
set -euo pipefail

# manifest-preflight.sh: change_manifest DESTINATIONS are validated against the
# repo before the seal. The three shapes that shipped as Phase 3.5 drift in the
# field run are the three this must catch: a modify pointed at a file that
# does not exist, a create into a directory whose pattern the codebase never
# uses, and a filename that breaks its siblings' convention. A correct entry
# must stay silent — a checker that flags valid manifests gets ignored.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKER="$REPO_ROOT/scripts/manifest-preflight.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
git -C "$WORK" init -q
cd "$WORK"
git config user.email t@example.com
git config user.name test

mkdir -p Data Migrations web/src/components/shell docs/specs
printf '// entities configured inline in OnModelCreating\n' > Data/AppContext.cs
: > Migrations/20260801120000_Initial.cs
: > Migrations/20260801120000_Initial.Designer.cs
: > Migrations/20260810090000_AddLeave.cs
: > Migrations/20260810090000_AddLeave.Designer.cs
: > Migrations/20260815110000_AddAssets.cs
: > web/src/components/shell/nav-items.ts
: > web/src/components/button.tsx
git add -A >/dev/null 2>&1 && git commit -qm fixture >/dev/null

# --- 1. A clean manifest must be silent (exit 0, no findings) ----------------
cat > docs/specs/clean.json <<'EOF'
{"slug":"c","date":"2026-08-20","scope":"new-feature","security_impact":"none",
 "success_criteria":[],
 "change_manifest":[
  {"path":"Data/AppContext.cs","action":"modify","purpose":"register entity"},
  {"path":"web/src/components/shell/nav-items.ts","action":"modify","purpose":"add nav entry"},
  {"path":"web/src/components/panel.tsx","action":"create","purpose":"new panel"}
 ]}
EOF
set +e
out="$(bash "$CHECKER" docs/specs/clean.json)"; rc=$?
set -e
[ "$rc" -eq 0 ] || fail "a valid manifest must exit 0 (got $rc): $out"
case "$out" in *'"verdict":"PASS"'*) : ;; *) fail "clean manifest must verdict PASS: $out" ;; esac

# --- 2. modify pointed at a path that does not exist -> critical MP001 ------
cat > docs/specs/missing.json <<'EOF'
{"slug":"m","date":"2026-08-20","scope":"new-feature","security_impact":"none",
 "success_criteria":[],
 "change_manifest":[{"path":"web/src/components/app-sidebar.tsx","action":"modify","purpose":"nav"}]}
EOF
set +e
out="$(bash "$CHECKER" docs/specs/missing.json)"; rc=$?
set -e
[ "$rc" -eq 1 ] || fail "a missing modify target must exit 1 (got $rc)"
case "$out" in *'"rule":"MP001"'*) : ;; *) fail "expected MP001 for missing modify target: $out" ;; esac
case "$out" in *'"severity":"critical"'*) : ;; *) fail "missing modify target must be critical: $out" ;; esac

# --- 3. the same file existing elsewhere is a relocation, not a gap ---------
cat > docs/specs/moved.json <<'EOF'
{"slug":"r","date":"2026-08-20","scope":"new-feature","security_impact":"none",
 "success_criteria":[],
 "change_manifest":[{"path":"web/src/nav-items.ts","action":"modify","purpose":"nav"}]}
EOF
set +e
out="$(bash "$CHECKER" docs/specs/moved.json)"; rc=$?
set -e
case "$out" in *'"rule":"MP002"'*) : ;; *) fail "expected MP002 when the basename is tracked elsewhere: $out" ;; esac
case "$out" in *'web/src/components/shell/nav-items.ts'*) : ;;
  *) fail "MP002 must name the real path so the entry can be repointed: $out" ;; esac

# --- 4. create into a directory whose pattern the repo never uses -----------
cat > docs/specs/pattern.json <<'EOF'
{"slug":"p","date":"2026-08-20","scope":"new-feature","security_impact":"none",
 "success_criteria":[],
 "change_manifest":[{"path":"Data/Configurations/TemplateConfiguration.cs","action":"create","purpose":"EF config"}]}
EOF
set +e
out="$(bash "$CHECKER" docs/specs/pattern.json)"; rc=$?
set -e
case "$out" in *'"rule":"MP004"'*) : ;; *) fail "expected MP004 for a create into a novel directory: $out" ;; esac
case "$out" in *'may not be used in this codebase at all'*) : ;;
  *) fail "MP004 must say the pattern is absent, not merely that the dir is new: $out" ;; esac

# --- 5. sibling naming + companion conventions ------------------------------
cat > docs/specs/convention.json <<'EOF'
{"slug":"v","date":"2026-08-20","scope":"new-feature","security_impact":"none",
 "success_criteria":[],
 "change_manifest":[{"path":"Migrations/LifecycleTemplates.cs","action":"create","purpose":"migration"}]}
EOF
set +e
out="$(bash "$CHECKER" docs/specs/convention.json)"; rc=$?
set -e
case "$out" in *'"rule":"MP005"'*) : ;; *) fail "expected MP005 for a name breaking the timestamp convention: $out" ;; esac
case "$out" in *'"rule":"MP006"'*) : ;; *) fail "expected MP006 for the missing .Designer.cs companion: $out" ;; esac

# --- 6. declaring the companion silences MP006 (the fix must work) ----------
cat > docs/specs/companion.json <<'EOF'
{"slug":"w","date":"2026-08-20","scope":"new-feature","security_impact":"none",
 "success_criteria":[],
 "change_manifest":[
  {"path":"Migrations/20260820100000_Lifecycle.cs","action":"create","purpose":"migration"},
  {"path":"Migrations/20260820100000_Lifecycle.Designer.cs","action":"create","purpose":"designer"}
 ]}
EOF
set +e
out="$(bash "$CHECKER" docs/specs/companion.json)"; rc=$?
set -e
[ "$rc" -eq 0 ] || fail "a convention-following migration pair must exit 0 (got $rc): $out"

# --- 7. create over an existing path -> MP003 -------------------------------
cat > docs/specs/exists.json <<'EOF'
{"slug":"e","date":"2026-08-20","scope":"new-feature","security_impact":"none",
 "success_criteria":[],
 "change_manifest":[{"path":"Data/AppContext.cs","action":"create","purpose":"ctx"}]}
EOF
set +e
out="$(bash "$CHECKER" docs/specs/exists.json)"; rc=$?
set -e
case "$out" in *'"rule":"MP003"'*) : ;; *) fail "expected MP003 for create over an existing path: $out" ;; esac

# --- 8. input errors are exit 2, never a silent pass ------------------------
set +e
bash "$CHECKER" docs/specs/nope.json >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "a missing sidecar must exit 2 (got $rc)"
printf 'not json\n' > docs/specs/bad.json
set +e
bash "$CHECKER" docs/specs/bad.json >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "an unparseable sidecar must exit 2, not pass (got $rc)"
printf '{"slug":"x"}\n' > docs/specs/nocm.json
set +e
bash "$CHECKER" docs/specs/nocm.json >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "a sidecar with no change_manifest must exit 2 (got $rc)"

printf 'PASS: manifest-preflight (8 checks)\n'
