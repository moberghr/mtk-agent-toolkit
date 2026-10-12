#!/usr/bin/env bash
set -euo pipefail

# mtk-doctor accounts for Stop-hook registrations and stale plugin-cache versions
# (issue #60: "Ran 9 stop hooks" in the field).
#
# WHY. The 9 was 5 entries in the plugin's hooks/hooks.json plus 4 in the
# project's .claude/settings.json. There is no double-run guard (removed in
# 8.1.0), so every basename wired in both places really runs twice. The doctor
# must (a) show that arithmetic, (b) WARN for every doubly-wired Stop hook,
# naming it — for every event, not only Stop — and (c) WARN for leftover version directories in the plugin cache,
# naming them and the installed one, without deleting anything.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/mtk-doctor.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; }

SBX="$(mktemp -d -t mtk-doctor-XXXXXX)"
trap 'rm -rf "$SBX"' EXIT

PROJ="$SBX/proj"; mkdir -p "$PROJ/scripts" "$PROJ/hooks" "$PROJ/.claude"
cp "$DOCTOR" "$PROJ/scripts/mtk-doctor.sh"
( cd "$PROJ" && git init -q . )

# Two Stop hooks wired in BOTH places. A third only in the plugin.
printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n' > "$PROJ/hooks/guarded.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n' > "$PROJ/hooks/naked.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n' > "$PROJ/hooks/plugin-only.sh"
chmod +x "$PROJ"/hooks/*.sh
cat > "$PROJ/hooks/hooks.json" <<'JSON'
{"hooks":{"Stop":[{"hooks":[
  {"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/guarded.sh","timeout":5},
  {"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/naked.sh","timeout":5},
  {"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/plugin-only.sh","timeout":5}
]}]}}
JSON
cat > "$PROJ/.claude/settings.json" <<'JSON'
{"hooks":{"Stop":[{"hooks":[
  {"type":"command","command":"$CLAUDE_PROJECT_DIR/hooks/guarded.sh"},
  {"type":"command","command":"$CLAUDE_PROJECT_DIR/hooks/naked.sh"}
]}]}}
JSON

# A plugin cache with two version directories and a registry that installs 7.2.0.
HOMEDIR="$SBX/home"; CACHE="$HOMEDIR/.claude/plugins/cache/mkt/mtk"
for v in 7.1.0 7.2.0; do
  mkdir -p "$CACHE/$v/.claude/skills/context-engineering"; : > "$CACHE/$v/.claude/skills/context-engineering/SKILL.md"
done
printf '{"version":2,"plugins":{"mtk@mkt":[{"scope":"user","installPath":"%s/7.2.0","version":"7.2.0"}]}}\n' "$CACHE" \
  > "$HOMEDIR/.claude/plugins/installed_plugins.json"

run_doctor() { ( cd "$PROJ" && env -u MTK_HELPER_ROOT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR "$@" bash "$PROJ/scripts/mtk-doctor.sh" 2>&1 ) || true; }

out="$(run_doctor HOME="$HOMEDIR")"

# (a) the arithmetic
grep -q '3 plugin' <<<"$out" || fail "Stop accounting should count 3 plugin entries. Output: $out"
grep -q '2 project' <<<"$out" || fail "Stop accounting should count 2 project entries"
grep -qi 'Ran 5 stop hooks' <<<"$out" || fail "accounting should name the harness figure 'Ran 5 stop hooks'"
ok "Stop registrations counted: 3 plugin + 2 project = the harness's 5"

# (b) the double wiring — every shared basename is named
grep -q 'hook wired twice' <<<"$out" || fail "no WARN for hooks wired in both places"
grep -qE 'hook wired twice.*Stop naked\.sh' <<<"$out" || fail "WARN does not name naked.sh"
grep -qE 'hook wired twice.*Stop guarded\.sh' <<<"$out" || fail "WARN does not name guarded.sh"
! grep -qE 'hook wired twice.*plugin-only\.sh' <<<"$out" || fail "plugin-only.sh must not be flagged"
ok "every doubly-wired Stop hook is named; the plugin-only one is not"

# (c) stale cache versions
grep -q 'stale plugin-cache versions' <<<"$out" || fail "no WARN for the leftover 7.1.0 directory. Output: $out"
grep -q '7.1.0' <<<"$out" || fail "stale WARN does not name 7.1.0"
grep -q 'installed is 7.2.0' <<<"$out" || fail "stale WARN does not name the installed version"
[ -d "$CACHE/7.1.0" ] || fail "doctor must not delete cache directories"
ok "stale cache version named with the installed one; nothing deleted"

# (d) project wiring removed + single version → PASS lines, no WARNs from these checks
printf '{}\n' > "$PROJ/.claude/settings.json"
rm -rf "$CACHE/7.1.0"
out="$(run_doctor HOME="$HOMEDIR")"
grep -q 'Stop hook registrations accounted for' <<<"$out" || fail "expected PASS accounting line"
! grep -q 'hook wired twice' <<<"$out" || fail "double-wiring WARN must clear once the project copy is gone"
grep -q 'plugin cache holds only the installed version' <<<"$out" || fail "expected PASS once the stale version is gone"
! grep -q 'stale plugin-cache versions' <<<"$out" || fail "stale WARN must clear"
ok "clean configuration reports PASS for both checks"

# (e) quoted plugin paths — hooks.json wraps ${CLAUDE_PLUGIN_ROOT} in double quotes so an
# install path with a space survives word-splitting; basenames must still match.
cat > "$PROJ/.claude/settings.json" <<'JSON'
{"hooks":{"Stop":[{"hooks":[
  {"type":"command","command":"$CLAUDE_PROJECT_DIR/hooks/naked.sh"}
]}]}}
JSON
cat > "$PROJ/hooks/hooks.json" <<'JSON'
{"hooks":{"Stop":[{"hooks":[
  {"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/guarded.sh\"","timeout":5},
  {"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/naked.sh\" --flush","timeout":5}
]}]}}
JSON
out="$(run_doctor HOME="$HOMEDIR")"
grep -q 'hook wired twice' <<<"$out" || fail "quoted plugin path hid the naked.sh double wiring. Output: $out"
grep -qE 'naked\.sh([^"]|$)' <<<"$out" || fail "WARN should name naked.sh without a trailing quote"
ok "quoted \${CLAUDE_PLUGIN_ROOT} commands still match by basename"

# (f) every event, not only Stop: a PreToolUse hook wired in both places is named
cat > "$PROJ/hooks/hooks.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[
  {"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/hooks/guarded.sh\"","timeout":5}
]}]}}
JSON
cat > "$PROJ/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[
  {"type":"command","command":"$CLAUDE_PROJECT_DIR/hooks/guarded.sh"}
]}]}}
JSON
out="$(run_doctor HOME="$HOMEDIR")"
grep -qE 'hook wired twice.*PreToolUse guarded\.sh' <<<"$out" || fail "PreToolUse double wiring not reported. Output: $out"
ok "double wiring is reported for every event, not only Stop"

printf '\nAll mtk-doctor Stop-hook / cache checks passed.\n'
