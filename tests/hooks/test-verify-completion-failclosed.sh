#!/usr/bin/env bash
set -euo pipefail

# The Stop gate may skip a completion claim only when it KNOWS the session
# changed nothing. Missing state must not read as "unchanged":
#   7. no ledger, or a Stop payload without the session_id the ledger was
#      written under, or a resumed session → the gap checks still run
#   8. the baseline fingerprint is taken in PreToolUse, before the first tool
#      changes anything (a PostToolUse baseline already contains the change)
#   9. one unreadable file must not blind the fingerprint to later paths
#  10. stdin is bounded even without timeout/gtimeout (stock macOS)
#  11. outside git (seq fallback) a Bash command that writes files after the
#      last verification re-arms the gap

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUDGET="$REPO_ROOT/hooks/evidence-ledger.sh"
STOP="$REPO_ROOT/hooks/verify-completion"
START="$REPO_ROOT/hooks/session-start"
FORMAT="$REPO_ROOT/hooks/format-on-edit.sh"
SCOPE="$REPO_ROOT/hooks/scope-guard.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
STATE="$(mktemp -d)"
cleanup() { chmod -R u+rw "$WORK" 2>/dev/null || true; rm -rf "$WORK" "$STATE"; }
trap cleanup EXIT

git -C "$WORK" init -q
git -C "$WORK" config user.email t@example.com
git -C "$WORK" config user.name t
printf 'one\n' > "$WORK/a.txt"
git -C "$WORK" add a.txt
git -C "$WORK" commit -qm init
cd "$WORK"
export CLAUDE_PROJECT_DIR="$WORK" TMPDIR="$STATE"

payload() { python3 -c 'import json,sys;d=json.loads(sys.argv[1]);print(json.dumps(d))' "$1"; }
post_bash() { # $1 session  $2 command
  python3 -c 'import json,sys;print(json.dumps({"session_id":sys.argv[1],"tool_name":"Bash","tool_input":{"command":sys.argv[2]},"tool_response":{"stdout":""}}))' "$1" "$2" \
    | bash "$BUDGET" >/dev/null 2>&1 || true
}
pre_bash() { # PreToolUse Bash: format-on-edit --flush-before-verify
  python3 -c 'import json,sys;print(json.dumps({"session_id":sys.argv[1],"tool_name":"Bash","tool_input":{"command":sys.argv[2]}}))' "$1" "$2" \
    | bash "$FORMAT" --flush-before-verify >/dev/null 2>&1 || true
}
start() { printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"%s"}' "$1" "${2:-startup}" \
  | bash "$START" >/dev/null 2>&1 || true; }
stop() { # $1 session ('' = omit)  $2 message
  python3 -c '
import json, sys
d = {"hook_event_name": "Stop", "last_assistant_message": sys.argv[2], "stop_hook_active": False}
if sys.argv[1]:
    d["session_id"] = sys.argv[1]
print(json.dumps(d))' "$1" "$2" | bash "$STOP" 2>&1 || true
}
gap() { case "$1" in *'VERIFICATION GAP'*) return 0 ;; esac; return 1; }
CLAIM='All done. Implementation complete.'

# --- 7a. no ledger at all + dirty tree → gap ----------------------------------
printf 'dirty\n' >> a.txt
out="$(stop never-seen "$CLAIM")"
gap "$out" || fail "7a: no ledger with a dirty tree must not pass silently. Got: $out"
git checkout -q -- a.txt
printf '  PASS  7a: no ledger is unknown, not unchanged\n'

# --- 7b. Stop payload without session_id, ledger written under one → gap -----
start s7b
printf 'edit\n' >> a.txt
out="$(stop '' "$CLAIM")"
gap "$out" || fail "7b: Stop without session_id must not read as unchanged. Got: $out"
git checkout -q -- a.txt
printf '  PASS  7b: missing session_id falls through to the gap checks\n'

# --- 7c. resume: wired, and an existing baseline is kept ----------------------
python3 - "$REPO_ROOT/hooks/hooks.json" <<'PY' || fail "7c: SessionStart matcher for session-start must include resume"
import json, sys
d = json.load(open(sys.argv[1]))["hooks"]["SessionStart"]
ok = any("resume" in (m.get("matcher") or "") and any("session-start" in h.get("command", "") for h in m.get("hooks", [])) for m in d)
sys.exit(0 if ok else 1)
PY
start s7c
printf 'edit\n' >> a.txt
start s7c resume
out="$(stop s7c "$CLAIM")"
gap "$out" || fail "7c: resume must not overwrite the baseline with the changed tree. Got: $out"
git checkout -q -- a.txt
printf '  PASS  7c: resume wired, baseline kept\n'

# --- 8. baseline before the first tool (PreToolUse), not after ----------------
pre_bash s8 "sed -i.bak s/one/two/ a.txt"
printf 'two\n' > a.txt
post_bash s8 "sed -i.bak s/one/two/ a.txt"
out="$(stop s8 "$CLAIM")"
gap "$out" || fail "8: a Bash edit made by the very first tool must count as a change. Got: $out"
git checkout -q -- a.txt
printf '  PASS  8: baseline is recorded in PreToolUse\n'

# --- 9. an unreadable file does not blind the fingerprint ----------------------
printf 'secret\n' > a-secret.txt; chmod 000 a-secret.txt
printf 'b\n' > b.txt
fp() { bash -c 'source "$0/hooks/lib/hook-io.sh"; mtk_tree_fingerprint' "$REPO_ROOT" 2>/dev/null; }
rc=0; fp1="$(fp)" || rc=$?
[ "$rc" -ne 0 ] || fail "9: an unreadable file must make the fingerprint return non-zero"
printf 'changed\n' > b.txt
fp2="$(fp)" || true
[ "$fp1" != "$fp2" ] || fail "9: a change to a later path must still change the fingerprint"
chmod 644 a-secret.txt; rm -f a-secret.txt b.txt
printf '  PASS  9: unreadable file is marked, later paths still hashed\n'

# --- 10. bounded read without timeout/gtimeout ---------------------------------
BIN="$STATE/bin"; mkdir -p "$BIN"
for tool in dirname cat sleep; do ln -sf "$(command -v "$tool")" "$BIN/$tool"; done
ln -sf "$(python3 -c 'import sys;print(sys.executable)')" "$BIN/python3"
t0="$(date +%s)"
{ printf '{"x":1}'; sleep 8; } | { PATH="$BIN" /bin/bash -c 'source "$0/hooks/lib/hook-io.sh"; mtk_read_payload 2 >/dev/null' "$REPO_ROOT" || true; date +%s > "$STATE/done"; }
t1="$(cat "$STATE/done")"
[ $((t1 - t0)) -lt 6 ] || fail "10: mtk_read_payload waited $((t1 - t0))s with no timeout binary"
printf '  PASS  10: stdin bounded via python3 when timeout is absent\n'

# --- 11. seq fallback: a Bash write after verification re-arms (no git) -------
NOGIT="$STATE/nogit"; mkdir -p "$NOGIT"; printf 'one\n' > "$NOGIT/a.txt"
seq_bash() { # $1 session  $2 command  $3 stdout
  python3 -c 'import json,sys;print(json.dumps({"session_id":sys.argv[1],"tool_name":"Bash","tool_input":{"command":sys.argv[2]},"tool_response":{"stdout":sys.argv[3]}}))' "$1" "$2" "$3" \
    | ( cd "$NOGIT" && CLAUDE_PROJECT_DIR="$NOGIT" bash "$BUDGET" >/dev/null 2>&1 ) || true
}
seq_stop() {
  python3 -c 'import json,sys;print(json.dumps({"session_id":sys.argv[1],"hook_event_name":"Stop","last_assistant_message":sys.argv[2],"stop_hook_active":False}))' "$1" "$2" \
    | ( cd "$NOGIT" && CLAUDE_PROJECT_DIR="$NOGIT" bash "$STOP" 2>&1 ) || true
}
seq_bash s11 "pytest" "===== 5 passed ====="
out="$(seq_stop s11 'All done. Tests: 5 passed, exit code 0.')"
gap "$out" && fail "11: fresh verification outside git must not gap. Got: $out"
seq_bash s11 "sed -i.bak s/one/two/ a.txt" ""
out="$(seq_stop s11 'All done. Tests: 5 passed, exit code 0.')"
case "$out" in *'re-armed'*) : ;; *) fail "11: a Bash write after verification must re-arm outside git. Got: $out" ;; esac
seq_bash s11 "pytest --collect-only" "5 tests collected"
out="$(seq_stop s11 'All done. Tests: 5 passed, exit code 0.')"
case "$out" in *'re-armed'*) : ;; *) fail "11: pytest --collect-only must not count as fresh verification. Got: $out" ;; esac
printf '  PASS  11: Bash writes bump the edit seq; --collect-only is not verification\n'

printf '\nAll verify-completion fail-closed checks passed.\n'
