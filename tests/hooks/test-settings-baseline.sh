#!/usr/bin/env bash
set -euo pipefail

# The native permission baseline replaced hooks/read-guard.sh (F001):
#   (a) every secret pattern read-guard denied at d49a214 has a baseline
#       `Read(**/<pattern>)` deny rule (SKIP when d49a214 is not in history)
#   (b) settings-baseline.sh --missing / --merge: lists absent rules, unions them
#       in via merge-settings.sh keeping every existing key and rule, idempotent,
#       --out leaves the original untouched
#   (c) setup-refresh-plan.sh reports a `permissions-baseline` row: stale with
#       the missing count, fresh once merged
#   (d) mtk-doctor WARNs naming the missing rules; --fix merges them
#   (e) the `### settings` section: autoCompactWindow in --json / --missing /
#       --merge (an existing value wins); doctor --fix merges it, but the
#       doctor's baseline WARN leaves it to the auto-compaction line (9.4.1)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SB="$REPO_ROOT/scripts/settings-baseline.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available" >&2; exit 0; }

DENY="$(bash "$SB" --json | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["permissions"]["deny"]))')"
[ -n "$DENY" ] || fail "baseline --json produced no deny rules"

# --- (a) read-guard parity --------------------------------------------------------
if git -C "$REPO_ROOT" cat-file -e 'd49a214:hooks/read-guard.sh' 2>/dev/null; then
  OLD="$(git -C "$REPO_ROOT" show 'd49a214:hooks/read-guard.sh')"
  # The secret classification `case "$BASE" in … esac`; arms that set is_secret=1.
  PATTERNS="$(awk '/case "\$BASE" in/{f=1;next} f&&/^esac/{exit} f&&/is_secret=1/{sub(/\).*/,""); gsub(/[[:space:]]/,""); print}' <<<"$OLD" | tr '|' '\n' | awk 'NF')"
  [ "$(printf '%s\n' "$PATTERNS" | wc -l | tr -d ' ')" -ge 20 ] || fail "(a) extracted too few read-guard patterns: $PATTERNS"
  missing=""
  while IFS= read -r pat; do
    grep -qxF "Read(**/$pat)" <<<"$DENY" || missing="$missing $pat"
  done <<<"$PATTERNS"
  [ -z "$missing" ] || fail "(a) read-guard patterns with no baseline deny rule:$missing"
  printf '  PASS  (a) all %s read-guard secret patterns have a baseline deny rule\n' "$(printf '%s\n' "$PATTERNS" | wc -l | tr -d ' ')"
else
  printf '  SKIP  (a) d49a214 not in history — read-guard parity not checked\n'
fi

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
NRULES="$(bash "$SB" --json | python3 -c 'import json,sys; d=json.load(sys.stdin); p=d["permissions"]; print(len(p["deny"])+len(p["ask"])+len([k for k in d if k!="permissions"]))')"

# --- (b) --missing / --merge -------------------------------------------------------
rc=0; out="$(bash "$SB" --missing "$SBX/none.json")" || rc=$?
[ "$rc" -eq 1 ] && [ "$(awk 'NF' <<<"$out" | wc -l | tr -d ' ')" = "$NRULES" ] || fail "(b) a missing file must lack all $NRULES rules (rc=$rc)"
cat > "$SBX/s.json" <<'JSON'
{"env":{"KEEP":"1"},"permissions":{"allow":["Bash(make test)"],"deny":["Read(**/.env)","Bash(rm -rf:*)"]}}
JSON
cp "$SBX/s.json" "$SBX/orig.json"
rc=0; out="$(bash "$SB" --missing "$SBX/s.json")" || rc=$?
[ "$rc" -eq 1 ] || fail "(b) partial file must report missing rules"
grep -qF $'deny\tRead(**/id_rsa)' <<<"$out" || fail "(b) --missing must name Read(**/id_rsa). Got: $out"
grep -qF 'Read(**/.env)' <<<"$out" && fail "(b) a present rule was reported missing"
bash "$SB" --merge "$SBX/s.json" --out "$SBX/out.json"
cmp -s "$SBX/s.json" "$SBX/orig.json" || fail "(b) --out must leave the original untouched"
bash "$SB" --missing "$SBX/out.json" >/dev/null || fail "(b) merged copy still misses rules"
bash "$SB" --merge "$SBX/s.json"
python3 - "$SBX/s.json" <<'PY' || fail "(b) in-place merge dropped existing settings"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["env"] == {"KEEP": "1"}, d
assert d["permissions"]["allow"] == ["Bash(make test)"], d
assert "Bash(rm -rf:*)" in d["permissions"]["deny"], d
assert d["permissions"]["deny"].count("Read(**/.env)") == 1, d
PY
cp "$SBX/s.json" "$SBX/once.json"; bash "$SB" --merge "$SBX/s.json"
cmp -s "$SBX/s.json" "$SBX/once.json" || fail "(b) --merge must be idempotent"
printf '  PASS  (b) --missing lists absent rules; --merge unions, keeps settings, is idempotent\n'

# --- (c) setup-refresh plan row ----------------------------------------------------
PROJ="$SBX/proj"; mkdir -p "$PROJ/.claude"; ( cd "$PROJ" && git init -q . )
cp "$SBX/orig.json" "$PROJ/.claude/settings.json"
row() { ( cd "$PROJ" && bash "$REPO_ROOT/scripts/setup-refresh-plan.sh" --json ) | python3 -c 'import json,sys; r=[a for a in json.load(sys.stdin)["artifacts"] if a["artifact"]=="permissions-baseline"]; print(r[0]["status"]+"|"+r[0]["reason"] if r else "NO-ROW")'; }
r="$(row)"; case "$r" in stale*missing*) : ;; *) fail "(c) plan must mark permissions-baseline stale. Got: $r" ;; esac
bash "$SB" --merge "$PROJ/.claude/settings.json"
r="$(row)"; case "$r" in fresh*) : ;; *) fail "(c) plan must mark permissions-baseline fresh after merge. Got: $r" ;; esac
printf '  PASS  (c) setup-refresh plan: permissions-baseline stale, then fresh\n'

# --- (d) mtk-doctor WARN + --fix -----------------------------------------------------
DOC="$SBX/doc"; mkdir -p "$DOC/scripts" "$DOC/hooks/lib" "$DOC/.claude/references"
cp "$REPO_ROOT/scripts/mtk-doctor.sh" "$REPO_ROOT/scripts/settings-baseline.sh" "$DOC/scripts/"
cp "$REPO_ROOT/hooks/merge-settings.sh" "$DOC/hooks/"; cp "$REPO_ROOT/hooks/lib/narrow-permissions.txt" "$DOC/hooks/lib/"
cp "$REPO_ROOT/.claude/references/settings-baseline.md" "$DOC/.claude/references/"
( cd "$DOC" && git init -q . )
cp "$SBX/orig.json" "$DOC/.claude/settings.json"
doctor() { ( cd "$DOC" && env -u MTK_HELPER_ROOT -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR HOME="$SBX/home" bash scripts/mtk-doctor.sh "$@" 2>&1 ) || true; }
out="$(doctor)"
grep -q 'missing baseline permission rules' <<<"$out" || fail "(d) doctor must WARN on missing baseline rules. Output: $(grep -i baseline <<<"$out" || true)"
grep -qF 'Read(**/.npmrc)' <<<"$out" || fail "(d) the WARN must name the missing rules"
out="$(doctor --fix)"
grep -q 'permission baseline merged' <<<"$out" || fail "(d) --fix must merge the baseline. Output: $(grep -i baseline <<<"$out" || true)"
bash "$SB" --missing "$DOC/.claude/settings.json" >/dev/null || fail "(d) --fix left rules missing"
grep -q '"KEEP"' "$DOC/.claude/settings.json" || fail "(d) --fix dropped existing settings"
out="$(doctor)"
grep -q 'permission baseline present' <<<"$out" || fail "(d) after --fix the baseline must PASS"
printf '  PASS  (d) mtk-doctor WARNs on missing rules and --fix merges them\n'

# --- (e) settings scalar keys ------------------------------------------------------
bash "$SB" --json | python3 -c 'import json,sys; assert json.load(sys.stdin)["autoCompactWindow"]==300000' || fail "(e) --json must carry autoCompactWindow 300000 at the top level"
printf '{"permissions":{}}\n' > "$SBX/e1.json"
printf '{"autoCompactWindow":500000}\n' > "$SBX/e2.json"
out="$(bash "$SB" --missing "$SBX/e1.json" || true)"
grep -qF $'settings\tautoCompactWindow: 300000' <<<"$out" || fail "(e) --missing must list the absent setting. Got: $out"
# e3 = e2's custom value plus every baseline rule, so --missing must exit 0 and list nothing.
cp "$SBX/e2.json" "$SBX/e3.json"; bash "$SB" --merge "$SBX/e3.json"
rc=0; out="$(bash "$SB" --missing "$SBX/e3.json")" || rc=$?
[ "$rc" = "0" ] || fail "(e) --missing must exit 0 when the target has every baseline item (rc=$rc). Got: $out"
grep -q 'autoCompactWindow' <<<"$out" && fail "(e) a present setting (any value) must not be missing"
bash "$SB" --merge "$SBX/e1.json"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["autoCompactWindow"]==300000' "$SBX/e1.json" || fail "(e) --merge must add an absent setting"
bash "$SB" --merge "$SBX/e2.json"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["autoCompactWindow"]==500000' "$SBX/e2.json" || fail "(e) --merge must keep an existing setting value"
printf '{"env":{"KEEP":"1"}}\n' > "$DOC/.claude/settings.json"
out="$(doctor)"
bl_lines="$(grep -i 'baseline' <<<"$out" || true)"
case "$bl_lines" in *autoCompactWindow*) fail "(e) the baseline line must leave autoCompactWindow to the auto-compaction line. Output: $bl_lines" ;; esac
doctor --fix >/dev/null
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["autoCompactWindow"]==300000' "$DOC/.claude/settings.json" || fail "(e) doctor --fix must merge the setting"
printf '  PASS  (e) settings keys: --json, --missing, --merge (existing value wins), doctor --fix; not in the baseline WARN\n'

printf '\nAll settings-baseline checks passed.\n'
