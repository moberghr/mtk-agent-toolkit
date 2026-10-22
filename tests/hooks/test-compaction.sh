#!/usr/bin/env bash
set -euo pipefail

# hooks/lib/compaction.py resolves effective auto-compaction the way Claude Code
# does; context-guard (nudge wording) and mtk-doctor (auto-compaction line) both
# read it. Every case runs in a sandbox HOME and project with
# MTK_MANAGED_SETTINGS pointed into the sandbox.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/hooks/lib/compaction.py"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available" >&2; exit 0; }

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
P="$SBX/proj"; H="$SBX/home"; M="$SBX/managed.json"
mkdir -p "$P/.claude" "$H/.claude"

fails=0
check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — expected [$2] got [$3]"; fails=$((fails + 1)); fi
}
# res [env...] — the resolver's line for the sandbox, with only the given env.
res() {
  env -u CLAUDE_CODE_AUTO_COMPACT_WINDOW -u DISABLE_AUTO_COMPACT -u DISABLE_COMPACT \
    HOME="$H" MTK_MANAGED_SETTINGS="$M" "$@" python3 "$LIB" "$P"
}
clean() { rm -f "$P/.claude/settings.json" "$P/.claude/settings.local.json" "$H/.claude/settings.json" "$H/.claude.json" "$M"; }
TAB="$(printf '\t')"

clean
check "nothing set: on by default, no window" "enabled=1${TAB}enabled_source=default${TAB}window=-${TAB}window_source=default" "$(res)"

for v in 1 true yes on TRUE; do
  check "DISABLE_AUTO_COMPACT=$v turns it off" "enabled=0" "$(res DISABLE_AUTO_COMPACT="$v" | cut -f1)"
done
check "DISABLE_COMPACT turns it off too" "enabled_source=env DISABLE_COMPACT" "$(res DISABLE_COMPACT=1 | cut -f2)"
check "DISABLE_AUTO_COMPACT=0 leaves it on" "enabled=1" "$(res DISABLE_AUTO_COMPACT=0 | cut -f1)"

printf '{"autoCompactEnabled": "false"}\n' > "$P/.claude/settings.json"
check "a non-boolean autoCompactEnabled is ignored" "enabled=1${TAB}enabled_source=default" "$(res | cut -f1-2)"
clean

printf '{"autoCompactEnabled": false' > "$P/.claude/settings.local.json"   # malformed
printf '{"autoCompactEnabled": true}\n' > "$P/.claude/settings.json"
check "a malformed settings file is skipped, as Claude Code skips it" "enabled_source=.claude/settings.json" "$(res | cut -f2)"
clean

printf '{"autoCompactEnabled": true}\n' > "$P/.claude/settings.local.json"
printf '{"autoCompactEnabled": false}\n' > "$M"
check "the managed policy file beats local settings" "enabled=0${TAB}enabled_source=managed-settings.json" "$(res | cut -f1-2)"
clean

printf '{"autoCompactEnabled": false}\n' > "$H/.claude.json"
check "~/.claude.json applies when no settings file sets it" "enabled=0${TAB}enabled_source=~/.claude.json" "$(res | cut -f1-2)"
printf '{"autoCompactEnabled": true}\n' > "$H/.claude/settings.json"
check "user settings beat ~/.claude.json" "enabled=1${TAB}enabled_source=~/.claude/settings.json" "$(res | cut -f1-2)"
clean

printf '{"autoCompactWindow": 400000}\n' > "$H/.claude/settings.json"
printf '{"autoCompactWindow": 300000}\n' > "$P/.claude/settings.json"
check "project window beats user window" "window=300000${TAB}window_source=.claude/settings.json" "$(res | cut -f3-4)"
check "env window beats settings" "window=250000${TAB}window_source=env CLAUDE_CODE_AUTO_COMPACT_WINDOW" "$(res CLAUDE_CODE_AUTO_COMPACT_WINDOW=250000 | cut -f3-4)"
clean

printf '{"env": {"DISABLE_AUTO_COMPACT": "1", "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "350000"}}\n' > "$H/.claude/settings.json"
check "settings env block: kill switch" "enabled=0${TAB}enabled_source=env DISABLE_AUTO_COMPACT (~/.claude/settings.json)" "$(res | cut -f1-2)"
check "settings env block: window" "window=350000" "$(res | cut -f3)"
check "the process env beats the env block" "enabled=1" "$(res DISABLE_AUTO_COMPACT=0 | cut -f1)"
clean

for bad in NaN Infinity -5 0 '"abc"' true; do
  printf '{"autoCompactWindow": %s}\n' "$bad" > "$P/.claude/settings.json"
  check "window $bad reads as no window" "window=-" "$(res | cut -f3)"
done
clean

rc=0; python3 "$LIB" "$P" extra >/dev/null 2>&1 || rc=$?
check "usage error exits 2" "2" "$rc"

if [ "$fails" -ne 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "All compaction checks passed"
