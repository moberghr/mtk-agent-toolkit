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

# --- Case 1: the plugin declares the queue, the pre-verify flush, the Stop flush
# SubagentStop must NOT flush: it fires mid-turn and formats files the parent
# still has open, so the parent's next Edit fails "modified since read".
python3 - "$REPO_ROOT/hooks/hooks.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1])).get("hooks", {})
def entries(ev):
    return [(m.get("matcher") or "", h.get("command", "")) for m in d.get(ev, []) for h in m.get("hooks", [])]
def cmds(ev):
    return [c for _, c in entries(ev)]
missing = []
if not any("format-on-edit.sh" in c and "--flush" not in c for c in cmds("PostToolUse")):
    missing.append("PostToolUse (queue)")
if not any("format-on-edit.sh" in c and c.rstrip().endswith("--flush") for c in cmds("Stop")):
    missing.append("Stop (--flush)")
if not any("format-on-edit.sh" in c and "--flush-before-verify" in c and "Bash" in m
           for m, c in entries("PreToolUse")):
    missing.append("PreToolUse Bash (--flush-before-verify)")
if missing:
    print("FAIL: hooks.json missing format-on-edit wiring: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
if any("format-on-edit.sh" in c for c in cmds("SubagentStop")):
    print("FAIL: SubagentStop must not run format-on-edit (it formats the parent's open files mid-turn)", file=sys.stderr)
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

# --- Case 5: the flush formats only — no lint autofix, no dotnet style/analyzers
# Stubs on PATH log every call. `ruff check --fix` is a lint autofix, and
# `dotnet format style` loads MSBuild — slow enough to hit the Stop timeout.
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/.claude" "$W/bin" "$W/src"
git -C "$W" init -q
printf 'python\n' > "$W/.claude/tech-stack"
LOG="$W/calls.log"
for tool in ruff dotnet; do
  cat > "$W/bin/$tool" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\$*" >> "$LOG"
EOF
  chmod +x "$W/bin/$tool"
done
printf '<Project Sdk="Microsoft.NET.Sdk"/>\n' > "$W/src/App.csproj"
printf 'class A {}\n' > "$W/src/A.cs"
printf 'x = 1\n' > "$W/src/a.py"
run_fmt() { # $1 = payload, rest = hook args
  local payload="$1"; shift
  printf '%s' "$payload" | PATH="$W/bin:$PATH" CLAUDE_PROJECT_DIR="$W" TMPDIR="$W" bash "$HOOK" "$@" >/dev/null 2>&1 || true
}
queue() { run_fmt "{\"session_id\":\"s5\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$1\"}}"; }
queue "$W/src/A.cs"; queue "$W/src/a.py"
run_fmt '{"session_id":"s5","hook_event_name":"Stop"}' --flush
calls="$(cat "$LOG" 2>/dev/null || true)"
case "$calls" in *'ruff format'*) : ;; *) fail "case 5: ruff format did not run. Calls: $calls" ;; esac
case "$calls" in *'ruff check'*) fail "case 5: ruff check --fix must not run. Calls: $calls" ;; esac
case "$calls" in *'dotnet format whitespace'*'--folder'*) : ;; *) fail "case 5: the dotnet flush must be 'format whitespace --folder'. Calls: $calls" ;; esac
case "$calls" in *'format style'*|*'format analyzers'*) fail "case 5: dotnet style/analyzers must not run. Calls: $calls" ;; esac
printf '  PASS  case 5: format only (ruff format, dotnet format whitespace --folder)\n'

# --- Case 6: --flush-before-verify flushes only ahead of a verification command
: > "$LOG"
queue "$W/src/a.py"
pre() { run_fmt "$(python3 -c 'import json,sys;print(json.dumps({"session_id":"s5","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1")" --flush-before-verify; }
pre 'git status'
[ ! -s "$LOG" ] || fail "case 6: a non-verification Bash call must not flush. Calls: $(cat "$LOG")"
q="$(ls "$W"/mtk-format-queue-* 2>/dev/null | awk 'NR==1')"
[ -n "$q" ] && [ -s "$q" ] || fail "case 6: the queue must survive a non-verification Bash call"
pre 'pytest -q'
grep -q 'ruff format' "$LOG" || fail "case 6: a verification command must flush the queue first"
[ ! -s "$q" ] || fail "case 6: the queue must be empty after the pre-verify flush"
printf '  PASS  case 6: pre-verify flush runs only ahead of verification\n'

printf 'PASS: format-on-edit plugin-scope wiring\n'
