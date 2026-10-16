#!/usr/bin/env bash
set -euo pipefail

# scripts/review-receipt.sh — diff-bound review receipts (R9).
#
# Every case runs in a mktemp -d sandbox: HOME, TMPDIR and the git global
# config point into it, the repositories are sandbox repos, and the only remote
# is a local bare repository. Nothing touches the real ~/.mtk or any network.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RECEIPT="$REPO_ROOT/scripts/review-receipt.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
mkdir -p "$SANDBOX/home" "$SANDBOX/tmp"
export HOME="$SANDBOX/home"
export TMPDIR="$SANDBOX/tmp"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"
export GIT_TERMINAL_PROMPT=0
export GIT_PAGER=cat
cat >"$GIT_CONFIG_GLOBAL" <<'CFG'
[user]
	name = MTK Test
	email = mtk-test@example.invalid
[init]
	defaultBranch = main
[commit]
	gpgsign = false
CFG

fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

# expect <label> <want-exit> <got-exit>
expect() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — expected exit $2, got $3"; fi
}
# run <args…>: run the script in $PWD; stdout+stderr in $OUT, exit code echoed via $RC.
run() {
  RC=0
  OUT="$(bash "$RECEIPT" "$@" 2>&1)" || RC=$?
}
mode_of() { python3 -c 'import os, sys; print("%o" % (os.lstat(sys.argv[1]).st_mode & 0o777))' "$1"; }
repo_key() { python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$1"; }
commit() { # $1 file  $2 content  $3 message
  printf '%s\n' "$2" >"$1"
  git add "$1"
  git commit -q -m "$3"
}
change_id() { bash "$RECEIPT" id | awk '{print $1}'; }
base_ref() { bash "$RECEIPT" id | awk '{print $4}'; }

# --- Sandbox repositories: seed → bare remote (HEAD=main) → work clone ------
mkdir "$SANDBOX/seed"
cd "$SANDBOX/seed"
git init -q
commit README.md "seed" "seed commit"
git clone -q --bare "$SANDBOX/seed" "$SANDBOX/remote.git"
git clone -q "$SANDBOX/remote.git" "$SANDBOX/work"
WORK="$SANDBOX/work"
cd "$WORK"
git checkout -q -b feature
commit a.txt "alpha" "feat: alpha"

KEYDIR="$HOME/.mtk/receipts/$(repo_key "$WORK")"

# --- Usage / argument errors ------------------------------------------------
run --help
expect "--help exits 0" 0 "$RC"
case "$OUT" in *"Exit codes:"*) pass "--help shows the exit codes" ;; *) fail "--help lacks the exit codes: $OUT" ;; esac
run bogus
expect "unknown subcommand exits 2" 2 "$RC"
run write --rigor HIGH
expect "write without --lanes exits 2" 2 "$RC"
run write --lanes compliance --rigor HIGH --verdict FAIL
expect "a non-PASS verdict is refused (exit 2)" 2 "$RC"
[ ! -e "$HOME/.mtk" ] && pass "a refused write creates nothing" || fail "a refused write created ~/.mtk"

# --- Write: modes and location ----------------------------------------------
run check
expect "check before any receipt exits 1" 1 "$RC"
case "$OUT" in
  "receipt: missing change_id="*"commits=1"*"feat: alpha"*) pass "check names the uncovered commit" ;;
  *) fail "check output unexpected: $OUT" ;;
esac

run write --lanes compliance,test,architecture --rigor high
expect "write exits 0" 0 "$RC"
ID1="$(change_id)"
FILE="$KEYDIR/$ID1.json"
[ "$OUT" = "$FILE" ] && pass "write prints the receipt path" || fail "write printed [$OUT], want [$FILE]"
[ -f "$FILE" ] && pass "receipt stored under ~/.mtk/receipts/<repo key>/<change_id>.json" || fail "no receipt at $FILE"
[ "$(mode_of "$FILE")" = "600" ] && pass "receipt file is 0600" || fail "receipt mode $(mode_of "$FILE")"
for d in "$HOME/.mtk" "$HOME/.mtk/receipts" "$KEYDIR"; do
  [ "$(mode_of "$d")" = "700" ] && pass "dir ${d#"$HOME"/} is 0700" || fail "dir $d mode $(mode_of "$d")"
done
if python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["change_id"] == sys.argv[2] and d["verdict"] == "PASS" and d["rigor"] == "HIGH"
assert d["lanes"] == ["compliance", "test", "architecture"]
assert d["merge_base"] and d["head"] and d["timestamp"]
' "$FILE" "$ID1"; then
  pass "receipt records lanes, rigor, verdict, timestamp, merge_base, head"
else
  fail "receipt content: $(cat "$FILE")"
fi
leftover="$(find "$KEYDIR" -name '.receipt-*' | wc -l | tr -d ' ')"
[ "$leftover" = 0 ] && pass "no temp file left behind" || fail "$leftover temp file(s) left"

# --- Check: same range passes, a new commit fails ---------------------------
run check
expect "check passes for the reviewed range" 0 "$RC"
case "$OUT" in "receipt: covered change_id=$ID1") pass "check reports the covered id" ;; *) fail "check output: $OUT" ;; esac

commit b.txt "beta" "feat: beta"
run check
expect "check fails after a new commit" 1 "$RC"
case "$OUT" in
  *"commits=2"*"feat: beta"*) pass "check lists the new commit" ;;
  *) fail "check after new commit: $OUT" ;;
esac

# --- Amend: content change → new id; message-only → same id -----------------
ID_B="$(change_id)"
printf 'beta 2\n' >b.txt
git add b.txt
git commit -q --amend --no-edit
ID_AMEND="$(change_id)"
[ -n "$ID_B" ] && [ "$ID_B" != "$ID_AMEND" ] && pass "amended content gives a new change_id" || fail "amend kept id $ID_B"
git commit -q --amend -m "feat: beta, reworded"
[ "$(change_id)" = "$ID_AMEND" ] && pass "message-only amend keeps the change_id (same diff)" || fail "message-only amend changed the id"

# --- Bounded commit list ----------------------------------------------------
for n in $(seq 1 22); do commit "n$n.txt" "$n" "chore: n$n"; done
run check
lines="$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
case "$OUT" in
  *"... and 4 more") [ "$lines" = 22 ] && pass "uncovered list bounded to 20 lines + a count" || fail "list has $lines lines" ;;
  *) fail "bounded list: $OUT" ;;
esac
git reset -q --hard HEAD~22

# --- Base fallback: upstream → origin/HEAD → main ----------------------------
git push -q -u origin feature </dev/null
[ "$(base_ref)" = "origin/feature" ] && pass "upstream set → base is @{upstream}" || fail "base with upstream: $(base_ref)"
run check
expect "fully pushed branch (empty range) counts as covered" 0 "$RC"
git branch -q --unset-upstream
[ "$(base_ref)" = "origin/main" ] && pass "no upstream → base is origin/HEAD" || fail "base without upstream: $(base_ref)"
git remote set-head origin -d
[ "$(base_ref)" = "main" ] && pass "no upstream, no origin/HEAD → base is main" || fail "base without origin/HEAD: $(base_ref)"

mkdir "$SANDBOX/nobase"
cd "$SANDBOX/nobase"
git init -q -b trunk
commit x.txt "x" "x"
run check
expect "no upstream, no origin/HEAD, no main → exit 2" 2 "$RC"
cd "$WORK"

# --- Symlinks and ownership are refused -------------------------------------
ID_NOW="$(change_id)"
run write --lanes compliance --rigor HIGH
expect "write for the current range" 0 "$RC"
TARGET="$KEYDIR/$ID_NOW.json"
rm -f "$TARGET"
printf 'outside\n' >"$SANDBOX/outside.txt"
ln -s "$SANDBOX/outside.txt" "$TARGET"
run write --lanes compliance --rigor HIGH
expect "write refuses a symlinked receipt path (exit 2)" 2 "$RC"
[ "$(cat "$SANDBOX/outside.txt")" = "outside" ] && pass "symlink target untouched" || fail "symlink target was written"
run check
expect "check refuses a symlinked receipt (exit 2)" 2 "$RC"
rm -f "$TARGET"

mv "$KEYDIR" "$SANDBOX/real-keydir"
ln -s "$SANDBOX/real-keydir" "$KEYDIR"
run write --lanes compliance --rigor HIGH
expect "write refuses a symlinked per-repo receipts dir (exit 2)" 2 "$RC"
[ ! -e "$SANDBOX/real-keydir/$ID_NOW.json" ] && pass "nothing written through the symlinked dir" || fail "receipt written through symlink"
run check
expect "check refuses a symlinked per-repo receipts dir (exit 2)" 2 "$RC"
rm -f "$KEYDIR"

mv "$HOME/.mtk/receipts" "$SANDBOX/real-receipts"
ln -s "$SANDBOX/real-receipts" "$HOME/.mtk/receipts"
run write --lanes compliance --rigor HIGH
expect "write refuses a symlinked ~/.mtk/receipts (exit 2)" 2 "$RC"
rm -f "$HOME/.mtk/receipts"
mv "$SANDBOX/real-receipts" "$HOME/.mtk/receipts"

run write --lanes compliance --rigor HIGH
expect "write works again once the symlinks are gone" 0 "$RC"
run check
expect "check passes again" 0 "$RC"

# A receipt naming another change id, or a non-PASS verdict, does not count.
python3 -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["verdict"] = "FAIL"
json.dump(d, open(p, "w"))
' "$KEYDIR/$ID_NOW.json"
run check
expect "a receipt whose verdict is not PASS does not cover" 1 "$RC"

# --- Not a git repository ----------------------------------------------------
mkdir "$SANDBOX/plain"
cd "$SANDBOX/plain"
run check
expect "check outside a git repo exits 2" 2 "$RC"
run write --lanes compliance --rigor HIGH
expect "write outside a git repo exits 2" 2 "$RC"
run id
expect "id outside a git repo exits 2" 2 "$RC"

if [ "$fails" -ne 0 ]; then
  printf '\n%s assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf '\nreview-receipt: all assertions passed\n'
