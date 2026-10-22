#!/usr/bin/env bash
set -euo pipefail

# session-start compares the repo's setup stamp (.claude/mtk-version.json,
# written by scripts/stamp-version.sh) with the plugin's manifest version.
# Before 9.4.2 every difference said "MTK update available … use the plugin
# manager", but the plugin manager cannot change the stamp, so about 20 repos
# showed it forever. A stamp written with a space after the colon was never read.
#   stamp older  -> "set up with MTK X … run /mtk-setup --refresh"
#   stamp newer  -> update the plugin
#   equal / none -> nothing
# Versions compare numerically (9.10.0 is newer than 9.4.2).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/session-start"

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
export TMPDIR="$SBX/tmp"; mkdir -p "$TMPDIR"
PLUG="$SBX/plugin"; mkdir -p "$PLUG/.claude"
printf '{\n  "version": "9.4.2"\n}\n' > "$PLUG/.claude/manifest.json"
P="$SBX/proj"; mkdir -p "$P/.claude"; git -C "$P" init -q

fails=0
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
run() { (cd "$P" && CLAUDE_PLUGIN_ROOT="$PLUG" CLAUDE_PROJECT_DIR="$P" bash "$HOOK" <<<'{"hook_event_name":"SessionStart","source":"startup","session_id":"s-v"}' 2>/dev/null || true); }
stamp() { printf '%s\n' "$1" > "$P/.claude/mtk-version.json"; }

stamp '{"version":"7.24.0","installed":"2026-05-01"}'
out="$(run)"
case "$out" in *'set up with MTK 7.24.0'*'9.4.2'*'/mtk-setup --refresh'*) echo "PASS: older stamp -> refresh message" ;; *) fail "older stamp must point at /mtk-setup --refresh. Got: $out" ;; esac
case "$out" in *'plugin manager'*) fail "older stamp must not send the engineer to the plugin manager. Got: $out" ;; esac

stamp '{ "version": "7.10.2" }'
out="$(run)"
case "$out" in *'set up with MTK 7.10.2'*) echo "PASS: stamp with spaces is read" ;; *) fail "a stamp written with a space after the colon must be read. Got: $out" ;; esac

stamp '{"version":"9.4.2"}'
out="$(run)"
case "$out" in *'set up with MTK'*|*'newer than the installed plugin'*|*'update available'*) fail "equal versions must say nothing. Got: $out" ;; *) echo "PASS: equal -> no message" ;; esac

stamp '{"version":"9.10.0"}'
out="$(run)"
case "$out" in *'9.10.0'*'newer than the installed plugin'*'9.4.2'*) echo "PASS: newer stamp (numeric compare) -> update the plugin" ;; *) fail "9.10.0 is newer than 9.4.2 and must ask for a plugin update. Got: $out" ;; esac

# Without CLAUDE_PLUGIN_ROOT (another harness), the manifest next to the hook is used.
stamp '{"version":"7.0.0"}'
out="$(cd "$P" && env -u CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR="$P" bash "$HOOK" <<<'{"hook_event_name":"SessionStart","source":"startup"}' 2>/dev/null || true)"
case "$out" in *'set up with MTK 7.0.0'*'/mtk-setup --refresh'*) echo "PASS: no CLAUDE_PLUGIN_ROOT -> the hook's own manifest" ;; *) fail "without CLAUDE_PLUGIN_ROOT the drift check must use the manifest next to the hook. Got: $out" ;; esac

rm -f "$P/.claude/mtk-version.json"
out="$(run)"
case "$out" in *'set up with MTK'*|*'newer than the installed plugin'*) fail "no stamp must say nothing. Got: $out" ;; *) echo "PASS: no stamp -> no message" ;; esac

if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "All session-start version checks passed"
