#!/usr/bin/env bash
set -euo pipefail

# hooks/evidence-ledger.sh (formerly context-budget.sh) keeps only the evidence
# ledger verify-completion reads:
#   - an Edit/Write/MultiEdit/NotebookEdit bumps the edit sequence
#   - a write-pattern Bash command bumps it too; a read-only one does not
#   - a verification command is recorded with its outcome and a tree fingerprint
#   - it never records the session baseline itself
# and it never nudges: no CONTEXT BUDGET advisory, however many events, files or
# bytes a session accumulates (the file/operation/byte thresholds are gone).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/evidence-ledger.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
[ -x "$HOOK" ] || fail "hooks/evidence-ledger.sh must exist and be executable"

WORK="$(mktemp -d)"
STATE="$(mktemp -d)"
trap 'rm -rf "$WORK" "$STATE"' EXIT
git -C "$WORK" init -q
git -C "$WORK" config user.email t@example.com
git -C "$WORK" config user.name t
printf 'one\n' > "$WORK/a.txt"
git -C "$WORK" add a.txt
git -C "$WORK" commit -qm init
cd "$WORK"
export CLAUDE_PROJECT_DIR="$WORK" TMPDIR="$STATE"
# Old threshold knobs set as low as possible: none of them may wake a nudge.
export MTK_CTX_FILES_WARN=1 MTK_CTX_MODS_WARN=1 MTK_CTX_OPS_WARN=1 MTK_CONTEXT_WINDOW_TOKENS=100 MTK_CONTEXT_BUDGET_PCT=1

post() { # $1 session  $2 tool  $3 command-or-path  [$4 stdout] → hook stdout
  python3 - "$@" <<'PY' | bash "$HOOK" 2>/dev/null || true
import json, sys
sid, tool, arg = sys.argv[1], sys.argv[2], sys.argv[3]
out = sys.argv[4] if len(sys.argv) > 4 else ""
if tool == "Bash":
    ti = {"command": arg}
elif tool == "NotebookEdit":
    ti = {"notebook_path": arg, "new_source": "x = 1", "edit_mode": "replace"}
elif tool == "MultiEdit":
    ti = {"file_path": arg, "edits": [{"old_string": "a", "new_string": "b"}]}
else:
    ti = {"file_path": arg}
print(json.dumps({"session_id": sid, "hook_event_name": "PostToolUse", "tool_name": tool,
                  "tool_input": ti, "tool_response": {"stdout": out, "stderr": ""}}))
PY
}
ledger() { # $1 session → ledger path
  bash -c 'source "$1/hooks/lib/hook-io.sh"; mtk_session_bind "{\"session_id\":\"$2\"}"; mtk_session_file' _ "$REPO_ROOT" "$1"
}
field() { grep "^$2=" "$(ledger "$1")" | cut -d= -f2- | tr -d "'"; }

# --- the ledger never records the baseline (post-tool it would already hold the
# tool's effect; session-start and the PreToolUse hooks own it) -----------------
post s1 Edit "$WORK/a.txt" >/dev/null
[ -z "$(field s1 session_start_tree)" ] || fail "the PostToolUse ledger must not record a session baseline"
printf '  PASS  ledger leaves the session baseline to session-start / PreToolUse\n'

# --- edit bumps; read-only Bash does not; write-pattern Bash does ---------------
post s1 Edit "$WORK/a.txt" >/dev/null
e1="$(field s1 last_edit_seq)"; [ "${e1:-0}" -gt 0 ] || fail "Edit must bump last_edit_seq (got '$e1')"
post s1 Bash 'ls -la' >/dev/null
[ "$(field s1 last_edit_seq)" = "$e1" ] || fail "read-only Bash must not bump last_edit_seq"
post s1 Bash "sed -i.bak 's/one/two/' a.txt" >/dev/null
e2="$(field s1 last_edit_seq)"; [ "$e2" -gt "$e1" ] || fail "write-pattern Bash must bump last_edit_seq ($e1 -> $e2)"
printf '  PASS  edit sequence: Edit and write-pattern Bash bump it, read-only Bash does not\n'

# --- MultiEdit and NotebookEdit are edits too ----------------------------------
# Outside git verify-completion compares edit and verification sequence numbers,
# so an edit tool that does not bump the edit sequence after a verification run
# would let the stale verification stand.
m0="$(field s1 mods)"
post s1 MultiEdit "$WORK/a.txt" >/dev/null
e3="$(field s1 last_edit_seq)"; [ "$e3" -gt "$e2" ] || fail "MultiEdit must bump last_edit_seq ($e2 -> $e3)"
[ "$(field s1 mods)" -gt "$m0" ] || fail "MultiEdit must count as a modification"
post s1 NotebookEdit "$WORK/nb.ipynb" >/dev/null
e4="$(field s1 last_edit_seq)"; [ "$e4" -gt "$e3" ] || fail "NotebookEdit must bump last_edit_seq ($e3 -> $e4)"
[ "$(field s1 last_edit_seq)" = "$(field s1 event_seq)" ] || fail "NotebookEdit's edit sequence must be its own event"
printf '  PASS  MultiEdit and NotebookEdit bump the edit sequence\n'

# --- verification recorded with outcome + fingerprint --------------------------
post s1 Bash 'pytest' '===== 5 passed =====' >/dev/null
[ "$(field s1 last_verification_command)" = "pytest" ] || fail "verification command not recorded"
[ "$(field s1 last_verification_status)" = "pass" ] || fail "verification outcome not classified (got '$(field s1 last_verification_status)')"
[ -n "$(field s1 last_verification_tree)" ] || fail "verification must record a tree fingerprint"
printf '  PASS  verification recorded with outcome and tree fingerprint\n'

# --- never nudges ---------------------------------------------------------------
all=""
for i in $(seq 1 30); do
  printf 'x%s\n' "$i" > "$WORK/f$i.txt"
  all="${all}$(post s2 Read "$WORK/f$i.txt")$(post s2 Edit "$WORK/f$i.txt")$(post s2 Bash "echo $i")"
done
[ -z "$all" ] || fail "the ledger must never emit output (no CONTEXT BUDGET nudges). Got: $all"
printf '  PASS  no threshold nudges, however many events\n'

printf '\nAll evidence-ledger checks passed.\n'
