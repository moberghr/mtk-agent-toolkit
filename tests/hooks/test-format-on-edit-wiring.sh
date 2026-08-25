#!/usr/bin/env bash
set -euo pipefail

# format-on-edit.sh must be wired from the PLUGIN's hooks/hooks.json, never from
# a generated project .claude/settings.json.
#
# WHY. `$CLAUDE_PLUGIN_ROOT` is only defined for hooks a plugin declares in its
# own hooks.json. Inside a project's settings.json it expands to the empty
# string, so the command becomes `bash /hooks/format-on-edit.sh` and every Edit
# spawns a doomed process:
#     bash: /hooks/format-on-edit.sh: No such file or directory
# Measured 4,552 such failures across 7 bootstrapped repos — each one a process
# spawn plus a failure attachment pushed into context, and formatting never ran.
#
# The hook self-gates (unknown extension -> exit 0, project without an MTK
# tech-stack marker -> exit 0), so plugin-scope registration is safe.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/format-on-edit.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# --- Case 1: the plugin declares all three halves ---------------------------
python3 - "$REPO_ROOT/hooks/hooks.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1])).get("hooks", {})
def cmds(ev):
    return [h.get("command","") for m in d.get(ev, []) for h in m.get("hooks", [])]
missing = []
if not any("format-on-edit.sh" in c and "--flush" not in c for c in cmds("PostToolUse")):
    missing.append("PostToolUse (queue)")
for ev in ("Stop", "SubagentStop"):
    if not any("format-on-edit.sh" in c and "--flush" in c for c in cmds(ev)):
        missing.append(f"{ev} (--flush)")
if missing:
    print("FAIL: hooks.json missing format-on-edit wiring: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
# The PostToolUse half must be matched on Edit|Write, not fired on every tool.
for m in d.get("PostToolUse", []):
    if any("format-on-edit.sh" in h.get("command","") for h in m.get("hooks", [])):
        if "Edit" not in (m.get("matcher") or "") or "Write" not in (m.get("matcher") or ""):
            print(f"FAIL: PostToolUse matcher must cover Edit|Write, got {m.get('matcher')!r}", file=sys.stderr)
            sys.exit(1)
PY

# --- Case 2: no generated project-scope template still emits the broken var --
if grep -rn 'CLAUDE_PLUGIN_ROOT[^"]*format-on-edit' \
     "$REPO_ROOT/.claude/skills"/tech-stack-*/SKILL.md 2>/dev/null; then
  fail "case 2: a tech-stack Settings Additions block still emits \$CLAUDE_PLUGIN_ROOT/hooks/format-on-edit.sh into project settings.json"
fi

# --- Case 3: a project that never opted into MTK is left alone --------------
d="$(mktemp -d)"; mkdir -p "$d/.claude"
( cd "$d" && git init -q . )
printf '%s' "console.log(1)" > "$d/a.ts"
out="$(printf '{"session_id":"s1","tool_name":"Edit","tool_input":{"file_path":"%s/a.ts"}}' "$d" \
  | CLAUDE_PROJECT_DIR="$d" TMPDIR="$d" bash "$HOOK" 2>&1 || true)"
q="$(ls "$d"/mtk-format-queue-* 2>/dev/null | head -1 || true)"
[ -z "$q" ] || fail "case 3: hook queued a path in a project with no .claude/tech-stack marker"

# --- Case 4: a bootstrapped project still queues ---------------------------
printf 'typescript\n' > "$d/.claude/tech-stack"
printf '{"session_id":"s1","tool_name":"Edit","tool_input":{"file_path":"%s/a.ts"}}' "$d" \
  | CLAUDE_PROJECT_DIR="$d" TMPDIR="$d" bash "$HOOK" >/dev/null 2>&1 || true
q="$(ls "$d"/mtk-format-queue-* 2>/dev/null | head -1 || true)"
[ -n "$q" ] || { rm -rf "$d"; fail "case 4: opted-in project did not queue the edited path"; }
grep -q 'a.ts' "$q" || { rm -rf "$d"; fail "case 4: queue does not contain the edited path"; }
rm -rf "$d"

printf 'PASS: format-on-edit plugin-scope wiring\n'
