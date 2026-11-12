#!/usr/bin/env bash
set -euo pipefail

# Recursive force-delete decisions, pinned against the 9.4.2 gate.
#
# The rule (rm_broad in hooks/lib/gate-backstop.sh): a delete the 9.4.2 gate
# denied is allowed only when every operand is on the allow-list; a delete it
# allowed stays allowed unless it is one of the named bypasses. Each row below
# carries the 9.4.2 decision as a literal (CI clones shallow, so it cannot be
# recomputed from history), the decision expected now, and — where the two
# differ — why. A row whose expected decision differs from 9.4.2 without a
# reason fails, so every change of behaviour is a deliberate, annotated one.
#
# Shapes use @R@ for the delete command and <LF> for a newline; the literals
# are assembled at run time, so this file never contains them verbatim (the
# live gate scans scripts a command executes).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="${MTK_TEST_GATE:-$REPO_ROOT/hooks/security-gate.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$GATE" "$TMP" <<'PY'
import json, os, subprocess, sys
gate, tmp = sys.argv[1], sys.argv[2]
R = "r" + "m"

# (decision of the 9.4.2 gate, decision now, reason when they differ, shape)
ROWS = [
    ('A', 'A', '', '@R@ -rf build'),
    ('D', 'A', 'deny->allow: every operand on the allow-list', '@R@ -rf ./build'),
    ('A', 'A', '', '@R@ -rf node_modules dist'),
    ('D', 'A', 'deny->allow: every operand on the allow-list', '@R@ -rf .next'),
    ('D', 'A', 'deny->allow: every operand on the allow-list', '@R@ -rf /tmp/x'),
    ('D', 'A', 'deny->allow: every operand on the allow-list', '@R@ -rf /private/tmp/build-abc'),
    ('D', 'D', '', '@R@ -rf /'),
    ('D', 'D', '', '@R@ -rf .'),
    ('D', 'D', '', '@R@ -rf ..'),
    ('D', 'D', '', '@R@ -rf ~'),
    ('D', 'D', '', '@R@ -rf ~/x/cache'),
    ('D', 'D', '', '@R@ -rf $HOME/.cache/foo'),
    ('D', 'D', '', '@R@ -rf "$TMPDIR/x"'),
    ('D', 'D', '', '@R@ -rf ${TMPDIR}/build'),
    ('D', 'D', '', '@R@ -rf *'),
    ('A', 'A', '', '@R@ -rf build/*'),
    ('A', 'A', '', '@R@ -rf dist/*'),
    ('A', 'A', '', '@R@ -rf bin/Debug/*'),
    ('D', 'D', '', '@R@ -rf **/bin'),
    ('A', 'A', '', '@R@ -rf {bin,obj}'),
    ('A', 'D', 'allow->deny: brace alternative names a broad path', '@R@ -rf {a,/}'),
    ('D', 'D', '', '@R@ -rf {/,x}'),
    ('D', 'D', '', '@R@ -rf $(mktemp -d)'),
    ('D', 'D', '', '@R@ -rf "${tmpdir}"'),
    ('D', 'D', '', '@R@ -rf $WORKDIR/out'),
    ('D', 'D', '', '@R@ -rf /tmp/x-$$'),
    ('D', 'D', '', 'trap \'@R@ -rf "$d"\' EXIT'),
    ('D', 'A', 'deny->allow: every operand on the allow-list', '@R@ -rf build > /dev/null'),
    ('D', 'A', 'deny->allow: every operand on the allow-list', '@R@ -rf ./build 2>/dev/null'),
    ('D', 'A', 'deny->allow: every operand on the allow-list', '@R@ -rf ./build >/dev/null 2>&1'),
    ('D', 'A', 'deny->allow: every operand on the allow-list', '@R@ -rf ./build || true'),
    ('D', 'A', 'deny->allow: every operand on the allow-list', '@R@ -rf ./a && echo done'),
    ('D', 'A', 'deny->allow: every operand on the allow-list', '@R@ -rf ./build # clean /tmp'),
    ('D', 'A', 'deny->allow: every operand on the allow-list', '@R@ -rf build # /'),
    ('A', 'D', 'allow->deny: &> and >& are redirects, not separators', '@R@ -rf build &>/dev/null /'),
    ('A', 'D', 'allow->deny: &> and >& are redirects, not separators', '@R@ -rf build >&2 /etc'),
    ('A', 'D', 'allow->deny: .. component', '@R@ -rf build/..'),
    ('A', 'D', 'allow->deny: .. component', '@R@ -rf build/../..'),
    ('A', 'A', '', '@R@ -rf build/v1..2'),
    ('A', 'D', 'allow->deny: .git component', '@R@ -rf foo/.git'),
    ('D', 'D', '', '@R@ -rf .git'),
    ('D', 'A', 'deny->allow: every operand on the allow-list', '@R@ -rf .gitignore-cache'),
    ('A', 'D', 'allow->deny: command word is an expansion', '$x -rf /'),
    ('A', 'D', 'allow->deny: command word is an expansion', '$(which @R@) -rf /'),
    ('A', 'D', 'allow->deny: command word is an expansion', 'r${E}m -rf /'),
    ('A', 'A', '', '[ -f /etc/x -a -r /etc/y ] && echo ok'),
    ('D', 'D', '', '@R@ -rf ./a x(y) /'),
    ('D', 'D', '', '@R@ -rf ./a <(echo /)'),
    ('A', 'A', '', '@R@ -rf -- build'),
    ('D', 'D', '', '@R@ -rf build -- /'),
    ('D', 'D', '', 'xargs @R@ -rf'),
    ('D', 'D', '', 'find . -name x | xargs @R@ -rf'),
    ('D', 'D', '', '@R@ -r -f /'),
    ('A', 'A', '', '@R@ --recursive --force build'),
    ('A', 'D', 'allow->deny: abbreviated long option', '@R@ --rec --force /usr/local'),
    ('D', 'A', 'deny->allow: every operand on the allow-list', '@R@ -fr ./x'),
    ('D', 'D', '', '@R@ -rf'),
    ('A', 'A', '', 'farm -rf build /'),
    ('D', 'D', '', 'farm -rf /'),
    ('A', 'D', 'allow->deny: relative operand after cd to a target that is not safe', 'cd /etc && @R@ -rf x'),
    ('A', 'A', '', 'cd frontend && @R@ -rf node_modules'),
    ('A', 'A', '', 'cd ./build && @R@ -rf tmp'),
    ('A', 'A', '', 'cd /tmp/work && @R@ -rf out'),
    ('A', 'D', 'allow->deny: relative operand after cd to a target that is not safe', 'cd ~ && @R@ -rf x'),
    ('A', 'D', 'allow->deny: relative operand after cd to a target that is not safe', 'cd $DIR && @R@ -rf x'),
    ('A', 'D', 'allow->deny: relative operand after cd to a target that is not safe', 'cd - && @R@ -rf x'),
    ('A', 'D', 'allow->deny: relative operand after cd to a target that is not safe', 'cd .. && @R@ -rf x'),
    ('A', 'D', 'allow->deny: relative operand after cd to a target that is not safe', 'cd && @R@ -rf x'),
    ('A', 'D', 'allow->deny: relative operand after cd to a target that is not safe', 'pushd /var && @R@ -rf x'),
    ('D', 'A', 'deny->allow: every operand on the allow-list', 'cd /etc && @R@ -rf /tmp/x'),
    ('D', 'D', '', '@R@ -rf build { /'),
    ('A', 'A', '', '@R@ -rf build } x'),
    ('A', 'A', '', '@R@ -rf x\\;/'),
    ('A', 'D', 'allow->deny: escaped separator', '@R@ -rf a\\; /'),
    ('A', 'D', 'allow->deny: escaped separator', '@R@ -rf build\\& /'),
    ('A', 'D', 'allow->deny: escaped separator', '@R@ -rf build\\| /'),
    ('A', 'D', 'allow->deny: fd close/dup or clobber redirect', '@R@ -rf build >&- /'),
    ('A', 'A', '', '@R@ -rf build 2>&- x'),
    ('A', 'D', 'allow->deny: fd close/dup or clobber redirect', '@R@ -rf build <&0 /'),
    ('A', 'D', 'allow->deny: fd close/dup or clobber redirect', '@R@ -rf build >|x /'),
    ('A', 'D', 'allow->deny: fd close/dup or clobber redirect', '@R@ -rf build &>- /'),
    ('D', 'D', '', '@R@ -rf ./build >&-'),
    ('A', 'D', 'allow->deny: backslash-newline joins the operand', '@R@ -rf build \\<LF>/'),
    ('D', 'D', '', '@R@ -rf \\<LF>/tmp/x'),
    ('A', 'A', '', '@R@ -rf build\\<LF>/'),
    ('D', 'D', '', "bash -c '@R@ -rf /'"),
    ('A', 'A', '', 'bash -c "@R@ -rf build"'),
    ('A', 'D', 'allow->deny: relative operand after cd to a target that is not safe', 'sh -c "cd /etc; @R@ -rf x"'),
    ('A', 'A', '', '@R@ -rf "my dir"'),
    ('A', 'A', '', "@R@ -rf 'my\\ build'"),
    ('D', 'D', '', '"@R@" -rf /'),
    ('D', 'D', '', 'r\\m -rf /'),
    ('D', 'D', '', 'sudo @R@ -rf /var/lib/x'),
    ('A', 'A', '', '@R@ -rf node_modules/.cache'),
    ('D', 'A', 'deny->allow: every operand on the allow-list', '@R@ -rf ./node_modules/.cache'),
    ('A', 'D', 'allow->deny: operand is a command substitution', '@R@ -rf build $(echo x)'),
    ('D', 'D', '', '@R@ -rf ./build/$(date +%s)'),
    ('D', 'A', 'deny->allow: every operand on the allow-list', '@R@ -rf build; @R@ -rf /tmp/y'),
    ('D', 'D', '', 'for d in a b; do @R@ -rf "$d"; done'),
    ('D', 'D', '', '@R@ -rf "$1"'),
    ('A', 'A', '', '@R@ -rf build/'),
    ('D', 'D', '', '@R@ -rf ./'),
    ('D', 'D', '', '@R@ -rf /tmp'),
    ('D', 'D', '', '@R@ -rf /tmp/../etc'),
    ('A', 'D', 'allow->deny: relative operand after cd to a target that is not safe', '( cd /etc && @R@ -rf x )'),
    ('A', 'A', '', '@R@ -rf x\\'),
    ('A', 'A', '', '@R@ -rfv build'),
    ('A', 'A', '', '@R@ -Rf build'),
    ('A', 'A', '', '@R@ -rf build <<EOF<LF>x<LF>EOF'),
    ('A', 'A', '', '$RM -rf build'),
    ('A', 'D', 'allow->deny: command word is an expansion', '$RM -rf "$OUT"'),
    ('A', 'A', '', 'echo @R@ -rf /'),
    ('A', 'A', '', 'grep -r "@R@ -rf /" .'),
    ('D', 'A', 'deny->allow: every operand on the allow-list', '@R@ -rf ./build ./dist'),
    ('D', 'D', '', '@R@ -rf build ./dist /etc'),
    ('D', 'D', '', '@R@ -rf "" /'),
    ('D', 'D', '', "@R@ -rf build $'\\x2f'"),
]

def decide(cmd):
    p = {"tool_name": "Bash", "session_id": "rm-table", "tool_input": {"command": cmd}}
    env = {"PATH": os.environ["PATH"], "HOME": os.environ.get("HOME", "/nonexistent"), "LC_ALL": "C.UTF-8"}
    r = subprocess.run(["bash", gate], input=json.dumps(p), capture_output=True, text=True, cwd=tmp, env=env)
    return {0: "A", 2: "D"}.get(r.returncode, "E%d" % r.returncode), r.stderr.strip().split("\n")[0]

fails = 0
if len(ROWS) < 60:
    print("FAIL: the table must hold at least 60 shapes, has %d" % len(ROWS)); fails += 1
for head, now, why, shape in ROWS:
    if (head != now) != bool(why):
        print("FAIL: row %r: 9.4.2=%s now=%s needs a reason exactly when they differ" % (shape, head, now)); fails += 1
        continue
    if why and not why.startswith("allow->deny" if head == "A" else "deny->allow"):
        print("FAIL: row %r: reason %r does not match %s->%s" % (shape, why, head, now)); fails += 1
    got, first = decide(shape.replace("@R@", R).replace("<LF>", "\n"))
    if got != now:
        print("FAIL: %s expected %s, got %s :: %s" % (shape, now, got, first[:120])); fails += 1
changed = sum(1 for h, n, w, s in ROWS if h != n)
if fails:
    print("test-security-gate-rm-table: %d failure(s)" % fails)
    sys.exit(1)
print("test-security-gate-rm-table: PASS (%d shapes, %d intended differences from 9.4.2)" % (len(ROWS), changed))
PY
