#!/usr/bin/env bash
set -euo pipefail

# test-compact-archive.sh — hooks/compact-archive.sh archives the compaction summary
# under .mtk/sessions/<session>/compact-<stamp>.md. Covers: archive with
# frontmatter + body + mode 0600, the workflow field, every no-write case
# (kill switch, empty summary, malformed JSON, un-ignored .mtk), empty stdout +
# exit 0 always, the 14-day prune, the shared hooks/lib/session_store.py CLI
# (prune, dir, ignored) and the liveness stamp. Failures exit 1 immediately (no
# subshell counters).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/compact-archive.sh"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available" >&2; exit 0; }

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf '  PASS  %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"

mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# run <project dir> <payload> [env...] — sets RC and OUT; never aborts the test.
run() {
  local proj="$1" payload="$2"; shift 2
  RC=0
  OUT="$(cd "$proj" && env CLAUDE_PROJECT_DIR="$proj" "$@" bash "$HOOK" <<<"$payload" 2>/dev/null)" || RC=$?
}
files_in() { find "$1/.mtk/sessions" -name 'compact-*.md' 2>/dev/null | sort; }

# A git project that ignores .mtk/.
P="$WORK/proj"; mkdir -p "$P"
git -C "$P" init -q
git -C "$P" symbolic-ref HEAD refs/heads/feat/pc
printf '.mtk/\n' > "$P/.gitignore"

PAYLOAD='{"hook_event_name":"PostCompact","session_id":"sess-1","trigger":"auto","compact_summary":"Summary line one.\nSecond line with \"quotes\" and š."}'

# --- 1. archive written: frontmatter, body, mode 0600, empty stdout ----------
run "$P" "$PAYLOAD"
[ "$RC" -eq 0 ] || fail "hook must exit 0 (got $RC)"
[ -z "$OUT" ] || fail "hook must print nothing on stdout. Got: $OUT"
F="$(files_in "$P")"
[ "$(wc -l <<<"$F" | tr -d ' ')" = "1" ] && [ -n "$F" ] || fail "expected exactly one archive file, got: $F"
case "$F" in */.mtk/sessions/sess-1/compact-2*Z.md) : ;; *) fail "unexpected archive path: $F" ;; esac
[ "$(mode_of "$F")" = "600" ] || fail "archive must be mode 0600, got $(mode_of "$F")"
head -1 "$F" | grep -qx -- '---' || fail "frontmatter must open with ---"
for k in 'session: sess-1' 'branch: feat/pc' 'trigger: auto' 'workflow: -'; do
  grep -qx -- "$k" "$F" || fail "frontmatter missing '$k'. File: $(cat "$F")"
done
grep -qE '^created: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$F" || fail "created must be ISO UTC. File: $(cat "$F")"
grep -q '^Summary line one\.$' "$F" || fail "body missing. File: $(cat "$F")"
grep -q 'Second line with "quotes"' "$F" || fail "escaped quotes must decode. File: $(cat "$F")"
pass "archive written with frontmatter, body, mode 0600, empty stdout, exit 0"

# --- 2. workflow field from an active workflow fixture -----------------------
mkdir -p "$P/.mtk/workflows"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"status":"active","updated_at":"%s","type":"implement","phase":"3","owner_session":"sess-wf"}\n' "$NOW" > "$P/.mtk/workflows/wf-test-123.json"
sleep 1
run "$P" "${PAYLOAD/sess-1/sess-wf}"
F2="$(files_in "$P" | grep sess-wf || true)"
[ -n "$F2" ] || fail "second archive not written"
grep -qx -- 'workflow: wf-test-123' "$F2" || fail "workflow field must name the active workflow. File: $(cat "$F2")"
pass "workflow field carries the active workflow id"
sleep 1
run "$P" "${PAYLOAD/sess-1/sess-other}"
F3="$(files_in "$P" | grep sess-other || true)"
[ -n "$F3" ] || fail "third archive not written"
grep -qx -- 'workflow: -' "$F3" || fail "another session's compaction must not name this session's workflow. File: $(cat "$F3")"
pass "another session's compaction archive does not name the workflow"

# --- 3. session id is sanitised before use in a path -------------------------
run "$P" '{"session_id":"a/../../evil id","trigger":"manual","compact_summary":"x"}'
[ ! -e "$P/evil id" ] && [ ! -e "$WORK/evil id" ] || fail "path traversal via session_id"
[ -d "$P/.mtk/sessions/a_.._.._evil_id" ] || fail "sanitised session dir expected"
run "$P" '{"session_id":"..","trigger":"manual","compact_summary":"x"}'
[ -z "$(ls "$P/.mtk/compact-"* 2>/dev/null)" ] || fail "'..' session id must write nothing"
pass "session_id sanitised to [A-Za-z0-9._-]; dot-leading ids rejected"

# --- 4. no-write cases --------------------------------------------------------
P2="$WORK/p2"; mkdir -p "$P2"; git -C "$P2" init -q; printf '.mtk/\n' > "$P2/.gitignore"
run "$P2" "$PAYLOAD" MTK_COMPACT_ARCHIVE=0
[ "$RC" -eq 0 ] && [ -z "$OUT" ] || fail "kill switch: exit 0 + empty stdout expected"
[ -z "$(files_in "$P2")" ] || fail "MTK_COMPACT_ARCHIVE=0 must write nothing"
for bad in '{"session_id":"s","trigger":"auto","compact_summary":""}' \
           '{"session_id":"s","trigger":"auto","compact_summary":"   "}' \
           '{"session_id":"s","trigger":"auto"}' \
           '{ not json' 'null' ''; do
  run "$P2" "$bad"
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] || fail "payload '$bad': exit 0 + empty stdout expected (rc=$RC out=$OUT)"
  [ -z "$(files_in "$P2")" ] || fail "payload '$bad' must write nothing"
done
P3="$WORK/p3"; mkdir -p "$P3"; git -C "$P3" init -q    # .mtk NOT ignored
run "$P3" "$PAYLOAD"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] || fail "un-ignored .mtk: exit 0 + empty stdout expected"
[ -z "$(files_in "$P3")" ] || fail "a git repo that does not ignore .mtk/ must get no archive"
pass "nothing written: kill switch, empty/missing summary, malformed JSON, un-ignored .mtk"

# --- 4b. skips that hide a gap leave one stderr line (still exit 0, empty stdout)
run_err() {
  local proj="$1" payload="$2"; RC=0
  ERR="$(cd "$proj" && env CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" <<<"$payload" 2>&1 >/dev/null)" || RC=$?
}
run_err "$P3" "$PAYLOAD"
[ "$RC" -eq 0 ] || fail "un-ignored .mtk: exit 0 expected (rc=$RC)"
case "$ERR" in *'.mtk/ is not git-ignored; compaction archive skipped'*) : ;; *) fail "un-ignored .mtk must say why on stderr. Got: $ERR" ;; esac
run_err "$P2" '{"session_id":"s","trigger":"auto"}'
case "$ERR" in *'no compact_summary'*) : ;; *) fail "a payload without compact_summary must say so on stderr. Got: $ERR" ;; esac
P5="$WORK/p5"; mkdir -p "$P5/.mtk"; git -C "$P5" init -q; printf '.mtk/\n' > "$P5/.gitignore"
: > "$P5/.mtk/sessions"                      # a file where the directory must go
run_err "$P5" "$PAYLOAD"
[ "$RC" -eq 0 ] || fail "write failure: exit 0 expected (rc=$RC)"
case "$ERR" in *'archive write failed'*) : ;; *) fail "a failed archive write must leave a stderr line. Got: $ERR" ;; esac
run "$P5" "$PAYLOAD"
[ -z "$OUT" ] || fail "write failure: stdout must stay empty"
run_err "$P2" '{"session_id":"s","trigger":"auto","compact_summary":""}'
[ -z "$ERR" ] || fail "an empty summary is a normal no-op and must stay quiet. Got: $ERR"
pass "un-ignored .mtk, missing compact_summary and a failed write each leave one stderr line; empty summary stays quiet"

# --- 5. not a git repo: archive is written ------------------------------------
P4="$WORK/p4"; mkdir -p "$P4"
run "$P4" "$PAYLOAD"
F4="$(files_in "$P4")"
[ -n "$F4" ] || fail "a non-git project must get the archive"
grep -qx -- 'branch: -' "$F4" || fail "non-git project: branch must be '-'. File: $(cat "$F4")"
pass "non-git project: archive written with branch -"

# --- 6. prune of session dirs older than 14 days ------------------------------
mkdir -p "$P/.mtk/sessions/old-sess" "$P/.mtk/sessions/new-sess"
printf 'x' > "$P/.mtk/sessions/old-sess/compact-20200101T000000Z.md"
touch -t 202001010000 "$P/.mtk/sessions/old-sess"
mkdir -p "$P/.mtk/workflows/keep-dir"; touch -t 202001010000 "$P/.mtk/workflows/keep-dir"
mkdir -p "$P/.mtk/sessions/edge-sess"
touch -t "$(date -v-13d +%Y%m%d%H%M 2>/dev/null || date -d '13 days ago' +%Y%m%d%H%M)" "$P/.mtk/sessions/edge-sess"
run "$P" "${PAYLOAD/sess-1/sess-prune}"
[ ! -e "$P/.mtk/sessions/old-sess" ] || fail "a >14d session dir must be pruned"
[ -d "$P/.mtk/sessions/edge-sess" ] || fail "a 13-day-old session dir must survive (threshold is 14 days)"
[ -d "$P/.mtk/sessions/new-sess" ] || fail "a fresh session dir must be kept"
[ -d "$P/.mtk/workflows/keep-dir" ] || fail "prune must stay under .mtk/sessions"
pass "prune removes >14d session dirs only under .mtk/sessions"

# A symlinked .mtk/sessions is never followed: its target's old subdirs survive.
P6="$WORK/p6"; P6T="$WORK/p6-target"; mkdir -p "$P6/.mtk" "$P6T/old-sess"
touch -t 202001010000 "$P6T/old-sess"
ln -s "$P6T" "$P6/.mtk/sessions"
run "$P6" "$PAYLOAD"
[ -d "$P6T/old-sess" ] || fail "prune must not follow a symlinked .mtk/sessions (target subdir deleted)"
pass "prune ignores a symlinked .mtk/sessions"

# --- 6b. the shared store directly (hooks/lib/session_store.py) -------------------
STORE="$REPO_ROOT/hooks/lib/session_store.py"
P7="$WORK/p7"; P7T="$WORK/p7-target"; mkdir -p "$P7/.mtk/sessions/old-a" "$P7/.mtk/sessions/fresh" "$P7T/old-linked"
touch -t 202001010000 "$P7/.mtk/sessions/old-a" "$P7T/old-linked"
ln -s "$P7T/old-linked" "$P7/.mtk/sessions/old-link"            # symlinked child: never touched
: > "$P7/.mtk/sessions/old-file"; touch -t 202001010000 "$P7/.mtk/sessions/old-file"   # not a dir
n="$(PYTHONDONTWRITEBYTECODE=1 python3 "$STORE" prune "$P7")" || fail "session_store prune exited non-zero"
[ "$n" = "1" ] || fail "session_store prune must report 1 removed dir, got: $n"
[ ! -e "$P7/.mtk/sessions/old-a" ] || fail "session_store prune must remove an old session dir"
[ -d "$P7/.mtk/sessions/fresh" ] && [ -L "$P7/.mtk/sessions/old-link" ] && [ -d "$P7T/old-linked" ] \
  && [ -f "$P7/.mtk/sessions/old-file" ] || fail "session_store prune must keep fresh dirs, symlinked children and files"
[ "$(python3 "$STORE" dir "$P7" 'a/../b c')" = "$P7/.mtk/sessions/a_.._b_c" ] || fail "session_store dir must sanitise the id"
rc=0; python3 "$STORE" dir "$P7" '..' >/dev/null || rc=$?
[ "$rc" -eq 1 ] || fail "session_store dir must reject a dot-leading id (exit 1), got $rc"
rc=0; python3 "$STORE" ignored "$P" || rc=$?;  [ "$rc" -eq 0 ] || fail "ignored: a repo that ignores .mtk/ must exit 0, got $rc"
rc=0; python3 "$STORE" ignored "$P3" || rc=$?; [ "$rc" -eq 3 ] || fail "ignored: a repo that does not ignore .mtk/ must exit 3, got $rc"
rc=0; python3 "$STORE" ignored "$P4" || rc=$?; [ "$rc" -eq 0 ] || fail "ignored: a non-git project must exit 0, got $rc"
pass "session_store: prune (real old dirs only), dir sanitising, ignored exit codes"

# --- 7. liveness stamp ----------------------------------------------------------
SEEN_DIR="$(CLAUDE_PROJECT_DIR="$P" bash -c 'source "$1"; mtk_hook_seen_dir' _ "$REPO_ROOT/hooks/lib/hook-io.sh")" \
  || fail "test setup: no stamp dir"
[ -f "$SEEN_DIR/compact-archive.sh" ] || fail "compact-archive.sh must stamp liveness in $SEEN_DIR"
pass "liveness stamp refreshed"

printf '\ntest-compact-archive: all checks passed\n'
