#!/usr/bin/env bash
# test-migrate-settings-permissions.sh — verifies scripts/migrate-settings-permissions.sh
# moves only NARROW build/test/lint entries of the invalid `permissions.allowedTools`
# key into `permissions.allow`.
#
# allowedTools has never been in effect (Claude Code reads allow / deny / ask), so
# moving it wholesale would silently switch on rules nobody ran with — Bash(python:*),
# Bash(curl:*), Write, Bash(*). Cases: --check exits 1 only for convertible entries,
# narrow entries activated and printed, broad entries left inert and printed, other
# keys preserved, idempotent second run, clean file untouched, non-list allow is an
# error, symlinked settings stay symlinks, missing file and unparseable JSON handled.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SH="$REPO_ROOT/scripts/migrate-settings-permissions.sh"

echo "=== migrate-settings-permissions Test ==="
[ -f "$TARGET_SH" ] || { echo "  FAIL  script not found: $TARGET_SH" >&2; exit 1; }

declare -a FAILS=()
pass() { echo "  PASS  $1"; }
failc() { FAILS+=("$1"); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/bad.json" <<'EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "env": {
    "MTK_HOOKS_TIER2": "1"
  },
  "permissions": {
    "allowedTools": [
      "Read",
      "Bash(dotnet build:*)",
      "Bash(git diff:*)",
      "Bash(npm run lint)",
      "Bash(python:*)",
      "Bash(npx:*)",
      "Bash(curl:*)",
      "Bash(find:*)",
      "Write",
      "Edit",
      "Bash(*)",
      "Bash(git log; rm -rf ~)"
    ],
    "allow": [
      "Read",
      "Bash(npm test:*)"
    ],
    "deny": [
      "Read(./.env)"
    ],
    "defaultMode": "default"
  },
  "teamCustom": "keep me"
}
EOF

# 1) --check exits 1 while narrow entries remain, and does not modify the file
cp "$TMP/bad.json" "$TMP/bad.orig"
set +e
check_out="$(bash "$TARGET_SH" --check "$TMP/bad.json" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] && pass "--check exits 1 when convertible narrow entries remain" \
  || failc "--check on bad file: expected exit 1, got $rc"
cmp -s "$TMP/bad.json" "$TMP/bad.orig" && pass "--check leaves the file untouched" \
  || failc "--check modified the file"

# 2) migrate: only narrow entries activated, every activation and leftover printed
out="$(bash "$TARGET_SH" "$TMP/bad.json")"
for e in 'Bash(dotnet build:*)' 'Bash(git diff:*)' 'Bash(npm run lint)'; do
  grep -qF "activated: $TMP/bad.json: \"$e\"" <<<"$out" || failc "activation of $e not printed: $out"
done
for e in 'Bash(python:*)' 'Bash(npx:*)' 'Bash(curl:*)' 'Bash(find:*)' 'Write' 'Edit' 'Bash(*)' 'Bash(git log; rm -rf ~)'; do
  grep -qF "\"$e\" needs a manual decision" <<<"$out" || failc "leftover $e not reported: $out"
done
verdicts="$(python3 - "$TMP/bad.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
p = d["permissions"]
def out(label, ok):
    print(("PASS" if ok else "FAIL") + "\t" + label)
allow = p.get("allow", [])
out("allow keeps existing order first", allow[:2] == ["Read", "Bash(npm test:*)"])
out("allow gains exactly the narrow entries",
    allow[2:] == ["Bash(dotnet build:*)", "Bash(git diff:*)", "Bash(npm run lint)"])
for broad in ["Bash(python:*)", "Bash(npx:*)", "Bash(curl:*)", "Bash(find:*)", "Write", "Edit", "Bash(*)"]:
    out("broad %s NOT activated" % broad, broad not in allow)
out("broad entries stay in allowedTools, already-allowed Read dropped",
    p.get("allowedTools") == ["Bash(python:*)", "Bash(npx:*)", "Bash(curl:*)", "Bash(find:*)",
                              "Write", "Edit", "Bash(*)", "Bash(git log; rm -rf ~)"])
out("deny preserved", p.get("deny") == ["Read(./.env)"])
out("scalar permission key preserved", p.get("defaultMode") == "default")
out("env preserved", d.get("env") == {"MTK_HOOKS_TIER2": "1"})
out("top-level custom key preserved", d.get("teamCustom") == "keep me")
out("$schema preserved and still first", list(d.keys())[0] == "$schema")
PY
)"
while IFS=$'\t' read -r v label; do
  [ -n "$v" ] || continue
  if [ "$v" = "PASS" ]; then pass "$label"; else failc "$label ($(cat "$TMP/bad.json"))"; fi
done <<< "$verdicts"

# 3) --check now exits 0 and still lists the inert leftovers
set +e
check_out="$(bash "$TARGET_SH" --check "$TMP/bad.json" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] && grep -q 'needs a manual decision' <<<"$check_out" \
  && pass "--check exits 0 with only broad leftovers, and lists them" \
  || failc "--check after migration: rc=$rc out=$check_out"

# 4) idempotent: second run leaves bytes identical
cp "$TMP/bad.json" "$TMP/after1.json"
bash "$TARGET_SH" "$TMP/bad.json" >/dev/null
cmp -s "$TMP/bad.json" "$TMP/after1.json" && pass "second run is byte-identical (idempotent)" \
  || failc "second run changed the file"

# 5) a clean file is never rewritten (bytes untouched, even with odd formatting)
printf '{"permissions":{"allow":["Read"]},  "x": 1}\n' > "$TMP/clean.json"
cp "$TMP/clean.json" "$TMP/clean.orig"
bash "$TARGET_SH" "$TMP/clean.json" >/dev/null
cmp -s "$TMP/clean.json" "$TMP/clean.orig" && pass "file without the bad key is left byte-for-byte" \
  || failc "clean file was rewritten"

# 6) narrow-only allowedTools (no allow yet) -> allow created, bad key removed
printf '{"permissions":{"allowedTools":["Bash(pytest:*)","Bash(pytest:*)","Bash(ruff check:*)"]}}\n' > "$TMP/only.json"
bash "$TARGET_SH" "$TMP/only.json" >/dev/null
got="$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["permissions"]; print(json.dumps(p, sort_keys=True))' "$TMP/only.json")"
[ "$got" = '{"allow": ["Bash(pytest:*)", "Bash(ruff check:*)"]}' ] && pass "narrow-only file gets a de-duplicated allow list, no allowedTools left" \
  || failc "narrow-only migration produced $got"

# 7) a non-list allow is an error, never replaced with []
printf '{"permissions":{"allow":"Read","allowedTools":["Bash(pytest:*)"]}}\n' > "$TMP/scalar.json"
cp "$TMP/scalar.json" "$TMP/scalar.orig"
set +e
bash "$TARGET_SH" "$TMP/scalar.json" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] && cmp -s "$TMP/scalar.json" "$TMP/scalar.orig" \
  && pass "non-list allow -> exit 2, file untouched" \
  || failc "non-list allow: expected exit 2 and untouched file, got rc=$rc: $(cat "$TMP/scalar.json")"

# 8) a symlinked settings file stays a symlink; the target is migrated
mkdir -p "$TMP/real" "$TMP/proj"
printf '{"permissions":{"allowedTools":["Bash(mypy:*)"]}}\n' > "$TMP/real/settings.json"
ln -s "$TMP/real/settings.json" "$TMP/proj/settings.json"
bash "$TARGET_SH" "$TMP/proj/settings.json" >/dev/null
if [ -L "$TMP/proj/settings.json" ] && grep -q '"allow"' "$TMP/real/settings.json"; then
  pass "symlink preserved, link target migrated"
else
  failc "symlink replaced or target not migrated"
fi

# 9) strict matching: fullmatch, single spaces only, no npx prefix
python3 - "$TMP/strict.json" <<'PY'
import json, sys
entries = ["Bash(pytest:*)\n", "Bash(pytest\t-q)", "Bash(ruff  check .)", "Bash( pytest)",
           "Bash(npx tsc --noEmit)", "Bash(pytest -q)"]
json.dump({"permissions": {"allowedTools": entries}}, open(sys.argv[1], "w"))
PY
bash "$TARGET_SH" "$TMP/strict.json" >/dev/null
got="$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["permissions"]; print(json.dumps([p.get("allow"), p.get("allowedTools")]))' "$TMP/strict.json")"
[ "$got" = '[["Bash(pytest -q)"], ["Bash(pytest:*)\n", "Bash(pytest\t-q)", "Bash(ruff  check .)", "Bash( pytest)", "Bash(npx tsc --noEmit)"]]' ] \
  && pass "only an exact single-spaced entry activates; trailing newline, tab, double space, npx stay inert" \
  || failc "strict matching produced $got"

# 10) one list: both migrate-settings-permissions.sh and merge-settings.sh read
#     hooks/lib/narrow-permissions.txt (a prefix added there activates in both)
KIT="$TMP/kit"; mkdir -p "$KIT/scripts" "$KIT/hooks/lib"
cp "$TARGET_SH" "$KIT/scripts/"; cp "$REPO_ROOT/hooks/merge-settings.sh" "$KIT/hooks/"
printf 'make check\n' > "$KIT/hooks/lib/narrow-permissions.txt"
printf '{"permissions":{"allowedTools":["Bash(make check)","Bash(pytest:*)"]}}\n' > "$TMP/kit-a.json"
cp "$TMP/kit-a.json" "$TMP/kit-b.json"
bash "$KIT/scripts/migrate-settings-permissions.sh" "$TMP/kit-a.json" >/dev/null
printf '{}\n' > "$TMP/kit-src.json"
bash "$KIT/hooks/merge-settings.sh" "$TMP/kit-src.json" "$TMP/kit-b.json" > "$TMP/kit-b.out" 2>/dev/null
for f in "$TMP/kit-a.json" "$TMP/kit-b.out"; do
  python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["permissions"]; sys.exit(0 if p.get("allow")==["Bash(make check)"] and p.get("allowedTools")==["Bash(pytest:*)"] else 1)' "$f" \
    || failc "$(basename "$f") did not follow the shared narrow list: $(cat "$f")"
done
pass "migrate and merge-settings both follow hooks/lib/narrow-permissions.txt"
rm -f "$KIT/hooks/lib/narrow-permissions.txt"
set +e
bash "$KIT/scripts/migrate-settings-permissions.sh" "$TMP/kit-b.json" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] && pass "missing narrow list -> exit 2, nothing migrated" || failc "missing narrow list: expected exit 2, got $rc"

# 11) missing file: exit 0, nothing created (settings.local.json is optional)
bash "$TARGET_SH" "$TMP/absent.json" >/dev/null 2>&1 && [ ! -e "$TMP/absent.json" ] \
  && pass "missing file is a no-op (exit 0, not created)" \
  || failc "missing file was not a clean no-op"

# 12) unparseable JSON: exit 2, file untouched
printf 'not json' > "$TMP/garbage.json"
set +e
bash "$TARGET_SH" "$TMP/garbage.json" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] && [ "$(cat "$TMP/garbage.json")" = "not json" ] \
  && pass "unparseable JSON -> exit 2, file untouched" \
  || failc "unparseable JSON: expected exit 2 and untouched file, got rc=$rc"

echo ""
if [ ${#FAILS[@]} -gt 0 ]; then
  printf '  FAIL  %s\n' "${FAILS[@]}" >&2
  exit 1
fi
echo "========================================"
echo "TEST PASSED — migrate-settings-permissions activates only narrow entries"
