#!/usr/bin/env bash
set -euo pipefail

# hooks/hooks.json is the only hook registration (S3.6). This pins the runtime
# diet: no hook on the read path (Read/Grep/Glob), on MCP calls or on
# UserPromptSubmit, no PreCompact snapshot, one SessionStart entry that also
# covers compaction, and every registered command resolves to an executable
# script in hooks/. The cut hooks must stay cut.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HJ="$REPO_ROOT/hooks/hooks.json"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available" >&2; exit 0; }

python3 - "$HJ" "$REPO_ROOT" <<'PY'
import json, os, re, sys

path, root = sys.argv[1], sys.argv[2]
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
    for ev, entries in hooks.items():
        for entry in entries:
            key = (ev, entry.get("matcher", ""))
            for h in entry.get("hooks", []):
                cmd = h["command"].replace('"', "")
                name = cmd.split("/hooks/", 1)[1]
                out.setdefault(key, []).append(name)
    return out

expected = {
    ("SessionStart", "startup|clear|compact|resume"): ["session-start"],
    ("PreToolUse", "Bash"): ["security-gate.sh", "format-on-edit.sh --flush-before-verify"],
    ("PreToolUse", "Edit|Write"): ["scope-guard.sh", "config-guard.sh"],
    ("PostToolUse", "Edit|Write|Bash"): ["evidence-ledger.sh"],
    ("PostToolUse", "Edit|Write"): ["spec-approval-trigger.sh", "format-on-edit.sh"],
    ("Stop", ""): ["verify-completion", "format-on-edit.sh --flush",
                   "workflow-continuation.sh", "cost-tracker.sh"],
}
got = table()
if got != expected:
    fails.append("hook table drifted:\n  expected %r\n  got      %r" % (expected, got))

# 4. every registered script exists and is executable
for (ev, m), names in got.items():
    for n in names:
        script = os.path.join(root, "hooks", n.split()[0])
        if not os.path.isfile(script):
            fails.append("%s/%s: %s does not exist" % (ev, m, script))
        elif not os.access(script, os.X_OK):
            fails.append("%s/%s: %s is not executable" % (ev, m, script))

# 5. the async Stop recorders stay async
for entry in hooks.get("Stop", []):
    for h in entry.get("hooks", []):
        if h["command"].rstrip('"').endswith(("cost-tracker.sh", "workflow-continuation.sh")):
            if h.get("async") is not True:
                fails.append("%s must be async" % h["command"])

if fails:
    for f in fails:
        print("FAIL: " + f, file=sys.stderr)
    sys.exit(1)
print("  PASS  hooks.json matches the runtime-diet table")
PY

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
