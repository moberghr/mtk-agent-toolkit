#!/usr/bin/env bash
set -euo pipefail

# hooks/hooks.json is the only hook registration (S3.6). This pins the runtime
# diet: no hook on the read path (Read/Grep/Glob), on MCP calls or on
# UserPromptSubmit, no PreCompact snapshot, one SessionStart entry that also
# covers compaction, every registered command resolves to an executable
# script in hooks/, and every such script stamps its liveness as
# `mtk_hook_seen <its file name>` — written down (static) and actually reached
# when the hook is driven with a minimal payload (runtime), each with negative
# controls. The cut hooks must stay cut.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HJ="$REPO_ROOT/hooks/hooks.json"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available" >&2; exit 0; }

python3 - "$HJ" "$REPO_ROOT" <<'PY'
import json, os, re, sys

path, root = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "hooks", "lib"))
sys.dont_write_bytecode = True  # importing must not write hooks/lib/__pycache__
from hook_registry import handlers  # the one hooks.json handler parser
hooks = json.load(open(path))["hooks"]
fails = []

def full(matcher, tool):
    try:
        return re.fullmatch(matcher, tool) is not None
    except re.error:
        return True  # an unparseable matcher is treated as matching everything

# 1. events that must not be registered at all
for ev in ("UserPromptSubmit", "PreCompact"):
    if ev in hooks:
        fails.append("%s must not be registered" % ev)

# 2. no tool hook may fire on the read path or on MCP calls
for ev in ("PreToolUse", "PostToolUse", "PostToolUseFailure"):
    for entry in hooks.get(ev, []):
        m = entry.get("matcher", "")
        if m in ("", "*"):
            fails.append("%s has a match-all matcher %r" % (ev, m))
            continue
        for tool in ("Read", "Grep", "Glob", "mcp__server__tool"):
            if full(m, tool):
                fails.append("%s matcher %r fires on %s" % (ev, m, tool))

# 3. exact expected table: (event, matcher) -> [hook basename + args]
def table():
    out = {}
    for h in handlers(path):
        out.setdefault((h["event"], h["matcher"]), []).append((h["script"] + " " + h["args"]).strip())
    return out

expected = {
    ("SessionStart", "startup|clear|compact|resume"): ["session-start"],
    ("PreToolUse", "Bash"): ["security-gate.sh", "format-on-edit.sh --flush-before-verify",
                            "push-gate.sh"],
    ("PreToolUse", "Edit|Write"): ["scope-guard.sh", "config-guard.sh"],
    ("PostToolUse", "Edit|Write|Bash"): ["evidence-ledger.sh"],
    ("PostToolUse", "Edit|Write"): ["spec-approval-trigger.sh", "format-on-edit.sh"],
    ("Stop", ""): ["verify-completion", "format-on-edit.sh --flush",
                   "workflow-continuation.sh", "cost-tracker.sh"],
    ("SubagentStart", ""): ["subagent-context.sh"],
    ("PostCompact", ""): ["compact-archive.sh"],
}
got = table()
if got != expected:
    fails.append("hook table drifted:\n  expected %r\n  got      %r" % (expected, got))

# 3b. the table reads only `command`: pin the `if` filter that keeps push-gate
# off every Bash call except `git push` (and no other handler carries one).
ifs = {h["script"]: h["if"] for h in handlers(path) if h.get("if")}
if ifs != {"push-gate.sh": "Bash(git push *)"}:
    fails.append("`if` filters drifted: expected only push-gate.sh with Bash(git push *), got %r" % (ifs,))

# 4. every registered script exists and is executable
for (ev, m), names in got.items():
    for n in names:
        script = os.path.join(root, "hooks", n.split()[0])
        if not os.path.isfile(script):
            fails.append("%s/%s: %s does not exist" % (ev, m, script))
        elif not os.access(script, os.X_OK):
            fails.append("%s/%s: %s is not executable" % (ev, m, script))

# 5. the async Stop recorders stay async
for h in handlers(path):
    if h["event"] == "Stop" and h["script"] in ("cost-tracker.sh", "workflow-continuation.sh") and not h["async"]:
        fails.append("%s must be async" % h["script"])

if fails:
    for f in fails:
        print("FAIL: " + f, file=sys.stderr)
    sys.exit(1)
print("  PASS  hooks.json matches the runtime-diet table")
PY

# 5b. every registered hook script stamps its liveness under its own file name
# (`mtk_hook_seen <basename>` on a non-comment line) — mtk-doctor derives the
# liveness set from hooks.json and looks for exactly that stamp name.
# stamp_check <root>: exit 0 when every script registered in <root>/hooks/hooks.json
# has the call, else prints one FAIL line per script and exits 1.
stamp_check() {
  python3 - "$1" "$REPO_ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
sys.path.insert(0, os.path.join(sys.argv[2], "hooks", "lib"))  # the real parser, even for a temp copy
sys.dont_write_bytecode = True  # importing must not write hooks/lib/__pycache__
from hook_registry import handlers
names = list(dict.fromkeys(h["script"] for h in handlers(os.path.join(root, "hooks", "hooks.json"))))
bad = []
for n in names:
    try:
        lines = open(os.path.join(root, "hooks", n)).read().splitlines()
    except OSError as e:
        bad.append("%s: cannot read (%s)" % (n, e))
        continue
    call = re.compile(r"(^|[\s;&|(])mtk_hook_seen\s+[\"']?" + re.escape(n) + r"[\"']?(\s|;|$)")
    if not any(call.search(l) for l in lines if not l.lstrip().startswith("#")):
        bad.append("hooks/%s has no `mtk_hook_seen %s` call" % (n, n))
for b in bad:
    print("FAIL: " + b, file=sys.stderr)
if bad:
    sys.exit(1)
print("  PASS  all %d registered hook scripts call mtk_hook_seen <their file name>" % len(names))
PY
}
stamp_check "$REPO_ROOT" || exit 1

# Negative controls on a temp copy: deleting or commenting out one stamp line
# must make the same check fail and name that hook.
WIRING_TMP="$(mktemp -d)"
trap 'rm -rf "$WIRING_TMP"' EXIT
mkdir -p "$WIRING_TMP/del/hooks" "$WIRING_TMP/cmt/hooks"
for f in "$REPO_ROOT"/hooks/*; do
  if [ -f "$f" ]; then cp "$f" "$WIRING_TMP/del/hooks/"; cp "$f" "$WIRING_TMP/cmt/hooks/"; fi
done
sed '/mtk_hook_seen scope-guard\.sh/d' "$REPO_ROOT/hooks/scope-guard.sh" >"$WIRING_TMP/del/hooks/scope-guard.sh"
sed 's/^\(.*mtk_hook_seen session-start\)/# \1/' "$REPO_ROOT/hooks/session-start" >"$WIRING_TMP/cmt/hooks/session-start"
neg_check() { # $1 label  $2 copy root  $3 hook expected in the FAIL line
  local rc=0 err
  err="$(stamp_check "$2" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -eq 1 ] && [ "${err#*"hooks/$3 has no"}" != "$err" ]; then
    printf '  PASS  negative control: %s → stamp check fails naming %s\n' "$1" "$3"
  else
    printf 'FAIL: negative control %s: expected exit 1 naming %s, got rc=%s: %s\n' "$1" "$3" "$rc" "$err" >&2
    exit 1
  fi
}
neg_check "scope-guard.sh stamp line deleted" "$WIRING_TMP/del" scope-guard.sh
neg_check "session-start stamp line commented out" "$WIRING_TMP/cmt" session-start

# 5c. runtime: the static check above only proves the call is written down.
# Drive every registered hook command once, with a minimal payload for the event
# it is registered on, and assert its stamp exists in the directory the doctor
# reads (always computed through mtk_hook_seen_dir, never spelled out). Sandbox
# project + HOME; each command gets its own fresh TMPDIR outside the project
# root (a TMPDIR inside the root disables stamping by design), so a stamp can
# only come from that one run. env -i keeps the session's MTK_* kill-switches out.
RT_PROJ="$WIRING_TMP/rt-proj"
mkdir -p "$RT_PROJ" "$WIRING_TMP/rt-home"
git -C "$RT_PROJ" init -q >/dev/null 2>&1 || true

# drive_plan <root>: one line per registered command —
# event|first tool of its matcher|script name|args (`|` is not IFS whitespace,
# so an empty matcher or args field is kept, not collapsed)
drive_plan() {
  python3 - "$1" "$REPO_ROOT" <<'PY'
import os, sys
root = sys.argv[1]
sys.path.insert(0, os.path.join(sys.argv[2], "hooks", "lib"))  # the real parser, even for a temp copy
sys.dont_write_bytecode = True  # importing must not write hooks/lib/__pycache__
from hook_registry import handlers
for h in handlers(os.path.join(root, "hooks", "hooks.json")):
    print("|".join([h["event"], h["matcher"].split("|")[0], h["script"], h["args"]]))
PY
}

# rt_payload <event> <tool>: the smallest payload of that event's shape.
rt_payload() {
  local base="\"session_id\":\"wiring-rt\",\"cwd\":\"$RT_PROJ\",\"hook_event_name\":\"$1\""
  case "$1:$2" in
    SessionStart:*) printf '{%s,"source":"startup"}' "$base" ;;
    *ToolUse:Bash)  printf '{%s,"tool_name":"Bash","tool_input":{"command":"ls"}}' "$base" ;;
    *ToolUse:*)     printf '{%s,"tool_name":"%s","tool_input":{"file_path":"%s/notes.txt","content":"x"}}' "$base" "$2" "$RT_PROJ" ;;
    Stop:*)         printf '{%s,"stop_hook_active":false}' "$base" ;;
    SubagentStart:*) printf '{%s,"agent_id":"agent-0","agent_type":"general-purpose"}' "$base" ;;
    *)              printf '{%s}' "$base" ;;
  esac
}

# rt_check <root>: drives every command in <root>/hooks/hooks.json; prints one
# "MISSING <script> (<event>)" line per command whose stamp did not appear and
# a final "DRIVEN <n>" line. The reader is always the repo's own hook-io.sh.
rt_check() {
  local root="$1" plan ev tool script args n=0 stmp dir
  plan="$(drive_plan "$root")"
  while IFS='|' read -r ev tool script args; do
    [ -n "$script" ] || continue
    n=$((n + 1))
    stmp="$(mktemp -d "$WIRING_TMP/rt-tmp-XXXXXX")"
    # shellcheck disable=SC2086  # $args is the registered flag list (one word or none)
    ( cd "$RT_PROJ" && env -i PATH="$PATH" HOME="$WIRING_TMP/rt-home" TMPDIR="$stmp" \
        CLAUDE_PROJECT_DIR="$RT_PROJ" CLAUDE_PLUGIN_ROOT="$root" \
        "$root/hooks/$script" $args <<<"$(rt_payload "$ev" "$tool")" ) >/dev/null 2>&1 || true
    dir="$(env -i PATH="$PATH" TMPDIR="$stmp" CLAUDE_PROJECT_DIR="$RT_PROJ" \
        bash -c '. "$1" && mtk_hook_seen_dir' _ "$REPO_ROOT/hooks/lib/hook-io.sh" </dev/null 2>/dev/null)" || dir=""
    if [ -z "$dir" ] || [ ! -f "$dir/$script" ]; then
      printf 'MISSING %s (%s%s)\n' "$script" "$ev" "${args:+ $args}"
    fi
  done <<<"$plan"
  printf 'DRIVEN %s\n' "$n"
}

rt_out="$(rt_check "$REPO_ROOT")"
rt_driven="$(awk '$1=="DRIVEN"{print $2}' <<<"$rt_out")"
rt_missing="$(grep '^MISSING ' <<<"$rt_out" || true)"
if [ -n "$rt_missing" ] || [ "${rt_driven:-0}" -lt 1 ]; then
  printf 'FAIL: runtime stamp check (driven=%s):\n%s\n' "${rt_driven:-0}" "$rt_missing" >&2
  exit 1
fi
printf '  PASS  runtime: all %s registered hook commands stamped under mtk_hook_seen_dir\n' "$rt_driven"

# Negative control: a temp copy of hooks/ whose evidence-ledger.sh stamp sits
# inside `if false` still passes the static check above but must fail the
# runtime one, naming exactly that hook (scripts/ is linked so other hooks keep
# their helper scripts).
mkdir -p "$WIRING_TMP/rt-neg"
cp -R "$REPO_ROOT/hooks" "$WIRING_TMP/rt-neg/hooks"
ln -s "$REPO_ROOT/scripts" "$WIRING_TMP/rt-neg/scripts"
sed 's/^mtk_hook_seen evidence-ledger\.sh$/if false; then mtk_hook_seen evidence-ledger.sh; fi/' \
  "$REPO_ROOT/hooks/evidence-ledger.sh" >"$WIRING_TMP/rt-neg/hooks/evidence-ledger.sh"
if ! grep -q '^if false; then mtk_hook_seen evidence-ledger\.sh; fi$' "$WIRING_TMP/rt-neg/hooks/evidence-ledger.sh"; then
  printf 'FAIL: negative control setup: evidence-ledger.sh stamp line not found to wrap\n' >&2
  exit 1
fi
stamp_check "$WIRING_TMP/rt-neg" >/dev/null 2>&1 \
  || { printf 'FAIL: negative control setup: the static check should still pass on the if-false copy\n' >&2; exit 1; }
rt_neg="$(rt_check "$WIRING_TMP/rt-neg")"
rt_neg_missing="$(grep '^MISSING ' <<<"$rt_neg" || true)"
if [ "$rt_neg_missing" = "MISSING evidence-ledger.sh (PostToolUse)" ]; then
  printf '  PASS  negative control: stamp under `if false` → runtime check fails naming evidence-ledger.sh only\n'
else
  printf 'FAIL: negative control: expected only evidence-ledger.sh missing, got:\n%s\n' "$rt_neg" >&2
  exit 1
fi

# 6. the cut hooks are gone from hooks/ (wiring alone could be re-added by mistake)
cut=0
for h in rule-trigger.sh userprompt-dispatch.sh read-guard.sh fact-force-guard.sh \
         mcp-health.sh compress-monitor.sh pre-compact-snapshot.sh capture-learnings.sh \
         api-compat-check.sh verify-behavioral-diff.sh interactive-guard.sh \
         post-compact.sh session-analytics.sh context-budget.sh \
         lib/trigger-hints.sh lib/prompt-nudges.sh lib/skill-queue.sh; do
  if [ -e "$REPO_ROOT/hooks/$h" ]; then
    printf 'FAIL: hooks/%s should have been removed\n' "$h" >&2
    cut=1
  fi
done
[ "$cut" -eq 0 ] || exit 1
printf '  PASS  cut hooks are absent from hooks/\n'

# 7. nothing in hooks/ or scripts/ still writes or reads the tier-2 queue
if grep -rlE '\.claude/queue|queue_skill|skill-queue\.sh' "$REPO_ROOT/hooks" "$REPO_ROOT/scripts" >/dev/null 2>&1; then
  printf 'FAIL: queue writers/readers remain:\n%s\n' \
    "$(grep -rlE '\.claude/queue|queue_skill|skill-queue\.sh' "$REPO_ROOT/hooks" "$REPO_ROOT/scripts" || true)" >&2
  exit 1
fi
printf '  PASS  no tier-2 queue writers or readers remain\n'

printf '\nAll hooks wiring checks passed.\n'
