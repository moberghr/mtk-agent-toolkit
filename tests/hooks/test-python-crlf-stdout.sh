#!/usr/bin/env bash
set -euo pipefail

# Test: bash consumers of python3 stdout survive a Windows-native python3.
#
# Issues #95, #96, #98 (2026-09-07, Git Bash + native Windows Python) were one
# root cause with three faces: Python's text-mode stdout on Windows translates
# "\n" to "\r\n", and every `$(python3 …)` capture in the toolkit then carries a
# trailing "\r" into a bash `case`, `read`, `split` or path. The fix is at the
# source — each parsed heredoc/one-liner reconfigures stdout to LF — so this
# test drives the three reported scripts through a python3 SHIM that emulates
# the Windows text layer (a TextIOWrapper with newline="\r\n") and asserts:
#   (0) the shim really does emit CRLF for a plain print()  — the emulation is live
#   (a) #98 manifest-preflight.sh: a valid `modify` manifest still verdicts PASS
#   (b) #96 workflow-artifact.sh: init → set → zero-arg seal → verify-seal round-trips
#   (c) #95 setup-refresh-plan.sh: --json parses and no status carries a "\r"
#
# Runs on macOS/Linux: the shim is the only Windows-specific piece.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== python3 CRLF stdout Test (#95 #96 #98) ==="
REAL_PY="$(command -v python3 || true)"
[ -n "$REAL_PY" ] || { echo "  SKIP  python3 not available"; exit 0; }

FAILS=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1" >&2; FAILS=$((FAILS + 1)); }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- The shim: python3 whose stdout behaves like Windows text mode -----------
# Handles the two forms the toolkit uses for parsed output — `python3 - args`
# (script on stdin) and `python3 -c code args` — and passes anything else
# straight through. sys.exit() inside the exec'd code propagates unchanged.
# The wrapper's own source occupies stdin, so the caller's stdin (its
# `python3 - <<'PY'` script) is handed over on fd 3.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/python3" <<'SHIM'
#!/usr/bin/env bash
exec 3<&0
exec "@REAL_PY@" - "$@" <<'PYWRAP'
import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", newline="\r\n", line_buffering=True)
args = sys.argv[1:]
g = {"__name__": "__main__"}
if args and args[0] == "-":
    src = open(3, encoding="utf-8").read()
    sys.argv = ["-"] + args[1:]
    exec(compile(src, "<stdin>", "exec"), g)
elif args and args[0] == "-c":
    sys.argv = ["-c"] + args[2:]
    exec(compile(args[1], "<string>", "exec"), g)
else:
    import runpy
    sys.argv = args
    runpy.run_path(args[0], run_name="__main__")
PYWRAP
SHIM
sed -i.bak "s|@REAL_PY@|$REAL_PY|" "$WORK/bin/python3"
rm -f "$WORK/bin/python3.bak"
chmod +x "$WORK/bin/python3"
export PATH="$WORK/bin:$PATH"

# --- (0) the emulation is live -------------------------------------------------
probe="$(printf 'print("x")\n' | python3 - | od -An -c | tr -d ' \n')"
case "$probe" in
  *'x\r\n'*) pass "shim: plain print() emits CRLF (Windows text layer emulated)" ;;
  *) fail "shim: expected CRLF from print(), got [$probe]"; echo "=== aborting: emulation not live ===" >&2; exit 1 ;;
esac
probe="$(python3 -c 'print("y")' | od -An -c | tr -d ' \n')"
case "$probe" in
  *'y\r\n'*) pass "shim: -c form emits CRLF too" ;;
  *) fail "shim: -c form expected CRLF, got [$probe]" ;;
esac

# --- fixture repo ----------------------------------------------------------------
FIX="$WORK/repo"
mkdir -p "$FIX/docs/specs" "$FIX/docs/plans" "$FIX/src"
git -C "$FIX" init -q
git -C "$FIX" config user.email t@example.com
git -C "$FIX" config user.name test
printf '# Fixture\n' > "$FIX/CLAUDE.md"
printf 'console.log(1)\n' > "$FIX/src/app.js"
printf '# spec\n' > "$FIX/docs/specs/2026-09-17-crlf.md"
printf '# plan\n' > "$FIX/docs/plans/2026-09-17-crlf.md"
git -C "$FIX" add -A >/dev/null && git -C "$FIX" commit -qm fixture >/dev/null

# --- (a) #98 manifest-preflight.sh ------------------------------------------------
cat > "$FIX/docs/specs/crlf.json" <<'JSON'
{"slug":"crlf","date":"2026-09-17","scope":"new-feature","security_impact":"none",
 "success_criteria":[],
 "change_manifest":[
  {"path":"src/app.js","action":"modify","purpose":"touch"},
  {"path":"CLAUDE.md","action":"modify","purpose":"touch"}
 ]}
JSON
set +e
out="$(cd "$FIX" && bash "$REPO_ROOT/scripts/manifest-preflight.sh" --human docs/specs/crlf.json 2>&1)"; rc=$?
set -e
if [ "$rc" -eq 0 ]; then pass "#98 manifest-preflight: valid modify manifest verdicts PASS under CRLF python"
else fail "#98 manifest-preflight: exit $rc under CRLF python — $(printf '%s' "$out" | head -2 | tr '\n' ' ')"; fi

# --- (b) #96 workflow-artifact.sh zero-arg seal -------------------------------------
WA="$REPO_ROOT/scripts/workflow-artifact.sh"
set +e
uuid="$(cd "$FIX" && CLAUDE_PROJECT_DIR="$FIX" bash "$WA" init BUILD --goal crlf 2>/dev/null)"; rc=$?
set -e
case "$uuid" in
  *$'\r'*) fail "#96 init: printed UUID carries a CR" ;;
  "")      fail "#96 init: no UUID printed (exit $rc)" ;;
  *)       pass "#96 init: UUID is CR-free" ;;
esac
uuid="${uuid%$'\r'}"
if [ -n "$uuid" ]; then
  set +e
  (cd "$FIX" && CLAUDE_PROJECT_DIR="$FIX" bash "$WA" set "$uuid" \
      results.spec_path=docs/specs/2026-09-17-crlf.md results.plan_path=docs/plans/2026-09-17-crlf.md >/dev/null 2>&1)
  out="$(cd "$FIX" && CLAUDE_PROJECT_DIR="$FIX" bash "$WA" seal "$uuid" 2>&1)"; rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then pass "#96 seal: zero-arg derivation seals both paths under CRLF python"
  else fail "#96 seal: exit $rc — $(printf '%s' "$out" | head -1)"; fi
  set +e
  out="$(cd "$FIX" && CLAUDE_PROJECT_DIR="$FIX" bash "$WA" verify-seal "$uuid" 2>&1)"; rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then pass "#96 verify-seal: recorded seal verifies"
  else fail "#96 verify-seal: exit $rc — $(printf '%s' "$out" | head -1)"; fi
fi

# --- (c) #95 setup-refresh-plan.sh --json --------------------------------------------
set +e
out="$(cd "$FIX" && bash "$REPO_ROOT/scripts/setup-refresh-plan.sh" --json 2>&1)"; rc=$?
set -e
case "$out" in
  *Traceback*) fail "#95 setup-refresh-plan --json: python traceback — $(printf '%s' "$out" | tail -1)" ;;
  *) pass "#95 setup-refresh-plan --json: no traceback (exit $rc)" ;;
esac
if printf '%s' "$out" | "$REAL_PY" -c '
import json, sys
d = json.load(sys.stdin)
bad = [a for a in d.get("artifacts", []) if "\r" in a.get("status", "") or "\r" in a.get("reason", "")]
sys.exit(1 if bad else 0)
' 2>/dev/null; then pass "#95 setup-refresh-plan --json: parses and no status/reason carries a CR"
else fail "#95 setup-refresh-plan --json: output is not clean JSON or a row carries a CR"; fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "=== python3 CRLF stdout: ALL PASS ==="
else
  echo "=== python3 CRLF stdout: $FAILS FAILURE(S) ===" >&2
  exit 1
fi
