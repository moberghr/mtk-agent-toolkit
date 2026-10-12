#!/usr/bin/env bash
set -euo pipefail

# verify-completion binds completion evidence to the tree that was verified,
# per session:
#   - a session that changed nothing (pure Q&A ending "Done.") never blocks;
#   - a change made after the last verification re-arms the gap even when no
#     Edit/Write tool made it (sed -i, a formatter, a script);
#   - committing exactly the verified changes does not re-arm;
#   - one session's verification never satisfies another session's check;
#   - the hint never points a target repo at toolkit-only paths;
#   - stdin is read under a bound, so a payload pipe that never closes cannot
#     hang the Stop.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUDGET="$REPO_ROOT/hooks/context-budget.sh"
STOP="$REPO_ROOT/hooks/verify-completion"
START="$REPO_ROOT/hooks/session-start"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
STATE="$(mktemp -d)"
cleanup() { rm -rf "$WORK" "$STATE"; }
trap cleanup EXIT

git -C "$WORK" init -q
git -C "$WORK" config user.email t@example.com
git -C "$WORK" config user.name t
printf 'one\n' > "$WORK/a.txt"
git -C "$WORK" add a.txt
git -C "$WORK" commit -qm init
cd "$WORK"

export CLAUDE_PROJECT_DIR="$WORK"
export TMPDIR="$STATE"

post() { # $1 session  $2 tool  $3 command-or-path  $4 stdout
  python3 - "$@" <<'PY' | bash "$BUDGET" >/dev/null 2>&1 || true
import json, sys
sid, tool, arg = sys.argv[1], sys.argv[2], sys.argv[3]
out = sys.argv[4] if len(sys.argv) > 4 else ""
ti = {"command": arg} if tool == "Bash" else {"file_path": arg}
print(json.dumps({"session_id": sid, "hook_event_name": "PostToolUse", "tool_name": tool,
                  "tool_input": ti, "tool_response": {"stdout": out, "stderr": ""}}))
PY
}
start() { # $1 session
  printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"startup"}' "$1" \
    | bash "$START" >/dev/null 2>&1 || true
}
stop() { # $1 session  $2 message
  python3 - "$1" "$2" <<'PY' | bash "$STOP" 2>&1 || true
import json, sys
print(json.dumps({"session_id": sys.argv[1], "hook_event_name": "Stop",
                  "last_assistant_message": sys.argv[2], "stop_hook_active": False}))
PY
}

EVIDENCE='All done. Tests: 5 passed, exit code 0.'

# --- 1. pure Q&A: no tool calls, no changes → never blocks ------------------
start qa
out="$(stop qa 'Done.')"
[ -z "$out" ] || fail "Q&A reply ending 'Done.' with no edits must not block. Got: $out"
post qa2 Read "$WORK/a.txt"
out="$(stop qa2 'Done.')"
[ -z "$out" ] || fail "read-only session must not block. Got: $out"
printf '  PASS  session with no changes never blocks\n'

# --- 2. a Bash-made change with no verification still blocks ----------------
start b
post b Bash 'ls'
printf 'two\n' >> a.txt
out="$(stop b 'All done.')"
case "$out" in *'VERIFICATION GAP'*) : ;; *) fail "Bash-made change without verification must block. Got: $out" ;; esac
git checkout -q -- a.txt
printf '  PASS  Bash-made change without verification blocks\n'

# --- 3. change after verification re-arms, even without an Edit tool --------
start c
post c Bash 'pytest' '===== 5 passed ====='
printf 'three\n' >> a.txt
out="$(stop c "$EVIDENCE")"
case "$out" in *'changed after the last verification'*) : ;; *) fail "shell edit after verification must re-arm. Got: $out" ;; esac
printf '  PASS  shell edit after verification re-arms the gap\n'

# --- 4. committing exactly the verified tree does not re-arm -----------------
start d
printf 'four\n' >> a.txt
post d Bash 'pytest' '===== 5 passed ====='
git commit -qam 'verified change'
out="$(stop d "$EVIDENCE")"
[ -z "$out" ] || fail "committing the verified tree must not re-arm. Got: $out"
printf '  PASS  commit of the verified tree keeps the evidence fresh\n'

# --- 5. sessions do not satisfy each other -----------------------------------
start e1
start e2
post e2 Edit "$WORK/a.txt"
post e1 Bash 'pytest' '===== 5 passed ====='
out="$(stop e2 "$EVIDENCE")"
case "$out" in *'VERIFICATION GAP'*) : ;; *) fail "session e2 must not borrow e1's verification. Got: $out" ;; esac
out="$(stop e1 "$EVIDENCE")"
[ -z "$out" ] || fail "session e1 verified its own (unchanged) tree and must not block. Got: $out"
printf '  PASS  concurrent sessions keep separate ledgers\n'

# --- 6. hint text names the stack skill, never toolkit-only paths ------------
mkdir -p .claude
printf 'python\n' > .claude/tech-stack
start f
post f Edit "$WORK/a.txt"
out="$(stop f 'All done.')"
case "$out" in *'.claude/skills/tech-stack'*) fail "hint must not point at .claude/skills/tech-stack-*/SKILL.md. Got: $out" ;; esac
case "$out" in *'validate-toolkit'*) fail "hint must not mention validate-toolkit when the project has none. Got: $out" ;; esac
case "$out" in *'tech-stack-python'*) : ;; *) fail "hint must name the active tech-stack skill. Got: $out" ;; esac
mkdir -p scripts
printf '#!/usr/bin/env bash\n' > scripts/validate-toolkit.sh
out="$(stop f 'All done.')"
case "$out" in *'validate-toolkit'*) : ;; *) fail "hint must mention validate-toolkit when the project has it. Got: $out" ;; esac
printf '  PASS  hint text fits the target repo\n'

# --- 7. bounded stdin read ---------------------------------------------------
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  t0="$(date +%s)"
  { printf '{"session_id":"g","hook_event_name":"Stop","last_assistant_message":"hi"}'; sleep 12; } \
    | { bash "$STOP" >/dev/null 2>&1 || true; date +%s > "$STATE/stop-done"; }
  t1="$(cat "$STATE/stop-done")"
  [ $((t1 - t0)) -lt 10 ] || fail "verify-completion waited $((t1 - t0))s on an open stdin"
  printf '  PASS  stdin read is bounded\n'
else
  printf '  SKIP  no timeout/gtimeout binary; bounded read degrades to cat\n'
fi

printf '\nAll verify-completion tree checks passed.\n'
