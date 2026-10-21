#!/usr/bin/env bash
set -euo pipefail

# mtk-doctor settings checks:
#   - an unparseable .claude/settings.json is a FAIL, never "hook block validated"
#   - permissions.allowedTools: FAIL only for convertible narrow entries, WARN for
#     inert broad leftovers, WARN (not "uses allowedTools") when the migration
#     script is missing or cannot check; --fix activates only narrow entries
#   - no context-budget calibration lines: the evidence ledger has no
#     window-scaled thresholds left to calibrate

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; }

SBX="$(mktemp -d -t mtk-doctor-settings-XXXXXX)"
trap 'rm -rf "$SBX"' EXIT
PROJ="$SBX/proj"; mkdir -p "$PROJ/scripts" "$PROJ/hooks" "$PROJ/.claude"
cp "$REPO_ROOT/scripts/mtk-doctor.sh" "$REPO_ROOT/scripts/migrate-settings-permissions.sh" "$PROJ/scripts/"
mkdir -p "$PROJ/hooks/lib" && cp "$REPO_ROOT/hooks/lib/narrow-permissions.txt" "$PROJ/hooks/lib/"
( cd "$PROJ" && git init -q . )

run_doctor() { ( cd "$PROJ" && env -u MTK_HELPER_ROOT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR -u MTK_CONTEXT_WINDOW_TOKENS HOME="$SBX/home" "$@" bash "$PROJ/scripts/mtk-doctor.sh" 2>&1 ) || true; }

# --- unparseable settings.json ------------------------------------------------
printf '{ "hooks": { broken\n' > "$PROJ/.claude/settings.json"
out="$(run_doctor)"
grep -q 'settings.json is not valid JSON' <<<"$out" || fail "unparseable settings.json must FAIL. Output: $out"
! grep -q 'settings.json hook block validated' <<<"$out" || fail "unparseable settings.json must not report PASS"
ok "unparseable settings.json is a FAIL, not a PASS"

# --- allowedTools: narrow -> FAIL; --fix activates narrow only; broad -> WARN --
cat > "$PROJ/.claude/settings.json" <<'JSON'
{"permissions":{"allowedTools":["Bash(dotnet test:*)","Bash(curl:*)"],"allow":["Read"]}}
JSON
out="$(run_doctor)"
grep -q 'uses permissions.allowedTools' <<<"$out" || fail "convertible narrow entry must FAIL. Output: $out"
grep -q 'Bash(dotnet test:\*)' <<<"$out" || fail "FAIL should name the convertible entry"
ok "convertible narrow entry reported as FAIL"

out="$( ( cd "$PROJ" && env -u MTK_HELPER_ROOT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR HOME="$SBX/home" bash scripts/mtk-doctor.sh --fix 2>&1 ) || true)"
python3 - "$PROJ/.claude/settings.json" <<'PY' || fail "--fix must activate only the narrow entry"
import json, sys
p = json.load(open(sys.argv[1]))["permissions"]
assert "Bash(dotnet test:*)" in p["allow"], p
assert "Bash(curl:*)" not in p["allow"], p
assert p.get("allowedTools") == ["Bash(curl:*)"], p
PY
grep -q 'migrated' <<<"$out" || fail "--fix should report the migration. Output: $out"
ok "--fix activates the narrow entry and leaves the broad one inert"

out="$(run_doctor)"
! grep -q 'uses permissions.allowedTools' <<<"$out" || fail "only broad leftovers must not FAIL. Output: $out"
grep -q 'inert broad permissions.allowedTools entries' <<<"$out" || fail "broad leftovers must WARN"
grep -q 'Bash(curl:\*)' <<<"$out" || fail "WARN should name the broad entry"
ok "broad leftovers reported as WARN, not FAIL"

# --- missing migration script: WARN, never "uses allowedTools" ---------------
rm -f "$PROJ/scripts/migrate-settings-permissions.sh"
out="$(run_doctor)"
! grep -q 'uses permissions.allowedTools' <<<"$out" || fail "a missing script must not be reported as 'uses allowedTools'"
grep -q 'allowedTools not checked' <<<"$out" || fail "a missing script should WARN that it could not check. Output: $out"
ok "missing migration script is a WARN about the check, not a finding"

# --- no context-budget calibration lines at all (thresholds removed) ----------
printf '{}\n' > "$PROJ/.claude/settings.json"
out="$(run_doctor ANTHROPIC_MODEL=claude-haiku-4-5)"
! grep -q 'context budget' <<<"$out" || fail "context-budget calibration lines must be gone. Output: $out"
ok "no context-budget calibration lines"

# --- .gitignore without .mtk/: WARN naming it; --fix appends it and the row passes --
printf '.claude/settings.local.json\n.claude/observability/' > "$PROJ/.gitignore"   # no trailing newline
out="$(run_doctor)"
grep -F '.gitignore missing entry' <<<"$out" | grep -qF '.mtk/' || fail "a .gitignore without .mtk/ must WARN naming it. Output: $(grep -i gitignore <<<"$out")"
! grep -qF '.gitignore covers expected paths' <<<"$out" || fail "missing .mtk/ must not report the covered PASS"
out="$( ( cd "$PROJ" && env -u MTK_HELPER_ROOT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR HOME="$SBX/home" bash scripts/mtk-doctor.sh --fix 2>&1 ) || true)"
grep -F '.gitignore fixed' <<<"$out" | grep -qF '.mtk/' || fail "--fix must report adding .mtk/. Output: $(grep -i gitignore <<<"$out")"
grep -qxF '.mtk/' "$PROJ/.gitignore" || fail "--fix must append .mtk/ to .gitignore"
grep -qxF '.claude/observability/' "$PROJ/.gitignore" || fail "--fix must not glue .mtk/ onto a last line that had no trailing newline. Got: $(cat "$PROJ/.gitignore")"
out="$(run_doctor)"
grep -qF '.gitignore covers expected paths' <<<"$out" || fail "after --fix the .gitignore row must PASS. Output: $(grep -i gitignore <<<"$out")"
! grep -qF '.gitignore missing entry' <<<"$out" || fail "after --fix no missing-entry WARN may remain"
ok ".gitignore missing .mtk/ WARNs; --fix appends it and the row turns PASS"

printf '\nAll mtk-doctor settings checks passed.\n'
