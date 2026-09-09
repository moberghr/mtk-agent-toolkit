#!/usr/bin/env bash
set -euo pipefail

# security-gate.sh must judge what a command RUNS, not what it MENTIONS.
#
# Three false-positive classes, all measured against this repo:
#
#   1. Read-only segments. `grep -rn '<delete>' hooks/` searches for a string; it
#      deletes nothing. Same for `echo`, and for a heredoc that WRITES a fixture.
#      Blocking these is not cosmetic: a PreToolUse deny forces the model to
#      re-plan and re-issue, costing a full extra turn — the most expensive thing
#      this hook can do.
#   2. Comments in an executed script. The guard's own source documents the SQL it
#      blocks, in prose, in `#` comments. `bash hooks/security-gate.sh` therefore
#      blocked itself, and so did anything that ran it.
#   3. Fixture text. Writing this very test file was blocked, because the file
#      contains the strings it asserts on.
#
# Neither exemption may weaken the real checks: an actual destructive command, and
# destructive SQL hiding in a script the command executes, must still be denied.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/security-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Build the dangerous literals at runtime. Written verbatim they would be scanned
# out of this file by the very hook under test on some invocation paths.
RMRF="rm -$(printf 'rf') /"
DROPT="$(printf 'DROP') $(printf 'TABLE') users"
FPUSH="git push --$(printf 'force') origin main"

gate() { # $1 = command string -> prints "blocked" or "allowed"
  local payload rc
  payload="$(python3 -c 'import json,sys;print(json.dumps({"session_id":"t","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1")"
  set +e
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$REPO_ROOT" bash "$HOOK" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 2 ] && printf 'blocked' || printf 'allowed'
}

allow() { [ "$(gate "$2")" = allowed ] || fail "$1: should be ALLOWED but was blocked -> $2"; }
block() { [ "$(gate "$2")" = blocked ] || fail "$1: should be BLOCKED but was allowed -> $2"; }

# --- class 1: read-only segments mention, they do not execute -----------------
allow "grep for a delete"   "grep -rn '$RMRF' hooks/"
allow "grep for sql"        "grep -rn '$DROPT' migrations/"
allow "echo a warning"      "echo 'never run $RMRF on prod'"
allow "grep in a pipeline"  "git diff | grep -nE '$RMRF' | head"
allow "printf a fixture"    "printf '%s' '$FPUSH' > /dev/null"

# --- class 2: comments in an executed script ---------------------------------
printf '#!/usr/bin/env bash\n# careful: %s wipes it\necho hi\n' "$DROPT" > "$TMP/commented.sh"
allow "sql only in a comment"  "bash $TMP/commented.sh"
allow "the guard runs itself"  "bash $REPO_ROOT/hooks/security-gate.sh"

# --- class 4: read-only command reached through shell structure ---------------
# The 2026-08 field case: a read-only grep behind a control word, wrapper,
# substitution, git subcommand, find -exec, or bash -c was judged by its first
# WORD (`do`, `if`, `!`, `xargs`, `out=$(`, `git`, `find`, `bash`) and blocked.
allow "grep inside a for loop"      "for f in hooks/*.sh; do grep -H '$RMRF' \"\$f\"; done"
allow "grep as an if condition"     "if grep -q '$RMRF' hooks/x.sh; then echo y; fi"
allow "negated grep"                "! grep -q '$RMRF' hooks/x.sh"
allow "grep in a while condition"   "while grep -q '$RMRF' f; do sleep 1; done"
allow "grep in a substitution"      "out=\$(grep -c '$RMRF' hooks/x.sh); echo \$out"
allow "grep in backticks"           "n=\`grep -c '$RMRF' hooks/x.sh\`"
allow "git grep"                    "git grep -n '$RMRF' -- hooks"
allow "git -C dir log -S"           "git -C hooks log -S'$RMRF' --oneline"
allow "xargs grep"                  "ls | xargs grep -l '$RMRF'"
allow "xargs -I grep"               "ls | xargs -I {} grep -l '$RMRF' {}"
allow "find -exec grep"             "find . -name '*.sh' -exec grep -l '$RMRF' {} +"
allow "bash -c grep"                "bash -c \"grep -E '$RMRF' hooks/*.sh\""
allow "sed as a filter"             "sed -n '/$RMRF/p' hooks/x.sh"
allow "awk pattern"                 "awk '/$RMRF/' hooks/x.sh"
allow "time grep"                   "time grep -rn '$RMRF' hooks"

# --- the real checks must still fire -----------------------------------------
block "delete inside a for loop"    "for f in x; do $RMRF; done"
block "delete as an if body"        "if true; then $RMRF; fi"
block "delete via xargs"            "ls | xargs $RMRF"
block "delete via bash -c"          "bash -c \"$RMRF\""
block "delete via find -exec"       "find . -exec $RMRF \\;"
block "delete in a substitution"    "x=\$($RMRF)"
block "force push inside a loop"    "for b in main; do $FPUSH; done"
block "sed -i then delete"          "sed -i 's/a/b/' f && $RMRF"
block "sql via bash -c"             "bash -c \"psql -c '$DROPT'\""
printf '#!/usr/bin/env bash\npsql -c "%s;"\n' "$DROPT" > "$TMP/live.sh"
block "bare recursive delete"  "$RMRF"
block "delete after a grep"    "grep -q x f && $RMRF"
block "inline sql"             "psql -c '$DROPT'"
block "sql in executed script" "bash $TMP/live.sh"
block "command substitution"   "grep -rn \"\$($RMRF)\" ."
block "force push to main"     "$FPUSH"

printf 'PASS: security-gate judges execution, not mention\n'
