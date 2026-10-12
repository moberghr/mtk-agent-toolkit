#!/usr/bin/env bash
set -euo pipefail

# The current security gate must deny everything the de0c626 gate denied.
#
# WHY. Twice a "more precise" rewrite replaced the old regex gate and some
# destructive shapes it had caught started passing again. The gate is now the
# union of precise token checks and that regex set (hooks/lib/gate-backstop.sh).
# This test enforces the union: it extracts the de0c626 gate into a temp dir,
# runs both gates over every probe in fixtures/security-gate-superset.cases,
# and fails on any probe the old gate denies and the current one allows. The
# one permitted difference is a git/gh message body (labels starting
# `msg-body:`): prose that mentions a command does not run it.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CASES="$SCRIPT_DIR/fixtures/security-gate-superset.cases"
BASE_REV="de0c626"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -f "$CASES" ] || fail "probe list missing: $CASES"
if ! git -C "$REPO_ROOT" cat-file -e "${BASE_REV}^{commit}" 2>/dev/null; then
  printf 'SKIP: base revision %s is not in this clone (shallow?) — superset not checked\n' "$BASE_REV"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/base" "$TMP/cwd"
git -C "$REPO_ROOT" archive "$BASE_REV" hooks | tar -x -C "$TMP/base"

python3 - "$CASES" "$TMP/base/hooks/security-gate.sh" "$REPO_ROOT/hooks/security-gate.sh" "$TMP/cwd" <<'PY'
import json, subprocess, sys

cases_path, base_gate, new_gate, cwd = sys.argv[1:5]

def conv(c):
    # Placeholders are split so this file never holds the literal it stands for.
    for k, v in [("@GP@", "git pu" + "sh"), ("@FWL@", "--force-with-" + "lease"), ("@FF@", "-" + "f"),
                 ("@DR@", "DR" + "OP"), ("@TB@", "TA" + "BLE"), ("@DELL@", "dele" + "te from users"),
                 ("@RH@", "git reset --" + "hard"), ("@GCL@", "git cle" + "an"), ("@RM@", "rm -r" + "f"),
                 ("@DROPDB@", "DR" + "OP DATABASE"), ("@DROP@", "DR" + "OP TABLE"), ("@droplc@", "dr" + "op table"),
                 ("@TRUNCB@", "trun" + "cate users"), ("@TRUNC@", "TRUN" + "CATE TABLE"),
                 ("@DEL@", "DELE" + "TE FROM users"), ("@EFDROP@", "ef database dr" + "op")]:
        c = c.replace(k, v)
    return c

def denied(gate, cmd):
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}})
    r = subprocess.run(["bash", gate], input=payload, capture_output=True, text=True, cwd=cwd,
                       env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
                            "HOME": cwd, "CLAUDE_PROJECT_DIR": cwd})
    return r.returncode == 2

text = open(cases_path).read()
blocks = [b.strip("\n") for b in text.split("\n====\n")[1:]]
checked = base_denies = 0
regressions = []
for b in blocks:
    label, _, body = b.partition("\n")
    if not body:
        continue
    cmd = conv(body)
    checked += 1
    if not denied(base_gate, cmd):
        continue
    base_denies += 1
    if label.startswith("msg-body:"):
        continue
    if not denied(new_gate, cmd):
        regressions.append(label)

print(f"checked {checked} probes; de0c626 denies {base_denies}")
if regressions:
    for r in regressions:
        print(f"FAIL: de0c626 denies, current gate allows: {r}", file=sys.stderr)
    sys.exit(1)
PY
printf 'PASS: current gate denies everything de0c626 denied (message bodies excepted)\n'
