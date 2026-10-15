#!/usr/bin/env bash
set -euo pipefail

# Guard modes (hooks/lib/hook-io.sh):
#   - mtk_guard_mode maps MTK_<NAME>_ENFORCE to off|advisory|shadow|active,
#     case-insensitively, with scope-guard's legacy truthy set kept as active
#   - mtk_deny is byte-for-byte unchanged and still the unshadowable floor:
#     security-gate denies destructive commands with every MTK_*_ENFORCE=shadow
#   - mtk_deny_gated: shadow logs exactly one JSON line and is otherwise
#     invisible; active denies; advisory/off do nothing
#   - mtk_tree_fingerprint ignores .mtk/ even where .mtk/ is not gitignored
#   - mtk_hook_seen stamps land under $TMPDIR/mtk-hook-seen-<uid>/<root key>,
#     never in the repository; the key is fork-free and the steady state spawns
#     nothing
#   - mtk_liveness_tick counts sessions in <stamp dir>/.sessions
#   - shared-temp hardening (CWE-59/377): both directory levels are created
#     0700; a planted symlink at the base, the root dir, a stamp or .sessions is
#     never followed (victim files keep size and content) and a base that fails
#     the ownership/symlink check makes mtk_hook_seen_dir return 1, silently
#   - mtk_read_payload_nopy reads a payload with no timeout binary and no python
#   - an unknown MTK_*_ENFORCE value and a lost shadow line each print one
#     stderr line
#
# Assertions run in this (parent) shell; helpers are sourced only inside
# $( ... ) captures, so a counter is never lost in a subshell.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK_IO="$REPO_ROOT/hooks/lib/hook-io.sh"
GATE="$REPO_ROOT/hooks/security-gate.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/proj" "$SANDBOX/tmp"
PROJ="$(cd "$SANDBOX/proj" && pwd -P)"
export CLAUDE_PROJECT_DIR="$PROJ"
export TMPDIR="$SANDBOX/tmp"
for v in SCOPE_GUARD CONFIG_GUARD TEST_GUARD SECURITY_GATE FOO; do unset "MTK_${v}_ENFORCE" 2>/dev/null || true; done
unset MTK_CONFIG_GUARD 2>/dev/null || true
cd "$PROJ"

fails=0
expect() {
  local label="$1" want="$2" got="$3"
  if [ "$got" != "$want" ]; then
    printf 'FAIL: %s — expected %s, got %s\n' "$label" "$want" "$got" >&2
    fails=$((fails + 1))
  else
    printf '  PASS  %s\n' "$label"
  fi
}

# mode <NAME> <default> [VAR=value ...] — prints mtk_guard_mode's answer.
mode() {
  local name="$1" def="$2"; shift 2
  env "$@" bash -c '. "$1"; mtk_guard_mode "$2" "$3"' _ "$HOOK_IO" "$name" "$def"
}

# ============================ mode table =======================================

expect "SCOPE_GUARD unset → advisory" advisory "$(mode SCOPE_GUARD advisory)"
expect "SCOPE_GUARD empty → advisory" advisory "$(mode SCOPE_GUARD advisory MTK_SCOPE_GUARD_ENFORCE=)"
for v in 1 true TRUE yes YES on ON; do
  expect "SCOPE_GUARD=$v (legacy truthy) → active" active "$(mode SCOPE_GUARD advisory MTK_SCOPE_GUARD_ENFORCE="$v")"
done
expect "SCOPE_GUARD=0 → advisory" advisory "$(mode SCOPE_GUARD advisory MTK_SCOPE_GUARD_ENFORCE=0)"
expect "SCOPE_GUARD=false → advisory" advisory "$(mode SCOPE_GUARD advisory MTK_SCOPE_GUARD_ENFORCE=false)"
expect "SCOPE_GUARD=shadow → shadow" shadow "$(mode SCOPE_GUARD advisory MTK_SCOPE_GUARD_ENFORCE=shadow)"
expect "SCOPE_GUARD=SHADOW (case-insensitive) → shadow" shadow "$(mode SCOPE_GUARD advisory MTK_SCOPE_GUARD_ENFORCE=SHADOW)"
expect "SCOPE_GUARD=Active → active" active "$(mode SCOPE_GUARD advisory MTK_SCOPE_GUARD_ENFORCE=Active)"
expect "SCOPE_GUARD=OFF → off" off "$(mode SCOPE_GUARD advisory MTK_SCOPE_GUARD_ENFORCE=OFF)"
expect "SCOPE_GUARD=Advisory → advisory" advisory "$(mode SCOPE_GUARD advisory MTK_SCOPE_GUARD_ENFORCE=Advisory)"
expect "SCOPE_GUARD=garbage → default" advisory "$(mode SCOPE_GUARD advisory MTK_SCOPE_GUARD_ENFORCE=bogus 2>/dev/null)"

# mode_err <NAME> <default> [VAR=value ...] — prints only mtk_guard_mode's stderr.
mode_err() {
  local name="$1" def="$2"; shift 2
  env "$@" bash -c '. "$1"; mtk_guard_mode "$2" "$3"' _ "$HOOK_IO" "$name" "$def" 2>&1 >/dev/null
}
expect "unknown value: one stderr line naming the variable, value and default" \
  "[mtk] MTK_SCOPE_GUARD_ENFORCE=bogus not recognised; using advisory" \
  "$(mode_err SCOPE_GUARD advisory MTK_SCOPE_GUARD_ENFORCE=bogus)"
expect "unknown value on another guard: stderr line uses that guard's default" \
  "[mtk] MTK_FOO_ENFORCE=1 not recognised; using shadow" \
  "$(mode_err FOO shadow MTK_FOO_ENFORCE=1)"
expect "unset value: no stderr" "" "$(mode_err SCOPE_GUARD advisory)"
expect "empty value: no stderr" "" "$(mode_err SCOPE_GUARD advisory MTK_SCOPE_GUARD_ENFORCE=)"
expect "recognised value: no stderr" "" "$(mode_err FOO shadow MTK_FOO_ENFORCE=Active)"
for v in 0 false FALSE no NO; do
  expect "SCOPE_GUARD=$v (legacy falsy) → default, no stderr" "advisory|" \
    "$(mode SCOPE_GUARD advisory MTK_SCOPE_GUARD_ENFORCE="$v")|$(mode_err SCOPE_GUARD advisory MTK_SCOPE_GUARD_ENFORCE="$v")"
done

expect "other guard unset → its default" shadow "$(mode FOO shadow)"
expect "other guard: legacy truthy set is scope-guard only (1 → default)" shadow "$(mode FOO shadow MTK_FOO_ENFORCE=1 2>/dev/null)"
expect "other guard: on → default" shadow "$(mode FOO shadow MTK_FOO_ENFORCE=on 2>/dev/null)"
expect "other guard: active → active" active "$(mode FOO shadow MTK_FOO_ENFORCE=active)"
expect "other guard: ADVISORY → advisory" advisory "$(mode FOO shadow MTK_FOO_ENFORCE=ADVISORY)"
expect "other guard: off → off" off "$(mode FOO active MTK_FOO_ENFORCE=off)"
expect "CONFIG_GUARD: MTK_CONFIG_GUARD=1 → default" active "$(mode CONFIG_GUARD active MTK_CONFIG_GUARD=1)"
expect "invalid default falls back to advisory" advisory "$(mode FOO bogus)"
expect "malformed name → default" shadow "$(mode 'a-b' shadow)"

# ============================ mtk_deny unchanged ===============================

# Pinned checksum of the mtk_deny function text. It is the S3.18 floor path; a
# change here must be a deliberate, reviewed edit to this pin.
deny_sum="$(awk '/^mtk_deny\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$HOOK_IO" | cksum | tr -s ' ' | tr ' ' '/')"
expect "mtk_deny function is byte-for-byte unchanged" "3323764538/1013" "$deny_sum"

rc=0
err="$(env -u MTK_HOOK_ID bash -c '. "$1"; mtk_deny "floor reason" ""' _ "$HOOK_IO" 2>&1 >/dev/null)" || rc=$?
expect "mtk_deny with MTK_HOOK_ID unset still exits 2" 2 "$rc"
case "$err" in *"floor reason"*) pass_reason=yes ;; *) pass_reason=no ;; esac
expect "mtk_deny still prints its reason" yes "$pass_reason"

bash_payload() {
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash",
                  "tool_input": {"command": sys.argv[1]}}))
PY
}
gate_rc() { # $1 command — security-gate exit with every MTK_*_ENFORCE=shadow exported
  local rc=0
  MTK_SECURITY_GATE_ENFORCE=shadow MTK_SCOPE_GUARD_ENFORCE=shadow MTK_CONFIG_GUARD_ENFORCE=shadow \
    MTK_TEST_GUARD_ENFORCE=shadow bash "$GATE" <<<"$(bash_payload "$1")" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
expect "security-gate denies a force push with every *_ENFORCE=shadow" 2 "$(gate_rc 'git push --force origin main')"
expect "security-gate denies rm -rf / with every *_ENFORCE=shadow" 2 "$(gate_rc 'rm -rf /')"
expect "security-gate still allows git status" 0 "$(gate_rc 'git status')"
[ ! -e "$PROJ/.mtk/metrics/enforcement-shadow.jsonl" ] \
  && expect "security-gate never writes the shadow log" none none \
  || expect "security-gate never writes the shadow log" none "$(cat "$PROJ/.mtk/metrics/enforcement-shadow.jsonl")"

# ============================ mtk_deny_gated ===================================

LOG="$PROJ/.mtk/metrics/enforcement-shadow.jsonl"
gated() { # $1 mode — runs mtk_deny_gated, prints "rc|stdout|stderr"
  local rc=0 out err
  out="$(bash -c '. "$1"; mtk_deny_gated "$2" test-hook TEST-CODE "would deny" "toggle hint" "src/secret path.cs"' \
    _ "$HOOK_IO" "$1" 2>"$SANDBOX/gated.err")" || rc=$?
  err="$(cat "$SANDBOX/gated.err")"
  printf '%s|%s|%s' "$rc" "$out" "$err"
}

rm -rf "$PROJ/.mtk"
expect "shadow: exit 0, no stdout, no stderr" "0||" "$(gated shadow)"
n="$( [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0)"
expect "shadow: exactly one JSON line" 1 "$n"
shape="$(python3 - "$LOG" <<'PY' 2>&1 || true
import json, sys, subprocess
lines = open(sys.argv[1]).read().splitlines()
d = json.loads(lines[0])
want = subprocess.run(["cksum"], input=b"src/secret path.cs", capture_output=True).stdout.split()[0].decode()
ok = (sorted(d) == ["code", "hook", "target", "ts"] and d["hook"] == "test-hook"
      and d["code"] == "TEST-CODE" and d["target"] == want and d["ts"].endswith("Z"))
print("ok" if ok else "bad: %r (want target %s)" % (d, want))
PY
)"
expect "shadow: line has ts/hook/code/target, target is the cksum" ok "$shape"
grep -qF 'secret path' "$LOG" && raw=present || raw=absent
expect "shadow: raw target text never logged" absent "$raw"
gated shadow >/dev/null
n="$(wc -l < "$LOG" | tr -d ' ')"
expect "shadow: appends (second call → two lines)" 2 "$n"

rm -rf "$PROJ/.mtk"
r="$(gated active)"
expect "active: exits 2" 2 "${r%%|*}"
case "$r" in *"would deny"*"disable this guard: toggle hint"*) a=yes ;; *) a=no ;; esac
expect "active: mtk_deny reason + toggle on stderr" yes "$a"
[ -e "$LOG" ] && a=logged || a=none
expect "active: nothing logged" none "$a"

expect "advisory: exit 0, silent" "0||" "$(gated advisory)"
expect "off: exit 0, silent" "0||" "$(gated off)"
expect "unknown mode: exit 0, silent" "0||" "$(gated bogus)"
[ -e "$LOG" ] && a=logged || a=none
expect "advisory/off: nothing logged" none "$a"

# Write failure: .mtk is a FILE, so mkdir -p .mtk/metrics fails. Still exit 0
# and no stdout, but the loss is reported on stderr (one line).
rm -rf "$PROJ/.mtk"; : > "$PROJ/.mtk"
expect "shadow: mkdir failure → exit 0, no stdout, one stderr line" \
  "0||[mtk] shadow log not written: cannot create $PROJ/.mtk/metrics" "$(gated shadow)"
rm -f "$PROJ/.mtk"

# Append failure: the log path is a DIRECTORY, so the >> open fails.
mkdir -p "$LOG"
expect "shadow: append failure → exit 0, no stdout, one stderr line" \
  "0||[mtk] shadow log not written: cannot append to $LOG" "$(gated shadow)"
rm -rf "$PROJ/.mtk"
expect "advisory: still silent after a failed shadow write" "0||" "$(gated advisory)"

# ============================ fingerprint ignores .mtk/ ========================

FP="$SANDBOX/fp"
mkdir -p "$FP/src" "$FP/.mtk"
git -C "$FP" init -q
git -C "$FP" config user.email t@example.invalid
git -C "$FP" config user.name t
printf 'a\n' > "$FP/src/a.txt"
printf 'tracked\n' > "$FP/.mtk/tracked.json"
git -C "$FP" add -A
git -C "$FP" commit -qm init
fp() { CLAUDE_PROJECT_DIR="$FP" bash -c 'cd "$2" && . "$1" && mtk_tree_fingerprint' _ "$HOOK_IO" "$FP"; }
fp0="$(fp)"
mkdir -p "$FP/.mtk/metrics"; printf 'x\n' > "$FP/.mtk/metrics/x"
expect "fingerprint unchanged after an untracked .mtk/ write (not gitignored)" "$fp0" "$(fp)"
printf 'changed\n' > "$FP/.mtk/tracked.json"
expect "fingerprint unchanged after a tracked .mtk/ change" "$fp0" "$(fp)"
printf 'x\n' > "$FP/src/x"
fp2="$(fp)"
[ "$fp2" != "$fp0" ] && a=changed || a=same
expect "fingerprint changes after an untracked src/ write" changed "$a"
rm -f "$FP/src/x"
printf 'b\n' > "$FP/src/a.txt"
[ "$(fp)" != "$fp0" ] && a=changed || a=same
expect "fingerprint changes after a tracked src/ change" changed "$a"
printf 'a\n' > "$FP/src/a.txt"
expect "fingerprint returns to baseline when src/ is restored" "$fp0" "$(fp)"

# ============================ liveness stamps ==================================

# A space and a '+' in the root exercise the key's character mapping.
ST="$SANDBOX/stamp repo+x"
mkdir -p "$ST"
git -C "$ST" init -q
ST="$(cd "$ST" && pwd -P)"
# Expected key computed independently of hook-io (sed, not bash expansion).
key="$(printf '%s' "$ST" | sed 's/[^A-Za-z0-9._-]/_/g')"
MYUID="$(id -u)"
BASE="$TMPDIR/mtk-hook-seen-$MYUID"
SEEN="$BASE/$key"
# perm <path> — the 10-char mode string from ls -ld (BSD/GNU alike; any ACL/xattr
# marker after it is cut off).
perm() { local p; p="$(ls -ld "$1" 2>/dev/null | awk '{print $1}')"; printf '%s' "${p:0:10}"; }
# fsig <path> — "<type>:<size>:<content>" of a victim file, to prove it untouched.
fsig() { if [ -f "$1" ]; then printf 'file:%s:%s' "$(wc -c < "$1" | tr -d ' ')" "$(cat "$1")"; elif [ -e "$1" ]; then printf 'other'; else printf 'absent'; fi; }

rc=0
d="$(CLAUDE_PROJECT_DIR="$ST" bash -c 'cd "$2" && . "$1" && mtk_hook_seen_dir' _ "$HOOK_IO" "$ST")" || rc=$?
expect "mtk_hook_seen_dir before any hook ran: exit 0, prints the path" "0|$SEEN" "$rc|$d"
[ -e "$SEEN" ] && a=created || a=absent
expect "mtk_hook_seen_dir (reader) creates nothing" absent "$a"
# Hooks run above (security-gate) may already have made the per-user base for
# another root; start from none so the mode check below sees a fresh mkdir.
rm -rf "$BASE"

# umask 000: the 0700 below must come from mkdir -m, not from the umask.
rc=0
out="$(CLAUDE_PROJECT_DIR="$ST" bash -c 'umask 000; cd "$2" && . "$1" && mtk_hook_seen scope-guard.sh' _ "$HOOK_IO" "$ST" 2>&1)" || rc=$?
expect "mtk_hook_seen: exit 0, silent" "0|" "$rc|$out"
[ -f "$SEEN/scope-guard.sh" ] && a=present || a=missing
expect "mtk_hook_seen: stamp under \$TMPDIR/mtk-hook-seen-<uid>/<root, unsafe chars → _>" present "$a"
expect "mtk_hook_seen: base dir created mode 0700" "drwx------" "$(perm "$BASE")"
expect "mtk_hook_seen: per-root dir created mode 0700" "drwx------" "$(perm "$SEEN")"
n="$(find "$ST" -path "$ST/.git" -prune -o -type f -print | wc -l | tr -d ' ')"
expect "mtk_hook_seen: nothing written inside the repository" 0 "$n"
seen_dir() { CLAUDE_PROJECT_DIR="$1" bash -c 'cd "$2" && . "$1" && mtk_hook_seen_dir' _ "$HOOK_IO" "$ST"; }
d="$(seen_dir "$ST")"
expect "mtk_hook_seen_dir names the stamp directory (no cksum in the key)" "$SEEN" "$d"
expect "mtk_hook_seen_dir is stable across processes" "$d" "$(seen_dir "$ST")"
expect "mtk_hook_seen_dir ignores a trailing slash on CLAUDE_PROJECT_DIR" "$d" "$(seen_dir "$ST/")"
d="$(cd "$ST" && env -u CLAUDE_PROJECT_DIR bash -c '. "$1" && mtk_hook_seen_dir' _ "$HOOK_IO")"
expect "mtk_hook_seen_dir without CLAUDE_PROJECT_DIR keys by the repo root" "$SEEN" "$d"
d="$(CLAUDE_PROJECT_DIR=/elsewhere bash -c '. "$1" && mtk_hook_seen_dir "$2"' _ "$HOOK_IO" "$ST")"
expect "mtk_hook_seen_dir \$1 overrides the root" "$SEEN" "$d"

# Steady state forks nothing: every command on PATH is a logging pass-through
# shim, and PATH holds only the shims (an unshimmed command would print
# "command not found" on stderr). The first call may mkdir; the second call
# must not run cksum, cut, mkdir — or anything else.
SHIM="$SANDBOX/shim"; SHIMLOG="$SANDBOX/shim.log"
mkdir -p "$SHIM"
for c in dirname basename cksum cut mkdir tr sed awk cat date git touch python3 timeout gtimeout id mv ln stat chmod ls test; do
  real="$(command -v "$c" 2>/dev/null || true)"
  case "$real" in /*) ;; *) continue ;; esac
  printf '#!/bin/sh\nprintf "%%s\\n" "%s" >> "$SHIMLOG"\nexec "%s" "$@"\n' "$c" "$real" > "$SHIM/$c"
  chmod +x "$SHIM/$c"
done
rm -rf "$SEEN"
rc=0
out="$(cd "$ST" && SHIMLOG="$SHIMLOG" CLAUDE_PROJECT_DIR="$ST" PATH="$SHIM" "$BASH" -c '
  . "$1"
  mtk_hook_seen first.sh
  mtk_liveness_tick
  : > "$SHIMLOG"
  mtk_hook_seen second.sh
  mtk_hook_seen first.sh
  mtk_liveness_tick
' _ "$HOOK_IO" 2>&1)" || rc=$?
expect "mtk_hook_seen under shim PATH: exit 0, silent" "0|" "$rc|$out"
[ -f "$SEEN/first.sh" ] && [ -f "$SEEN/second.sh" ] && a=both || a=missing
expect "mtk_hook_seen under shim PATH: both stamps written" both "$a"
expect "mtk_liveness_tick under shim PATH: counted twice" 2 "$(cat "$SEEN/.sessions" 2>/dev/null || echo missing)"
calls="$(cat "$SHIMLOG" 2>/dev/null | tr '\n' ' ')"
expect "steady-state mtk_hook_seen + mtk_liveness_tick spawn no external process (no id/mkdir/mv/cksum)" "" "$calls"

# ============================ session counter ==================================

tick() { CLAUDE_PROJECT_DIR="$ST" bash -c 'cd "$2" && . "$1" && mtk_liveness_tick' _ "$HOOK_IO" "$ST" 2>&1; }
rm -rf "$SEEN"
for want in 1 2 3; do
  out="$(tick)"
  got="$(cat "$SEEN/.sessions" 2>/dev/null || echo missing)"
  expect "mtk_liveness_tick: .sessions → $want, silent" "$want|" "$got|$out"
done
printf 'garbage\n' > "$SEEN/.sessions"
tick >/dev/null
expect "mtk_liveness_tick: non-numeric .sessions restarts at 1" 1 "$(cat "$SEEN/.sessions")"
rc=0
out="$(CLAUDE_PROJECT_DIR="$ST" bash -c 'cd "$2" && . "$1" && mtk_hook_seen .sessions' _ "$HOOK_IO" "$ST" 2>&1)" || rc=$?
expect "mtk_hook_seen refuses a dot-name (cannot clobber .sessions)" "0||1" "$rc|$out|$(cat "$SEEN/.sessions")"
: > "$SANDBOX/notadir"
rc=0
out="$(CLAUDE_PROJECT_DIR="$ST" TMPDIR="$SANDBOX/notadir" bash -c 'cd "$2" && . "$1" && mtk_liveness_tick' _ "$HOOK_IO" "$ST" 2>&1)" || rc=$?
expect "mtk_liveness_tick: unwritable TMPDIR → exit 0, silent" "0|" "$rc|$out"
mkdir -p "$ST/tmp-tick"
rc=0
out="$(CLAUDE_PROJECT_DIR="$ST" TMPDIR="$ST/tmp-tick" bash -c 'cd "$2" && . "$1" && mtk_liveness_tick' _ "$HOOK_IO" "$ST" 2>&1)" || rc=$?
n="$(find "$ST/tmp-tick" -type f | wc -l | tr -d ' ')"
expect "mtk_liveness_tick: TMPDIR inside the repo → exit 0, silent, nothing written" "0||0" "$rc|$out|$n"

# ============================ shared-temp hardening (CWE-59/377) ===============

# Each case runs the real helpers in a child shell and reports "rc|output".
hs()   { local rc=0 o; o="$(CLAUDE_PROJECT_DIR="$ST" bash -c 'cd "$2" && . "$1" && mtk_hook_seen "$3"' _ "$HOOK_IO" "$ST" "$1" 2>&1)" || rc=$?; printf '%s|%s' "$rc" "$o"; }
tk()   { local rc=0 o; o="$(CLAUDE_PROJECT_DIR="$ST" bash -c 'cd "$2" && . "$1" && mtk_liveness_tick' _ "$HOOK_IO" "$ST" 2>&1)" || rc=$?; printf '%s|%s' "$rc" "$o"; }
sdir() { local rc=0 o; o="$(CLAUDE_PROJECT_DIR="$ST" bash -c 'cd "$2" && . "$1" && mtk_hook_seen_dir' _ "$HOOK_IO" "$ST" 2>&1)" || rc=$?; printf '%s|%s' "$rc" "$o"; }
victim() { printf 'precious victim data\n' > "$1"; }
VICTIM="$SANDBOX/victim.txt"
VSIG="file:21:precious victim data"

# 1. A symlink planted at a stamp path is never followed: the victim keeps its
#    size and content, and a dangling link never creates its target.
rm -rf "$BASE"; hs init.sh >/dev/null        # a legitimate, owned stamp dir
victim "$VICTIM"
ln -s "$VICTIM" "$SEEN/scope-guard.sh"
expect "symlinked stamp: mtk_hook_seen exit 0, silent" "0|" "$(hs scope-guard.sh)"
expect "symlinked stamp: victim file untouched (size and content)" "$VSIG" "$(fsig "$VICTIM")"
[ -L "$SEEN/scope-guard.sh" ] && a=link || a=replaced
expect "symlinked stamp: the link itself is left alone" link "$a"
ln -s "$SANDBOX/created-by-hook" "$SEEN/dangling.sh"
hs dangling.sh >/dev/null
expect "dangling stamp symlink: target never created" absent "$(fsig "$SANDBOX/created-by-hook")"
mkdir "$SEEN/dir.sh"
expect "stamp path is a directory: exit 0, silent" "0|" "$(hs dir.sh)"

# 2. A symlink planted at .sessions: no read-through, no write-through.
victim "$VICTIM"
ln -s "$VICTIM" "$SEEN/.sessions"
expect "symlinked .sessions: mtk_liveness_tick exit 0, silent" "0|" "$(tk)"
expect "symlinked .sessions: victim file untouched (size and content)" "$VSIG" "$(fsig "$VICTIM")"
rm -f "$SEEN/.sessions"
ln -s "$SANDBOX/created-by-tick" "$SEEN/.sessions"
tk >/dev/null
expect "dangling .sessions symlink: target never created" absent "$(fsig "$SANDBOX/created-by-tick")"
rm -f "$SEEN/.sessions"

# 2b. The ownership half of the check, exercised directly: a real, non-symlink
#     directory owned by another user (root's /usr) must fail it, and one of ours
#     must pass. Skipped when the suite itself runs as root.
if [ "$(id -u)" != 0 ] && [ -d /usr ] && [ ! -L /usr ] && [ ! -O /usr ]; then
  rc=0; bash -c '. "$1"; _mtk_hook_seen_owned_dir /usr' _ "$HOOK_IO" >/dev/null 2>&1 || rc=$?
  expect "owned-dir check: a directory owned by another user is refused" 1 "$rc"
  mkdir -p "$SANDBOX/own-dir"
  rc=0; bash -c '. "$1"; _mtk_hook_seen_owned_dir "$2"' _ "$HOOK_IO" "$SANDBOX/own-dir" >/dev/null 2>&1 || rc=$?
  expect "owned-dir check: our own directory passes (control)" 0 "$rc"
else
  printf '  SKIP  owned-dir check: running as root or /usr unusable\n'
fi

# 3. A base that is not ours. chown to another user is unavailable here, so the
#    planted base is a symlink to another directory: it fails [ ! -L ] the same
#    way a foreign directory fails [ -O ]. Planted at both the per-user name and
#    the old shared name, so the case also fails against the pre-fix layout.
OTHER="$SANDBOX/other-user"
rm -rf "$BASE" "$TMPDIR/mtk-hook-seen" "$OTHER"; mkdir -p "$OTHER"
ln -s "$OTHER" "$BASE"
ln -s "$OTHER" "$TMPDIR/mtk-hook-seen"
expect "symlinked base: mtk_hook_seen exit 0, silent" "0|" "$(hs scope-guard.sh)"
expect "symlinked base: mtk_liveness_tick exit 0, silent" "0|" "$(tk)"
expect "symlinked base: mtk_hook_seen_dir returns 1, prints nothing" "1|" "$(sdir)"
n="$(find "$OTHER" | wc -l | tr -d ' ')"
expect "symlinked base: nothing created through the link" 1 "$n"
rm -f "$BASE" "$TMPDIR/mtk-hook-seen"

# 4. Base is ours, the per-root directory is a planted symlink.
mkdir -m 700 "$BASE"
ln -s "$OTHER" "$SEEN"
expect "symlinked root dir: mtk_hook_seen exit 0, silent" "0|" "$(hs scope-guard.sh)"
expect "symlinked root dir: mtk_liveness_tick exit 0, silent" "0|" "$(tk)"
expect "symlinked root dir: mtk_hook_seen_dir returns 1, prints nothing" "1|" "$(sdir)"
n="$(find "$OTHER" | wc -l | tr -d ' ')"
expect "symlinked root dir: nothing written through the link" 1 "$n"
rm -f "$SEEN"

# 5. The base path is a regular file (not a directory): refused, not clobbered.
rmdir "$BASE"; victim "$BASE"
expect "base is a file: mtk_hook_seen exit 0, silent" "0|" "$(hs scope-guard.sh)"
expect "base is a file: mtk_hook_seen_dir returns 1, prints nothing" "1|" "$(sdir)"
expect "base is a file: file untouched" "$VSIG" "$(fsig "$BASE")"
rm -f "$BASE"

# 6. Recovery: once the plant is gone, stamping works again with 0700 dirs.
expect "after the plant is removed: mtk_hook_seen exit 0, silent" "0|" "$(hs scope-guard.sh)"
[ -f "$SEEN/scope-guard.sh" ] && [ ! -L "$SEEN/scope-guard.sh" ] && a=present || a=missing
expect "after the plant is removed: stamp written as a regular file" present "$a"
expect "after the plant is removed: base 0700" "drwx------" "$(perm "$BASE")"

# ============================ python-free payload read =========================

# A PATH with no timeout, no gtimeout and a python3 that only records it ran:
# mtk_read_payload_nopy must take the bash `read -t` tier and never touch python.
NOPY="$SANDBOX/nopy"; NOPYLOG="$SANDBOX/nopy.log"
mkdir -p "$NOPY"
for c in dirname; do
  real="$(command -v "$c")"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$real" > "$NOPY/$c"; chmod +x "$NOPY/$c"
done
printf '#!/bin/sh\nprintf "python3\\n" >> "$NOPYLOG"\nexit 1\n' > "$NOPY/python3"; chmod +x "$NOPY/python3"
payload='{"tool_input":{"command":"echo \"a  b\"\\n"},
"session_id":"s 1"}'
rc=0
got="$(printf '%s' "$payload" | NOPYLOG="$NOPYLOG" PATH="$NOPY" /bin/bash -c '. "$1"; mtk_read_payload_nopy' _ "$HOOK_IO" 2>"$SANDBOX/nopy.err")" || rc=$?
expect "mtk_read_payload_nopy (no timeout, no python): payload read verbatim" "$payload" "$got"
expect "mtk_read_payload_nopy: exit 0, no stderr" "0|" "$rc|$(cat "$SANDBOX/nopy.err")"
[ -e "$NOPYLOG" ] && a=ran || a=never
expect "mtk_read_payload_nopy: python3 never spawned" never "$a"

# Bounded: stdin stays open for 4s; a 1s bound must return well before that.
t0="$(date +%s)"
{ printf '{"x":1}'; sleep 4; } | { PATH="$NOPY" /bin/bash -c '. "$1"; mtk_read_payload_nopy 1 >/dev/null' _ "$HOOK_IO" || true; date +%s > "$SANDBOX/nopy.done"; }
t1="$(cat "$SANDBOX/nopy.done")"
[ $((t1 - t0)) -lt 3 ] && a=bounded || a="waited $((t1 - t0))s"
expect "mtk_read_payload_nopy: open stdin bounded by the deadline" bounded "$a"

# TMPDIR inside the repository: skipped, never a stamp in the repo.
mkdir -p "$ST/tmp-inside"
rc=0
out="$(CLAUDE_PROJECT_DIR="$ST" TMPDIR="$ST/tmp-inside" bash -c 'cd "$2" && . "$1" && mtk_hook_seen x' _ "$HOOK_IO" "$ST" 2>&1)" || rc=$?
expect "mtk_hook_seen: TMPDIR inside the repo → exit 0, silent" "0|" "$rc|$out"
n="$(find "$ST/tmp-inside" -type f | wc -l | tr -d ' ')"
expect "mtk_hook_seen: TMPDIR inside the repo → no stamp written" 0 "$n"

# Same, spelled differently: on a case-insensitive volume a TMPDIR inside the
# repo can carry another case than the root and slip past a string prefix test.
# The identity check (mtk_path_is_within, -ef) must still refuse it. Skipped on
# a case-sensitive volume, where the other spelling is a different directory.
ST_ALT="$(printf '%s' "$ST" | tr '[:lower:][:upper:]' '[:upper:][:lower:]')"
if [ "$ST_ALT" != "$ST" ] && [ -d "$ST_ALT/tmp-inside" ] && [ "$ST_ALT" -ef "$ST" ]; then
  rc=0
  out="$(CLAUDE_PROJECT_DIR="$ST" TMPDIR="$ST_ALT/tmp-inside" bash -c 'cd "$2" && . "$1" && mtk_hook_seen x' _ "$HOOK_IO" "$ST" 2>&1)" || rc=$?
  expect "mtk_hook_seen: case-variant TMPDIR inside the repo → exit 0, silent" "0|" "$rc|$out"
  n="$(find "$ST/tmp-inside" -type f | wc -l | tr -d ' ')"
  expect "mtk_hook_seen: case-variant TMPDIR inside the repo → no stamp written" 0 "$n"
else
  printf '  SKIP  case-variant TMPDIR: volume is case-sensitive\n'
fi

# Unwritable TMPDIR: never fails.
: > "$SANDBOX/notadir"
rc=0
out="$(CLAUDE_PROJECT_DIR="$ST" TMPDIR="$SANDBOX/notadir" bash -c 'cd "$2" && . "$1" && mtk_hook_seen x' _ "$HOOK_IO" "$ST" 2>&1)" || rc=$?
expect "mtk_hook_seen: unwritable TMPDIR → exit 0, silent" "0|" "$rc|$out"

echo
if [ "$fails" -eq 0 ]; then
  echo "=== guard modes: ALL PASS ==="
fi
exit "$fails"
