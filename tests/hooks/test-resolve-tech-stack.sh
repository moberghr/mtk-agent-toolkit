#!/usr/bin/env bash
set -euo pipefail

# Test: scripts/resolve-tech-stack.sh
#
# Field feedback (2026-08-11, mixed .NET root + Vite SPA subtree) reported that a
# root-only `.claude/tech-stack` silently hands `dotnet build` to a TypeScript
# subtree, and that nothing flags the mismatch. This locks both halves down:
# the pre-existing polyglot resolution order, and the `--check` advisory added
# for that report.
#
# Covers:
#   (a) resolution order — MTK_STACK > subproject file > tech-stack.map > root
#   (b) --check stays SILENT when the resolved stack matches the paths
#   (c) --check WARNS on mismatch, but never changes stdout or the exit code
#   (d) --check ignores non-stack-bearing extensions (.md/.json/.sh)
#   (e) --check is silent when the subtree correctly declares its own stack
#       (the exact configuration the field report had to apply by hand)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
R="$REPO_ROOT/scripts/resolve-tech-stack.sh"

echo "=== resolve-tech-stack.sh Test ==="
[ -f "$R" ] || { echo "  FAIL  script not found: $R" >&2; exit 1; }

FAILS=0
FIX="$(mktemp -d)"
cleanup() { rm -rf "$FIX"; }
trap cleanup EXIT

mkdir -p "$FIX/.claude" "$FIX/web/.claude" "$FIX/svc"
git -C "$FIX" init -q .
printf 'dotnet\n'     > "$FIX/.claude/tech-stack"
printf 'typescript\n' > "$FIX/web/.claude/tech-stack"

# Run the resolver from inside the fixture; capture stdout, stderr, exit code.
# shellcheck disable=SC2317
run() { # $1=subdir  rest=args -> sets OUT/ERR/RC
  local sub="$1"; shift
  local errfile; errfile="$(mktemp)"
  set +e
  OUT="$( cd "$FIX/$sub" && bash "$R" "$@" 2>"$errfile" )"
  RC=$?
  set -e
  ERR="$(cat "$errfile")"; rm -f "$errfile"
}

check() { # $1=label $2=expected $3=actual
  if [ "$2" = "$3" ]; then
    echo "  PASS  $1"
  else
    echo "  FAIL  $1 — expected [$2], got [$3]" >&2
    FAILS=$((FAILS + 1))
  fi
}

# --- (a) resolution order ----------------------------------------------------
run "."   ".";        check "root resolves to root stack"          "dotnet"     "$OUT"
run "."   "web";      check "subtree resolves to subtree stack"    "typescript" "$OUT"
run "web" ".";        check "cwd inside subtree resolves subtree"  "typescript" "$OUT"
run "."   "svc";      check "undeclared subtree falls back to root" "dotnet"    "$OUT"

OUT="$( cd "$FIX" && MTK_STACK=python bash "$R" web )"
check "MTK_STACK overrides everything" "python" "$OUT"

printf 'svc/*  python\n' > "$FIX/.claude/tech-stack.map"
run "." "svc";        check "tech-stack.map glob wins over root"   "python"     "$OUT"
rm -f "$FIX/.claude/tech-stack.map"

# --- (b) --check silent on match --------------------------------------------
run "." --check "./Foo.cs"
check "match: stdout unchanged"  "dotnet" "$OUT"
check "match: no warning"        ""       "$ERR"
check "match: exit 0"            "0"      "$RC"

# --- (c) --check warns on mismatch, non-blocking -----------------------------
run "." --check "./a.tsx" "./b.tsx"
check "mismatch: stdout unchanged" "dotnet" "$OUT"
check "mismatch: exit still 0"     "0"      "$RC"
case "$ERR" in
  *WARNING*typescript*) echo "  PASS  mismatch: warns and names the real stack" ;;
  *) echo "  FAIL  mismatch: expected a WARNING naming typescript, got [$ERR]" >&2
     FAILS=$((FAILS + 1)) ;;
esac
case "$ERR" in
  *"No target file matches"*) echo "  PASS  mismatch: flags the all-foreign case" ;;
  *) echo "  FAIL  mismatch: expected the all-foreign note, got [$ERR]" >&2
     FAILS=$((FAILS + 1)) ;;
esac

# Partial mismatch: some files match, some do not -> warn, but not "no target".
run "." --check "./Foo.cs" "./a.tsx"
case "$ERR" in
  *WARNING*) : ;;
  *) echo "  FAIL  partial: expected a WARNING, got [$ERR]" >&2; FAILS=$((FAILS + 1)) ;;
esac
case "$ERR" in
  *"No target file matches"*)
     echo "  FAIL  partial: must not claim no target matches" >&2; FAILS=$((FAILS + 1)) ;;
  *) echo "  PASS  partial: warns without the all-foreign note" ;;
esac

# --- (d) non-stack-bearing extensions are inert ------------------------------
run "." --check "./README.md" "./package.json" "./run.sh"
check "inert extensions: no warning" "" "$ERR"

# --- (e) correctly declared subtree is silent --------------------------------
run "." --check "web/a.tsx" "web/b.ts"
check "declared subtree: resolves typescript" "typescript" "$OUT"
check "declared subtree: no warning"          ""           "$ERR"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "=== resolve-tech-stack.sh: ALL PASS ==="
else
  echo "=== resolve-tech-stack.sh: $FAILS FAILURE(S) ===" >&2
  exit 1
fi
