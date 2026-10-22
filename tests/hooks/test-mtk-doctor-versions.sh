#!/usr/bin/env bash
set -euo pipefail

# mtk-doctor version lines (9.4.2):
#   - The repo's setup stamp versus the plugin, through scripts/stamp-version.sh
#     --compare: PASS when equal; WARN with /mtk-setup --refresh when older; WARN
#     to update the plugin when newer.
#   - The marketplace that MTK was installed from must not list its own mtk
#     `version` that differs from what is installed. moberg-plugins sat at 8.0.1
#     while 9.4.x shipped, because a duplicate version in a marketplace entry goes
#     stale silently.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; }

SBX="$(mktemp -d -t mtk-doctor-versions-XXXXXX)"
trap 'rm -rf "$SBX"' EXIT
PROJ="$SBX/proj"; H="$SBX/home"
mkdir -p "$PROJ/scripts" "$PROJ/hooks/lib" "$PROJ/.claude" "$PROJ/.claude-plugin" "$H/.claude/plugins" "$SBX/mkt/.claude-plugin"
cp "$REPO_ROOT/scripts/mtk-doctor.sh" "$REPO_ROOT/scripts/stamp-version.sh" "$PROJ/scripts/"
cp "$REPO_ROOT/hooks/lib/narrow-permissions.txt" "$PROJ/hooks/lib/"
printf '{\n  "version": "9.9.1",\n  "files": {}\n}\n' > "$PROJ/.claude/manifest.json"
printf '{\n  "name": "mtk",\n  "version": "9.9.1"\n}\n' > "$PROJ/.claude-plugin/plugin.json"
( cd "$PROJ" && git init -q . )

run_doctor() { ( cd "$PROJ" && env -u MTK_HELPER_ROOT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR HOME="$H" bash "$PROJ/scripts/mtk-doctor.sh" 2>&1 ) || true; }
line() { grep -E "$1" <<<"$2" || true; }

# --- setup stamp versus plugin ----------------------------------------------------
printf '{"version":"7.24.0"}\n' > "$PROJ/.claude/mtk-version.json"
L="$(line 'setup stamp' "$(run_doctor)")"
case "$L" in *'⚠'*'7.24.0'*'9.9.1'*'/mtk-setup --refresh'*) : ;; *) fail "older stamp must WARN with /mtk-setup --refresh. Got: $L" ;; esac
ok "older stamp -> WARN pointing at /mtk-setup --refresh"

printf '{ "version": "9.9.1" }\n' > "$PROJ/.claude/mtk-version.json"
L="$(line 'setup stamp' "$(run_doctor)")"
case "$L" in *'✓'*'9.9.1'*) : ;; *) fail "equal stamp must PASS. Got: $L" ;; esac
ok "equal stamp -> PASS"

printf '{"version":"9.10.0"}\n' > "$PROJ/.claude/mtk-version.json"
L="$(line 'setup stamp' "$(run_doctor)")"
case "$L" in *'⚠'*'9.10.0'*'newer'*) : ;; *) fail "newer stamp must WARN that the plugin is behind. Got: $L" ;; esac
ok "newer stamp -> WARN that the plugin is behind"

# --- marketplace entry duplicate version ------------------------------------------
printf '{"version": 2, "plugins": {"mtk@mkt": [{"scope": "user", "version": "9.9.1"}]}}\n' > "$H/.claude/plugins/installed_plugins.json"
printf '{"mkt": {"installLocation": "%s"}}\n' "$SBX/mkt" > "$H/.claude/plugins/known_marketplaces.json"
printf '{"name": "mkt", "plugins": [{"name": "mtk", "version": "8.0.1", "source": {"source": "github", "repo": "x/y"}}]}\n' > "$SBX/mkt/.claude-plugin/marketplace.json"
L="$(line 'marketplace' "$(run_doctor)")"
case "$L" in *'⚠'*'mkt'*'8.0.1'*'9.9.1'*) : ;; *) fail "a stale duplicate entry version must WARN naming the marketplace and both versions. Got: $L" ;; esac
ok "stale marketplace entry version -> WARN"

printf '{"name": "mkt", "plugins": [{"name": "mtk", "version": "9.10.0", "source": {"source": "github", "repo": "x/y"}}]}\n' > "$SBX/mkt/.claude-plugin/marketplace.json"
L="$(line 'marketplace' "$(run_doctor)")"
case "$L" in *'⚠'*) fail "a newer entry is a pending update, not a stale catalog. Got: $L" ;; esac
ok "newer entry version (pending update) -> no WARN"

printf '{"name": "mkt", "plugins": [{"name": "mtk", "source": {"source": "github", "repo": "x/y", "ref": "plugin"}}]}\n' > "$SBX/mkt/.claude-plugin/marketplace.json"
L="$(line 'marketplace' "$(run_doctor)")"
case "$L" in *'⚠'*) fail "an entry without a version must not WARN. Got: $L" ;; esac
ok "entry without a version -> no WARN"

rm -f "$H/.claude/plugins/installed_plugins.json"
L="$(line 'marketplace' "$(run_doctor)")"
case "$L" in *'⚠'*) fail "no MTK plugin install must not WARN about marketplaces. Got: $L" ;; esac
ok "no plugin install -> no marketplace WARN"

echo "test-mtk-doctor-versions: all checks passed"
