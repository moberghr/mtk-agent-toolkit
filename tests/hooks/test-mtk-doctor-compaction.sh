#!/usr/bin/env bash
set -euo pipefail

# mtk-doctor reports effective auto-compaction on its own line (context
# category), resolved by hooks/lib/compaction.py the way Claude Code resolves it:
#   - WARN when it is off, naming the source (env DISABLE_AUTO_COMPACT /
#     DISABLE_COMPACT, a settings file, or ~/.claude.json when no settings file
#     sets it) — a 2026-10-22 field run had 0 compactions in 37 sessions because
#     ~/.claude/settings.json said autoCompactEnabled: false, and the doctor said
#     nothing;
#   - WARN when it is on but no window is configured (env or any settings file);
#   - PASS with the window and its source otherwise.
# The permission-baseline line no longer lists autoCompactWindow (it was item 35
# of 35 there), even though --fix still merges it.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; }

SBX="$(mktemp -d -t mtk-doctor-compaction-XXXXXX)"
trap 'rm -rf "$SBX"' EXIT
PROJ="$SBX/proj"; mkdir -p "$PROJ/scripts" "$PROJ/hooks/lib" "$PROJ/.claude/references" "$SBX/home/.claude"
cp "$REPO_ROOT/scripts/mtk-doctor.sh" "$REPO_ROOT/scripts/settings-baseline.sh" "$PROJ/scripts/"
cp "$REPO_ROOT/hooks/merge-settings.sh" "$PROJ/hooks/"
cp "$REPO_ROOT/hooks/lib/compaction.py" "$REPO_ROOT/hooks/lib/narrow-permissions.txt" "$PROJ/hooks/lib/"
cp "$REPO_ROOT/.claude/references/settings-baseline.md" "$PROJ/.claude/references/"
( cd "$PROJ" && git init -q . )
printf '{}\n' > "$PROJ/.claude/settings.json"

run_doctor() {
  ( cd "$PROJ" && env -u MTK_HELPER_ROOT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR \
      -u CLAUDE_CODE_AUTO_COMPACT_WINDOW -u DISABLE_AUTO_COMPACT -u DISABLE_COMPACT \
      HOME="$SBX/home" MTK_MANAGED_SETTINGS="$SBX/managed-settings.json" "$@" bash "$PROJ/scripts/mtk-doctor.sh" 2>&1 ) || true
}
line() { grep 'auto-compaction' <<<"$1" || true; }

# 1. Disabled in user settings: WARN naming the file.
printf '{"autoCompactEnabled": false, "autoCompactWindow": 300000}\n' > "$SBX/home/.claude/settings.json"
L="$(line "$(run_doctor)")"
case "$L" in *'⚠'*'auto-compaction disabled'*'~/.claude/settings.json'*) : ;; *) fail "user-settings off must WARN naming the file. Got: $L" ;; esac
ok "autoCompactEnabled false in ~/.claude/settings.json -> WARN naming it"

# 2. Project settings beat user settings.
printf '{"autoCompactEnabled": true}\n' > "$PROJ/.claude/settings.json"
L="$(line "$(run_doctor)")"
case "$L" in *'✓'*'auto-compaction on'*'300k'*) : ;; *) fail "project true must beat user false. Got: $L" ;; esac
ok "project settings beat user settings"
printf '{}\n' > "$PROJ/.claude/settings.json"

# 3. Only ~/.claude.json sets it (the /config store): WARN naming it.
printf '{"autoCompactWindow": 300000}\n' > "$SBX/home/.claude/settings.json"
printf '{"autoCompactEnabled": false}\n' > "$SBX/home/.claude.json"
L="$(line "$(run_doctor)")"
case "$L" in *'⚠'*'auto-compaction disabled'*'~/.claude.json'*) : ;; *) fail "~/.claude.json off must WARN naming it. Got: $L" ;; esac
ok "autoCompactEnabled false only in ~/.claude.json -> WARN naming it"
rm -f "$SBX/home/.claude.json"

# 4. Env kill switch.
L="$(line "$(run_doctor DISABLE_AUTO_COMPACT=1)")"
case "$L" in *'⚠'*'auto-compaction disabled'*'DISABLE_AUTO_COMPACT'*) : ;; *) fail "DISABLE_AUTO_COMPACT must WARN naming it. Got: $L" ;; esac
ok "DISABLE_AUTO_COMPACT -> WARN naming it"

# 5. On, window from user settings: PASS with window and source.
OUT="$(run_doctor)"
L="$(line "$OUT")"
case "$L" in *'✓'*'auto-compaction on'*'300k'*'~/.claude/settings.json'*) : ;; *) fail "on + user window must PASS with window and source. Got: $L" ;; esac
ok "on + window in user settings -> PASS naming the window and its source"

# 6. The permission-baseline line never lists autoCompactWindow.
B="$(grep -i 'baseline permission rules or settings' <<<"$OUT" || true)"
[ -n "$B" ] || fail "test setup: expected the baseline WARN for an empty project settings.json. Output: $OUT"
case "$B" in *autoCompactWindow*) fail "the baseline line must not list autoCompactWindow. Got: $B" ;; esac
ok "baseline WARN no longer lists autoCompactWindow"

# 6b. Only autoCompactWindow missing from the project file: the baseline line is a PASS.
python3 - "$PROJ/.claude/settings.json" "$PROJ" <<'PY'
import json, subprocess, sys
frag = json.loads(subprocess.check_output(["bash", sys.argv[2] + "/scripts/settings-baseline.sh", "--json"]))
frag.pop("autoCompactWindow", None)
json.dump(frag, open(sys.argv[1], "w"))
PY
B="$(grep -i 'permission baseline' <<<"$(run_doctor)" || true)"
case "$B" in *'✓'*'permission baseline present'*) : ;; *) fail "only autoCompactWindow missing must leave the baseline PASS. Got: $B" ;; esac
printf '{}\n' > "$PROJ/.claude/settings.json"
ok "only autoCompactWindow missing -> baseline PASS (the window has its own line)"

# 7. On, no window anywhere: WARN.
printf '{}\n' > "$SBX/home/.claude/settings.json"
L="$(line "$(run_doctor)")"
case "$L" in *'⚠'*'no auto-compact window'*) : ;; *) fail "no window must WARN. Got: $L" ;; esac
ok "on but no window configured -> WARN"

# 8. A settings `env` block counts: a hook inherits it, the doctor reads it.
printf '{"autoCompactWindow": 300000, "env": {"DISABLE_AUTO_COMPACT": "1"}}\n' > "$SBX/home/.claude/settings.json"
L="$(line "$(run_doctor)")"
case "$L" in *'⚠'*'auto-compaction disabled'*'DISABLE_AUTO_COMPACT'*'~/.claude/settings.json'*) : ;; *) fail "env block DISABLE_AUTO_COMPACT must WARN naming it and the file. Got: $L" ;; esac
printf '{"env": {"CLAUDE_CODE_AUTO_COMPACT_WINDOW": "400000"}}\n' > "$SBX/home/.claude/settings.json"
L="$(line "$(run_doctor)")"
case "$L" in *'✓'*'auto-compaction on'*'400k'*) : ;; *) fail "env block window must count. Got: $L" ;; esac
ok "settings env blocks: DISABLE_AUTO_COMPACT and CLAUDE_CODE_AUTO_COMPACT_WINDOW are read"

# 8b. The managed policy file beats every other settings file.
printf '{"autoCompactWindow": 300000}\n' > "$SBX/home/.claude/settings.json"
printf '{"autoCompactEnabled": false}\n' > "$SBX/managed-settings.json"
L="$(line "$(run_doctor)")"
case "$L" in *'⚠'*'auto-compaction disabled'*'managed-settings.json'*) : ;; *) fail "managed policy off must WARN naming it. Got: $L" ;; esac
rm -f "$SBX/managed-settings.json"
ok "managed-settings.json takes precedence"

# 9. A NaN window (json.load accepts it) is no window, not a crash.
printf '{"autoCompactWindow": NaN}\n' > "$SBX/home/.claude/settings.json"
L="$(line "$(run_doctor)")"
case "$L" in *'⚠'*'no auto-compact window'*) : ;; *) fail "NaN window must read as no window. Got: $L" ;; esac
ok "NaN autoCompactWindow -> no window WARN, no crash"

echo "test-mtk-doctor-compaction: all checks passed"
