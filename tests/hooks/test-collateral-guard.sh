#!/usr/bin/env bash
set -euo pipefail

# collateral-guard.sh: churn that is not the change you made. The three shapes
# come from one real session — a CRLF whole-file rewrite turning a 60-line edit
# into a 2,000-line diff, an `npm install` dragging a lockfile into a feature
# commit, and a screenshot run rewriting 78 of 84 images. A clean diff and a
# *declared* generated file must both stay silent.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$REPO_ROOT/hooks/collateral-guard.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
git -C "$WORK" init -q
cd "$WORK"
git config user.email t@example.com
git config user.name test
git config core.autocrlf false

mkdir -p web docs/img docs/specs
# A CRLF file, as one stray file in an otherwise-LF repo.
python3 -c "open('ctx.cs','w',newline='').write(''.join('line %d\r\n' % i for i in range(1,1001)))"
python3 -c "open('web/package-lock.json','w').write('{\n' + ''.join('  \"p%d\": 1,\n' % i for i in range(3000)) + '}\n')"
for i in $(seq 1 84); do printf '\211PNG\r\n\032\n orig%s' "$i" > "docs/img/shot$i.png"; done
printf 'export const a = 1;\n' > web/app.ts
git add -A >/dev/null 2>&1 && git commit -qm fixture >/dev/null

# --- 1. a clean, honest diff is silent -------------------------------------
printf 'export const b = 2;\n' >> web/app.ts
git add -A >/dev/null
set +e
out="$(bash "$GUARD" --cached)"; rc=$?
set -e
[ "$rc" -eq 0 ] || fail "an honest diff must exit 0 (got $rc): $out"
case "$out" in *'"verdict":"PASS"'*) : ;; *) fail "honest diff must verdict PASS: $out" ;; esac
git commit -qm honest >/dev/null

# --- 2. CRLF whole-file rewrite around a small real edit -> CG001 ----------
python3 -c "
lines=[l.rstrip('\r\n') for l in open('ctx.cs', newline='')]
lines += ['added %d' % i for i in range(60)]
open('ctx.cs','w',newline='\n').write('\n'.join(lines) + '\n')"
git add -A >/dev/null
set +e
out="$(bash "$GUARD" --cached)"; rc=$?
set -e
[ "$rc" -eq 1 ] || fail "line-ending churn must exit 1 (got $rc): $out"
case "$out" in *'"rule":"CG001"'*) : ;; *) fail "expected CG001 for CRLF rewrite: $out" ;; esac
# The finding is only useful if it separates the real edit from the churn.
case "$out" in *'only 60 survive'*) : ;;
  *) fail "CG001 must report the surviving real-line count: $out" ;; esac
git commit -qm crlf >/dev/null

# --- 3. undeclared lockfile churn -> CG002 --------------------------------
python3 -c "open('web/package-lock.json','w').write('{\n' + ''.join('  \"q%d\": 2,\n' % i for i in range(3000)) + '}\n')"
git add -A >/dev/null
set +e
out="$(bash "$GUARD" --cached)"; rc=$?
set -e
case "$out" in *'"rule":"CG002"'*) : ;; *) fail "expected CG002 for undeclared lockfile churn: $out" ;; esac
case "$out" in *'git restore --staged --worktree -- web/package-lock.json'*) : ;;
  *) fail "CG002 must hand over a working revert command: $out" ;; esac

# --- 4. the same churn, DECLARED, is silent (intent is exempt) ------------
cat > docs/specs/s.json <<'EOF'
{"change_manifest":[{"path":"web/package-lock.json","action":"modify","purpose":"dependency bump"}]}
EOF
set +e
out="$(bash "$GUARD" --cached --manifest docs/specs/s.json)"; rc=$?
set -e
case "$out" in *'"rule":"CG002"'*) fail "a declared lockfile change must not be flagged: $out" ;; esac
git commit -qm lock >/dev/null

# --- 5. wholesale asset regeneration -> CG003 ----------------------------
for i in $(seq 1 78); do printf '\211PNG\r\n\032\n regen%s' "$i" > "docs/img/shot$i.png"; done
git add -A >/dev/null
set +e
out="$(bash "$GUARD" --cached)"; rc=$?
set -e
case "$out" in *'"rule":"CG003"'*) : ;; *) fail "expected CG003 for an asset-set rewrite: $out" ;; esac
case "$out" in *'78 of 84'*) : ;; *) fail "CG003 must report the rewritten fraction: $out" ;; esac
git commit -qm assets >/dev/null

# --- 6. a handful of new assets is normal work, not a regeneration -------
for i in $(seq 1 4); do printf '\211PNG\r\n\032\n small%s' "$i" > "docs/img/shot$i.png"; done
git add -A >/dev/null
set +e
out="$(bash "$GUARD" --cached)"; rc=$?
set -e
case "$out" in *'"rule":"CG003"'*) fail "4 of 84 assets must not trip CG003: $out" ;; esac
git commit -qm few >/dev/null

# --- 7. usage errors are exit 2 -----------------------------------------
set +e
bash "$GUARD" --range >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "--range with no expression must exit 2 (got $rc)"

printf 'PASS: collateral-guard (7 checks)\n'
