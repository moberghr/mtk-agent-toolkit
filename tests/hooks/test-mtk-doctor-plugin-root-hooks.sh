#!/usr/bin/env bash
set -euo pipefail

# mtk-doctor flags project hooks wired through $CLAUDE_PLUGIN_ROOT.
#
# That variable is set only for hooks a plugin declares in its own hooks.json; in
# a project's .claude/settings.json it is empty, so `bash $CLAUDE_PLUGIN_ROOT/
# hooks/format-on-edit.sh` runs as `bash /hooks/format-on-edit.sh` and fails on
# every Edit/Write. Earlier bootstraps wrote exactly that entry (seen in two repos
# after the 9.0 upgrade). The doctor must FAIL on it — not resolve the variable
# to a guessed plugin root and call the hook fine — and --fix must strip only
# those entries, leaving other hooks, other keys and settings.local.json intact.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; }

SBX="$(mktemp -d -t mtk-doctor-pluginroot-XXXXXX)"
trap 'rm -rf "$SBX"' EXIT
PROJ="$SBX/proj"; mkdir -p "$PROJ/scripts" "$PROJ/hooks/lib" "$PROJ/.claude"
cp "$REPO_ROOT/scripts/mtk-doctor.sh" "$REPO_ROOT/scripts/migrate-settings-permissions.sh" "$PROJ/scripts/"
cp "$REPO_ROOT/hooks/lib/narrow-permissions.txt" "$PROJ/hooks/lib/"
printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n' > "$PROJ/scripts/own-hook.sh"; chmod +x "$PROJ/scripts/own-hook.sh"
( cd "$PROJ" && git init -q . )

run_doctor() { ( cd "$PROJ" && env -u MTK_HELPER_ROOT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR HOME="$SBX/home" bash "$PROJ/scripts/mtk-doctor.sh" "$@" 2>&1 ) || true; }

# The field-run shape: one broken plugin-root hook beside a legitimate project hook.
cat > "$PROJ/.claude/settings.json" <<'JSON'
{
  "permissions": {"allow": ["Read"]},
  "hooks": {
    "PostToolUse": [
      {"matcher": "Edit|Write", "hooks": [
        {"type": "command", "command": "bash $CLAUDE_PLUGIN_ROOT/hooks/format-on-edit.sh"},
        {"type": "command", "command": "$CLAUDE_PROJECT_DIR/scripts/own-hook.sh"}
      ]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/verify-completion\""}]}
    ]
  }
}
JSON
cat > "$PROJ/.claude/settings.local.json" <<'JSON'
{"hooks": {"PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "bash $CLAUDE_PLUGIN_ROOT/hooks/format-on-edit.sh"}]}]}}
JSON

out="$(run_doctor)"
grep -q 'settings.json wires hooks through \$CLAUDE_PLUGIN_ROOT' <<<"$out" || fail "plugin-root hook in settings.json must FAIL. Output: $out"
grep -q 'settings.local.json wires hooks through \$CLAUDE_PLUGIN_ROOT' <<<"$out" || fail "plugin-root hook in settings.local.json must FAIL too"
grep -q 'format-on-edit.sh' <<<"$out" || fail "the FAIL should name the broken command"
grep -q 'verify-completion' <<<"$out" || fail "the braced \${CLAUDE_PLUGIN_ROOT} form must be caught as well"
! grep -q 'registered hook missing' <<<"$out" || fail "plugin-root hooks must not also surface as a generic missing-hook FAIL"
ok "doctor FAILs on \$CLAUDE_PLUGIN_ROOT hooks in both project settings files"

out="$(run_doctor --fix)"
grep -q 'removed broken \$CLAUDE_PLUGIN_ROOT hooks from .claude/settings.json' <<<"$out" || fail "--fix must report the removal. Output: $out"
python3 - "$PROJ/.claude/settings.json" "$PROJ/.claude/settings.local.json" <<'PY' || fail "--fix must strip only the plugin-root hooks"
import json, sys
main = json.load(open(sys.argv[1])); local = json.load(open(sys.argv[2]))
assert main["permissions"] == {"allow": ["Read"]}, main
cmds = [h["command"] for g in main["hooks"]["PostToolUse"] for h in g["hooks"]]
assert cmds == ["$CLAUDE_PROJECT_DIR/scripts/own-hook.sh"], cmds
assert "Stop" not in main["hooks"], main["hooks"]          # emptied event dropped
assert "hooks" not in local, local                          # emptied hooks block dropped
PY
ok "--fix strips only the broken entries and keeps the project's own hook"

out="$(run_doctor)"
! grep -q 'wires hooks through \$CLAUDE_PLUGIN_ROOT' <<<"$out" || fail "after --fix the check must be clean"
before="$(shasum "$PROJ/.claude/settings.json")"; run_doctor --fix >/dev/null; after="$(shasum "$PROJ/.claude/settings.json")"
[ "$before" = "$after" ] || fail "--fix must be idempotent on a clean file"
ok "clean after --fix, and a second --fix changes nothing"

printf '\nAll mtk-doctor plugin-root hook checks passed.\n'
