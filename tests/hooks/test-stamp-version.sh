#!/usr/bin/env bash
set -euo pipefail

# scripts/stamp-version.sh is the one writer of a target repo's
# .claude/mtk-version.json. setup-bootstrap runs it at install, and
# setup-refresh runs it when a refresh finishes, so the stamp follows the
# version whose setup files the repo actually has. Before 9.4.2 nothing bumped
# it after bootstrap: about 20 repos sat at 7.x and session-start said "update
# available" forever.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAMP="$REPO_ROOT/scripts/stamp-version.sh"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available" >&2; exit 0; }

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
P="$SBX/proj"; mkdir -p "$P/.claude"
M="$SBX/manifest.json"
printf '{\n  "version": "9.9.1",\n  "coding-guidelines": {"sha": "plug", "sha256": "p256"}\n}\n' > "$M"
TODAY="$(date +%Y-%m-%d)"

fails=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 — expected [$2] got [$3]"; fails=$((fails + 1)); fi; }
field() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d
for k in sys.argv[2].split("."): v=v.get(k) if isinstance(v,dict) else None
print("<none>" if v is None else v)' "$P/.claude/mtk-version.json" "$1"; }
run() { (cd "$P" && bash "$STAMP" --manifest "$M" "$@"); }

# 1. Fresh repo: version, installed today, no refreshed, the plugin's pin.
run >/dev/null
check "fresh: version from the manifest" "9.9.1" "$(field version)"
check "fresh: installed today" "$TODAY" "$(field installed)"
check "fresh: no refreshed date" "<none>" "$(field refreshed)"
check "fresh: plugin pin copied" "plug" "$(field coding-guidelines.sha)"
check "fresh: source url" "https://github.com/moberghr/mtk-agent-toolkit" "$(field source)"

# 2. An old stamp: version bumped, installed kept, refreshed set, the repo's own pin kept.
printf '{"version":"7.24.0","installed":"2026-05-01","source":"x","coding-guidelines":{"sha":"repo","sha256":"r256"},"custom":1}\n' > "$P/.claude/mtk-version.json"
out="$(run)"
check "update: version bumped" "9.9.1" "$(field version)"
check "update: installed date kept" "2026-05-01" "$(field installed)"
check "update: refreshed today" "$TODAY" "$(field refreshed)"
check "update: the repo's own guidelines pin is kept" "repo" "$(field coding-guidelines.sha)"
check "update: unknown keys kept" "1" "$(field custom)"
case "$out" in *'7.24.0 -> 9.9.1'*) echo "PASS: update: reports old -> new" ;; *) echo "FAIL: update must report 7.24.0 -> 9.9.1. Got: $out"; fails=$((fails + 1)) ;; esac

# 3. Already current: no rewrite, says so.
before="$(cat "$P/.claude/mtk-version.json")"
out="$(run)"
check "current: file unchanged" "$before" "$(cat "$P/.claude/mtk-version.json")"
case "$out" in *'already 9.9.1'*) echo "PASS: current: says already" ;; *) echo "FAIL: current must say already. Got: $out"; fails=$((fails + 1)) ;; esac

# 4. Errors: unreadable manifest or a corrupt stamp exit 2 and leave the stamp alone.
rc=0; run --manifest "$SBX/missing.json" >/dev/null 2>&1 || rc=$?
check "missing manifest exits 2" "2" "$rc"
printf 'not json{' > "$P/.claude/mtk-version.json"
rc=0; run >/dev/null 2>&1 || rc=$?
check "corrupt stamp exits 2" "2" "$rc"
check "corrupt stamp left untouched" "not json{" "$(cat "$P/.claude/mtk-version.json")"

# 5. The default manifest is the toolkit's own (script dir/../.claude/manifest.json).
rm -f "$P/.claude/mtk-version.json"
(cd "$P" && bash "$STAMP" >/dev/null)
want="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$REPO_ROOT/.claude/manifest.json")"
check "default manifest: toolkit version" "$want" "$(field version)"

# 6. --compare is read-only and numeric.
cmp() { printf '%s\n' "$1" > "$P/.claude/mtk-version.json"; (cd "$P" && bash "$STAMP" --manifest "$M" --compare); }
check "compare: older" "older 7.24.0 9.9.1" "$(cmp '{"version":"7.24.0"}')"
check "compare: equal" "equal 9.9.1 9.9.1" "$(cmp '{"version":"9.9.1"}')"
check "compare: numeric, 9.10.0 is newer than 9.9.1" "newer 9.10.0 9.9.1" "$(cmp '{"version":"9.10.0"}')"
check "compare: never writes" '{"version":"9.10.0"}' "$(cat "$P/.claude/mtk-version.json")"
rm -f "$P/.claude/mtk-version.json"
check "compare: no stamp" "none - 9.9.1" "$(cd "$P" && bash "$STAMP" --manifest "$M" --compare)"

check "compare: a leading v and a suffix read as the number" "equal v9.9.1-rc1 9.9.1" "$(cmp '{"version":"v9.9.1-rc1"}')"

# 7. Never downgrade: an older plugin refreshing a newer stamp leaves it alone.
printf '{"version":"10.0.0","installed":"2026-01-01"}\n' > "$P/.claude/mtk-version.json"
out="$(run)"
check "no downgrade: version kept" "10.0.0" "$(field version)"
case "$out" in *'newer than 9.9.1; left alone'*) echo "PASS: no downgrade: says so" ;; *) echo "FAIL: no downgrade must say so. Got: $out"; fails=$((fails + 1)) ;; esac

# 8. From a subdirectory of a git repo the stamp goes to the top level.
G="$SBX/gitrepo"; mkdir -p "$G/src/deep"; git -C "$G" init -q
(cd "$G/src/deep" && bash "$STAMP" --manifest "$M" >/dev/null)
check "subdirectory: stamp at the git top level" "yes" "$([ -f "$G/.claude/mtk-version.json" ] && echo yes || echo no)"
check "subdirectory: no stray .claude/ in the subdirectory" "no" "$([ -e "$G/src/deep/.claude" ] && echo yes || echo no)"

if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "All stamp-version checks passed"
