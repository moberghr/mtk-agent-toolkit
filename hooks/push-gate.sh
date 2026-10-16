#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on unexpected non-zero exit (silent on
# success and on an intentional deny, exit 2).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 && $c -ne 2 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# PreToolUse guard for Bash `git push`: is the pushed change covered by a review
# receipt (scripts/review-receipt.sh)? Exit 0 = allow, exit 2 = block.
#
# Registered with `"if": "Bash(git push *)"`, but the command text is re-checked
# here too (defence in depth for a harness that ignores `if`): the command is
# split into segments on ; && || | & ( ) and newlines, and only a segment whose
# command word is `git` (after VAR=value / env / command / exec / time / nohup)
# with subcommand `push` counts. `echo git push`, `grep "git push" .` and a
# quoted "git push" are not invocations and pass silently. `bash -c "git push"`
# is not seen either — this is a drift guard, not a sandbox. A heredoc body line
# that reads `git push …` is a known false positive (one advisory, never a deny
# outside active mode).
#
# No refspec parsing beyond mapping the push to the current branch. Checked:
#   git push · git push <remote> · git push -u <remote> <current-branch>
#   git push <remote> HEAD · git push <remote> HEAD:<current-branch>
# Not mapped (one "push target not mapped — receipt not checked" line, allowed):
#   a refspec naming another branch (HEAD:other, other), several refspecs,
#   --all/--branches/--mirror/--tags/--delete/--prune, git -C <dir> /
#   --git-dir / --work-tree, a cd/pushd earlier in the command, several pushes in
#   one command, an option this hook does not know, a detached HEAD.
# Force pushes are security-gate.sh's job and are not looked at here.
#
# Mode: MTK_PUSH_GATE_ENFORCE=off|advisory|shadow|active (default advisory),
# read through mtk_guard_mode (hooks/lib/guard-mode.sh). Not covered ⇒
#   advisory  additionalContext naming the uncovered commits, once per change
#             id per session (mtk_advise_gated)
#   shadow    the same advisory, plus one enforcement-shadow.jsonl line
#   active    deny, code PUSH-UNREVIEWED
# The hook writes no state of its own; receipts live under ~/.mtk/receipts/ and
# are written only by a qualifying review (see scripts/review-receipt.sh). The
# advisory and deny text never print the receipt-write command: a receipt is the
# review's output, not something to create in order to push.
#
# Fails OPEN: empty/unparseable payload, python3 or review-receipt.sh absent, or
# a receipt check that errors (not a repo, no base) — the last one with a
# one-line note so the unchecked push is visible.
#
# Kill-switch: MTK_PUSH_GATE=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/guard-mode.sh"

[ "${MTK_PUSH_GATE:-1}" = "0" ] && exit 0
mtk_hook_seen push-gate.sh

INPUT="$(mtk_read_payload)"
[ -n "$INPUT" ] || exit 0

TOOL_NAME="$(mtk_extract_tool_name "$INPUT" 2>/dev/null || echo "")"
case "$TOOL_NAME" in
  Bash|"") ;;
  *) exit 0 ;;
esac

CMD="$(mtk_extract_command "$INPUT" 2>/dev/null || echo "")"
[ -n "$CMD" ] || exit 0
# Cheap prefilter (no fork) before any python or git: no "push", no push.
case "$CMD" in
  *push*) ;;
  *) exit 0 ;;
esac

MODE="$(mtk_guard_mode PUSH_GATE advisory)"
[ "$MODE" = "off" ] && exit 0

command -v python3 >/dev/null 2>&1 || exit 0

# Run git in the directory the Bash call runs in, when the payload names one.
CWD="$(mtk_extract_json_string "$INPUT" "cwd" 2>/dev/null || echo "")"
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  cd "$CWD" 2>/dev/null || exit 0
fi

BRANCH="$(git symbolic-ref -q --short HEAD 2>/dev/null || echo "")"

# Classify: none (no git push invocation) | check | unmapped.
VERDICT="$(python3 -I -c '
import re, shlex, sys

cmd = sys.stdin.read()
branch = sys.argv[1]

PUNCT = ";&|<>()\n"
try:
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=PUNCT)
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    tokens = list(lex)
except ValueError:
    print("none")
    sys.exit(0)

# shlex groups a run of punctuation into one token: one holding < or > is a
# redirection (dropped with its target and a bare fd number before it); any
# other run (; && || | & ( ) newline) ends the segment.
segments, cur, i = [], [], 0
while i < len(tokens):
    t = tokens[i]
    if t and all(c in PUNCT for c in t):
        if "<" in t or ">" in t:
            if cur and cur[-1].isdigit():
                cur.pop()
            i += 1
        else:
            if cur:
                segments.append(cur)
            cur = []
    else:
        cur.append(t)
    i += 1
if cur:
    segments.append(cur)

ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
WRAPPERS = {"command", "exec", "time", "nohup", "env"}
GIT_ARG_OPTS = {"-c", "--config-env", "--namespace"}
GIT_ELSEWHERE = {"-C", "--git-dir", "--work-tree"}


def strip_prefix(seg):
    """Drop leading VAR=value words, wrapper commands and env options."""
    j = 0
    while j < len(seg):
        w = seg[j]
        if ASSIGN.match(w) or w in WRAPPERS:
            j += 1
        elif j > 0 and seg[j - 1] == "env" and w.startswith("-"):
            j += 1
        else:
            break
    return seg[j:]


pushes, moved = [], False
for seg in segments:
    seg = strip_prefix(seg)
    if not seg:
        continue
    if seg[0] in ("cd", "pushd", "popd"):
        moved = True
        continue
    if not (seg[0] == "git" or seg[0].endswith("/git")):
        continue
    j, here = 1, True
    while j < len(seg) and seg[j].startswith("-"):
        o = seg[j]
        name = o.split("=", 1)[0]
        if name in GIT_ELSEWHERE:
            here = False
            j += 1 if "=" in o else 2
        elif name in GIT_ARG_OPTS:
            j += 1 if "=" in o else 2
        else:
            j += 1
    if j < len(seg) and seg[j] == "push":
        pushes.append((seg[j + 1:], here and not moved))

if not pushes:
    print("none")
    sys.exit(0)
if len(pushes) > 1:
    print("unmapped")
    sys.exit(0)

args, here = pushes[0]
if not here or not branch:
    print("unmapped")
    sys.exit(0)

FLAGS = {"-u", "--set-upstream", "-v", "--verbose", "-q", "--quiet", "--progress",
         "--no-progress", "--no-verify", "--verify", "-f", "--force", "--atomic",
         "--no-atomic", "--porcelain", "-n", "--dry-run", "--follow-tags",
         "--no-follow-tags", "--thin", "--no-thin", "-4", "--ipv4", "-6", "--ipv6",
         "--signed", "--no-signed", "--force-if-includes", "--no-force-if-includes",
         "--no-recurse-submodules"}
EQ_FLAGS = {"--force-with-lease", "--signed", "--recurse-submodules", "--receive-pack",
            "--exec", "--push-option", "--repo"}
ARG_FLAGS = {"-o", "--push-option", "--receive-pack", "--exec", "--repo",
             "--recurse-submodules"}

pos, k = [], 0
while k < len(args):
    a = args[k]
    if a == "--":
        pos.extend(args[k + 1:])
        break
    if a.startswith("-") and a != "-":
        name = a.split("=", 1)[0]
        if a in FLAGS or a == "--force-with-lease":
            k += 1
            continue
        if "=" in a and name in EQ_FLAGS:
            k += 1
            continue
        if a in ARG_FLAGS:
            k += 2
            continue
        print("unmapped")
        sys.exit(0)
    pos.append(a)
    k += 1

refspecs = pos[1:]
if not refspecs:
    print("check")
    sys.exit(0)
if len(refspecs) > 1:
    print("unmapped")
    sys.exit(0)

mine = {branch, "refs/heads/" + branch}
r = refspecs[0].lstrip("+")
if ":" in r:
    src, dst = r.split(":", 1)
    ok = src in (mine | {"HEAD"}) and dst in mine
else:
    ok = r in (mine | {"HEAD"})
print("check" if ok else "unmapped")
' "$BRANCH" <<<"$CMD" 2>/dev/null)" || exit 0

case "$VERDICT" in
  check) ;;
  unmapped)
    mtk_emit_additional_context PreToolUse \
      "MTK push gate: push target not mapped — receipt not checked."
    exit 0
    ;;
  *) exit 0 ;;
esac

# review-receipt.sh: this checkout first, then the installed plugin; absent ⇒ fail open.
RECEIPT=""
for cand in "$SCRIPT_DIR/../scripts/review-receipt.sh" "${CLAUDE_PLUGIN_ROOT:-}/scripts/review-receipt.sh"; do
  case "$cand" in /scripts/*) continue ;; esac
  if [ -f "$cand" ]; then RECEIPT="$cand"; break; fi
done
if [ -z "$RECEIPT" ]; then
  printf '[mtk] push-gate: scripts/review-receipt.sh not found; push not checked\n' >&2 || true
  exit 0
fi

# stderr folded into OUT: on exit 1 the script writes nothing to stderr, and on
# exit 2 its stderr is the one-line reason the note below repeats.
RC=0
OUT="$(bash "$RECEIPT" check 2>&1)" || RC=$?

case "$RC" in
  0) exit 0 ;;
  1) ;;
  *)
    ERR="${OUT##*$'\n'}"
    ERR="${ERR#review-receipt: }"
    ERR="${ERR:0:200}"
    mtk_emit_additional_context PreToolUse \
      "MTK push gate: receipt not checked (${ERR:-review-receipt.sh exit $RC})."
    exit 0
    ;;
esac

# First line: "receipt: missing change_id=<id> range=<mb>..<head> commits=<n>".
FIRST="${OUT%%$'\n'*}"
COMMITS=""
case "$OUT" in *$'\n'*) COMMITS="${OUT#*$'\n'}" ;; esac
CHANGE_ID="${FIRST#*change_id=}"; CHANGE_ID="${CHANGE_ID%% *}"
RANGE="${FIRST#*range=}"; RANGE="${RANGE%% *}"
NCOMMITS="${FIRST#*commits=}"; NCOMMITS="${NCOMMITS%% *}"
case "$CHANGE_ID" in ''|*[!0-9a-f]*) CHANGE_ID="" ;; esac

HOW="Get a receipt by running the full review on this branch — implement Phase 4, or code-review-and-quality with every lane — which records one when all lanes PASS. pre-commit-review does not count."
TEXT="MTK push gate: no review receipt covers ${RANGE} (${NCOMMITS} commit(s) not covered by a PASS review):
${COMMITS}
${HOW}"
REASON="Push blocked (PUSH-UNREVIEWED ${RANGE}): no review receipt covers the ${NCOMMITS} commit(s) this push would publish:
${COMMITS}
${HOW} If the user wants this push to go ahead without a review, ask them."

mtk_session_bind "$INPUT"
mtk_deny_gated "$MODE" push-gate PUSH-UNREVIEWED "$REASON" \
  "unset MTK_PUSH_GATE_ENFORCE (falls back to advisory)" "$RANGE"
mtk_advise_gated "$MODE" PreToolUse "push-gate:${CHANGE_ID:-$RANGE}" "$TEXT" || true
exit 0
