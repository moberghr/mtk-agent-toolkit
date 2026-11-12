#!/usr/bin/env bash
set -euo pipefail

# security-gate.sh must judge a long command, and judge it in linear time.
# A 2026-10-22 field run had 58 timeouts in 24h, every one a 2–15k-char heredoc
# file write. The cause was the "anything left after stripping?" test
# `[ -n "${NORM//[[:space:]]/}" ]`: on macOS bash 3.2 that substitution is
# super-linear (159s on an 8k command in a UTF-8 locale), and a timed-out hook
# never judged the command at all. A 2026-11-11 review found the same class in
# the segment judges: a single 32 KB segment of `time `, `{ `, `a=1 ` or
# `! nohup ` prefixes cost 2.5–25 s of CPU, one copy of the rest per word.
#
# These cases pin that a long command is still judged (denied with the right
# reason when its tail is destructive, allowed otherwise). They do not assert
# wall-clock bounds: on a loaded host those are flaky. A perl alarm watchdog
# (MTK_TEST_GATE_WATCHDOG, default 60 s) only stops a hang from stalling the
# suite; measure CPU time (user+sys) when tuning the gate.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="${MTK_TEST_GATE:-$REPO_ROOT/hooks/security-gate.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
WATCHDOG="${MTK_TEST_GATE_WATCHDOG:-60}"

# Writes a Bash payload whose command is a ~15k-char heredoc write followed by $1.
make_payload() {
  python3 - "$1" "$TMP/payload.json" <<'PY'
import json, sys
tail, out = sys.argv[1], sys.argv[2]
body = "\n".join("    public void Method%d() { var x = \"value %d\"; Assert.Equal(x, Compute(%d)); }" % (i, i, i) for i in range(180))
cmd = "cd /tmp/x && cat > src/Foo.cs <<'EOF'\n" + body + "\nEOF" + tail
json.dump({"tool_name": "Bash", "tool_input": {"command": cmd}}, open(out, "w"))
PY
}

# Writes a payload of shape $1 with size $2 (see the kinds below).
make_shaped() {
  python3 - "$1" "$2" "$TMP/payload.json" <<'PY'
import json, sys
kind, n, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
RM = "r" + "m"
if kind == "heredoc":      # n lines of C#-like code written to a file
    cmd = "cat > src/Foo.cs <<'EOF'\n" + "\n".join("    public int M%d() { return %d; }" % (i, i) for i in range(n)) + "\nEOF"
elif kind == "subst":      # n segments, each with a command substitution
    cmd = "; ".join("echo $(date)" for _ in range(n))
elif kind == "onesubst":   # one segment holding n command substitutions
    cmd = "echo " + "$(a)" * n
elif kind == "onebt":      # one segment holding n backtick substitutions
    cmd = "echo " + "`a`" * n
elif kind == "segments":   # n plain segments
    cmd = ";".join("true" for _ in range(n))
elif kind.startswith("shc-"):
    # n shell -c segments of one shape, optionally with a destructive tail.
    shape, tail = kind[4:].split(":")
    seg = {"x": "bash -c x", "echo": "bash -c 'echo hi'", "two": 'bash -c "a; b"',
           "sh": "sh -c x", "lc": "bash -lc x"}[shape]
    cmd = ";".join(seg for _ in range(n)) + {"": "", "rf": "; " + RM + " -" + "rf /"}[tail]
elif kind.startswith("nest-"):
    # n shells, each the -c text of the one before: bash -c bash -c … <tail>
    tail = {"rf": RM + " -" + "rf /", "ls": "ls"}[kind[5:]]
    cmd = "bash -c " * n + tail
elif kind == "chain-c":    # one segment of n `bash -c ` words
    cmd = "bash -c " * n
elif kind.startswith("md"):
    # A markdown file written through a heredoc: n lines of 5 code spans and
    # a 40-row table. md-q: quoted delimiter; md-uq: unquoted, fed to bash
    # with one destructive line; md-qbash: quoted, fed to bash, same line.
    B = "`"
    lines = [" ".join("use " + B + "cmd%d_%d --x" % (i, k) + B for k in range(5)) for i in range(n)]
    lines += ["| a | b | c | d |", "|---|---|---|---|"] + ["| " + B + "x%d" % i + B + " | y | z | w |" for i in range(40)]
    if kind == "md-q":
        cmd = "cat > docs/guide.md <<'EOF'\n# Guide\n\n" + "\n".join(lines) + "\nEOF"
    else:
        opener = "bash <<EOF\n" if kind == "md-uq" else "bash <<'EOF'\n"
        cmd = opener + "\n".join(lines[:20]) + "\n" + RM + " -" + "rf /\nEOF"
elif kind == "deadline":   # n substitutions in one segment, over every default cap
    cmd = "echo " + "$(a)" * n
elif kind == "prbody":     # a PR body with n markdown code spans, fed on stdin
    cmd = "gh pr create --title x --body-file - <<'EOF'\n" + "\n".join("- `item%d` uses `$(x)`" % i for i in range(n)) + "\nEOF"
elif kind == "commitmsg":  # a git commit -m of about n bytes
    cmd = 'git commit -m "' + ("word " * (n // 5)) + '"'
elif kind.startswith("chain-"):
    # One segment: prefix words repeated to about n bytes, then a tail. The
    # prefix is one the segment judges peel before the command word.
    shape, tail = kind[6:].split(":")
    prefix = {"time": "time ", "brace": "{ ", "assign": "a=1 ", "bangnohup": "! nohup ",
              "xargs": "xargs -0 "}[shape]
    tail = {"rf": RM + " -" + "rf /", "fr": RM + " -" + "fr /", "xrm": RM + " -" + "rf", "ls": "ls"}[tail]
    count = (n - len(tail)) // len(prefix) if n > 1000 else n
    cmd = prefix * count + tail
json.dump({"tool_name": "Bash", "tool_input": {"command": cmd}}, open(out, "w"))
PY
}

# Runs the gate on the payload under the watchdog; sets RC and ERR (stderr).
run_gate() {
  RC=0
  env "$@" LC_ALL=C.UTF-8 LANG=C.UTF-8 perl -e 'alarm shift; exec @ARGV or die' "$WATCHDOG" bash "$GATE" \
    < "$TMP/payload.json" >/dev/null 2>"$TMP/err" || RC=$?
  ERR="$(cat "$TMP/err")"
}

expect_deny() { # $1 label, $2 text the first stderr line must contain
  local first
  first="$(awk 'NR == 1' "$TMP/err")"
  [ "$RC" -eq 2 ] || { echo "FAIL: $1 — expected exit 2, got $RC: $first" >&2; fails=$((fails + 1)); return 0; }
  case "$first" in
    BLOCKED*"$2"*) ;;
    *) echo "FAIL: $1 — deny reason is not '$2': $first" >&2; fails=$((fails + 1)) ;;
  esac
}
expect_cap() { expect_deny "$1" 'too long'; }
expect_allow() { # $1 label
  [ "$RC" -eq 0 ] || { echo "FAIL: $1 — expected exit 0, got $RC: $ERR" >&2; fails=$((fails + 1)); }
}

# 1. A long, harmless heredoc write is allowed.
make_payload ""; run_gate; expect_allow "long heredoc write"

# 2. The same long command with a destructive tail is still denied.
make_payload " && rm -rf /"; run_gate; expect_deny "long command + rm -rf /" 'Recursive force-delete'

# 3–9. The early size cap. Judging grows with length, so a big enough command
# outlives the hook timeout, which the harness treats as non-blocking: the
# command would run unjudged. Over the cap the gate denies at once.
# 3. Over the byte cap (a ~50 KB heredoc write), and far over it (~175 KB):
#    extracting the command from the payload is itself quadratic, so the raw
#    payload is capped before extraction.
make_shaped heredoc 1500; run_gate; expect_cap "heredoc over the byte cap"
make_shaped heredoc 5000; run_gate; expect_cap "175 KB heredoc (payload cap)"
# 4. Over the substitution-segment cap (default 1024).
make_shaped subst 1025; run_gate; expect_cap "1025 substitution segments"
make_shaped subst 2000; run_gate; expect_cap "2000 substitution segments"
#    Every substitution body is judged, so the total is capped too (4 per
#    allowed segment, 4096 by default), even when one segment holds them all.
make_shaped onesubst 4097; run_gate; expect_cap "4097 substitutions in one segment"
make_shaped onesubst 4000; run_gate; expect_allow "4000 substitutions in one segment"
make_shaped onebt 4097; run_gate; expect_cap "4097 backtick substitutions in one segment"
make_shaped onebt 4000; run_gate; expect_allow "4000 backtick substitutions in one segment"
# 5. Over the segment cap.
make_shaped segments 3000; run_gate; expect_cap "3000 plain segments"
# 6. The caps are tunable, and a non-numeric value keeps the default.
make_shaped subst 6
run_gate MTK_SECURITY_GATE_MAX_SUBST=5; expect_cap "MTK_SECURITY_GATE_MAX_SUBST=5, 6 substitutions"
run_gate; expect_allow "6 substitutions under the default cap"
run_gate MTK_SECURITY_GATE_MAX_SUBST=abc; expect_allow "non-numeric MTK_SECURITY_GATE_MAX_SUBST keeps the default"
make_shaped heredoc 200
run_gate MTK_SECURITY_GATE_MAX_BYTES=1000; expect_cap "MTK_SECURITY_GATE_MAX_BYTES=1000"
make_shaped segments 50
run_gate MTK_SECURITY_GATE_MAX_SEGMENTS=40; expect_cap "MTK_SECURITY_GATE_MAX_SEGMENTS=40"
# 7. Ordinary long commands stay allowed: a 200-line heredoc file write, a long
#    commit message, and a PR body whose code spans are message text.
make_shaped heredoc 200; run_gate; expect_allow "200-line heredoc file write"
make_shaped commitmsg 20000; run_gate; expect_allow "20 KB git commit -m"
make_shaped prbody 300; run_gate; expect_allow "PR body with 300 code-span lines"
# 8. Just under the caps the gate still judges.
make_shaped subst 1000; run_gate; expect_allow "1000 substitution segments"
make_shaped segments 2400; run_gate; expect_allow "2400 plain segments"

# 11. Shell -c text is judged as its own command. Each costs a judge pass (a
#     splitter process when the text holds a separator), so their number is
#     capped (MTK_SECURITY_GATE_MAX_SHELL_C, default 128) and so is nesting
#     (8 shells deep). Under the caps a destructive tail is denied for what it
#     is; over them the command is denied as too long / too complex.
make_shaped "shc-x:" 129; run_gate; expect_cap "129 x bash -c x"
make_shaped "shc-x:rf" 2400; run_gate; expect_cap "2400 x bash -c x + delete"
make_shaped "shc-sh:" 2400; run_gate; expect_cap "2400 x sh -c x"
make_shaped "shc-lc:" 1500; run_gate; expect_cap "1500 x bash -lc x"
make_shaped "shc-two:" 1200; run_gate; expect_cap "1200 x bash -c \"a; b\""
make_shaped "shc-x:" 127; run_gate; expect_allow "127 x bash -c x"
make_shaped "shc-x:rf" 127; run_gate; expect_deny "127 x bash -c x + delete" 'Recursive force-delete'
make_shaped "shc-echo:" 127; run_gate; expect_allow "127 x bash -c 'echo hi'"
make_shaped "shc-two:rf" 120; run_gate; expect_deny "120 x bash -c \"a; b\" + delete" 'Recursive force-delete'
make_shaped "shc-two:" 120; run_gate; expect_allow "120 x bash -c \"a; b\""
make_shaped chain-c 4094; run_gate; expect_cap "one segment of 4094 bash -c"
make_shaped nest-rf 8; run_gate; expect_deny "delete 8 shells deep" 'Recursive force-delete'
make_shaped nest-rf 9; run_gate; expect_deny "delete 9 shells deep" 'too complex'
make_shaped nest-ls 9; run_gate; expect_deny "ls 9 shells deep" 'too complex'
make_shaped "shc-x:" 6
run_gate MTK_SECURITY_GATE_MAX_SHELL_C=5; expect_cap "MTK_SECURITY_GATE_MAX_SHELL_C=5, 6 shell -c"

# 12. The self-deadline (MTK_SECURITY_GATE_DEADLINE_SECS, default 3): a command
#     admitted by the caps that still takes longer to judge is denied, never
#     allowed — the harness treats a hook past its 5 s timeout as allowing.
#     Here the caps are lifted so ~30000 substitutions (~7 s of judging) get in.
make_shaped deadline 30000
run_gate MTK_SECURITY_GATE_MAX_BYTES=200000 MTK_SECURITY_GATE_MAX_SUBST=100000 MTK_SECURITY_GATE_DEADLINE_SECS=1
expect_deny "judging past the deadline" 'too complex'

# 13. Markdown written through a quoted heredoc: its code spans are not shell
#     substitutions and do not count against the substitution-segment cap.
#     The body is still judged, so a heredoc fed to a shell keeps its deletes.
make_shaped md-q 300; run_gate; expect_allow "300-line markdown heredoc, 1500 code spans, 40-row table"
make_shaped md-uq 20; run_gate; expect_deny "unquoted heredoc fed to bash with a delete" 'Recursive force-delete'
make_shaped md-qbash 20; run_gate; expect_deny "quoted heredoc fed to bash with a delete" 'Recursive force-delete'
make_shaped md-q 700; run_gate; expect_cap "markdown heredoc over the byte cap"

# 9. One segment of peelable prefixes at the byte cap (32 KB), destructive tail:
#    judged (the peel stops at MTK_GATE_MAX_PREFIX and the whole segment is
#    judged), with the delete's own reason, not a timeout or a size cap.
for shape in time brace assign bangnohup; do
  make_shaped "chain-$shape:rf" 32700; run_gate; expect_deny "32 KB $shape chain + delete" 'Recursive force-delete'
  make_shaped "chain-$shape:fr" 32700; run_gate; expect_deny "32 KB $shape chain + -fr delete" 'Recursive force-delete'
  make_shaped "chain-$shape:ls" 32700; run_gate; expect_allow "32 KB $shape chain + ls"
done
make_shaped "chain-xargs:xrm" 32700; run_gate; expect_deny "32 KB xargs -0 chain + delete" 'xargs'
# 10. Just under the peel bound (127 prefixes): peeled to the delete.
for shape in time assign; do
  make_shaped "chain-$shape:rf" 127; run_gate; expect_deny "127 $shape prefixes + delete" 'Recursive force-delete'
done

if [ "$fails" -gt 0 ]; then
  echo "test-security-gate-long-command: $fails failure(s)" >&2
  exit 1
fi
echo "test-security-gate-long-command: PASS"
