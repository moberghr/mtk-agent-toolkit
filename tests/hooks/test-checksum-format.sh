#!/usr/bin/env bash
set -euo pipefail

# generate-checksums.sh writes "<hash><space><marker><path>". The marker is a space in text
# mode and '*' in binary mode, and which one you get is a property of the hashing build
# rather than of the script — the identical generator produced both forms on two machines
# in this project. That cost twice: a whole-file merge conflict when the format flipped,
# and a --verify pass that could not read the '*' form at all (every entry counted MISSING,
# so it exited 1 without ever comparing a hash).
#
# These cases pin the fixed behaviour: output is always the space marker, and --verify
# reads both forms so manifests written before the fix still verify.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GEN="$REPO_ROOT/scripts/generate-checksums.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
expect() {
  local label="$1" want="$2" got="$3"
  if [ "$got" != "$want" ]; then
    printf 'FAIL: %s — expected %s, got %s\n' "$label" "$want" "$got" >&2
    fails=$((fails + 1))
  fi
}

# A throwaway repo shaped like a plugin clone. The generator resolves its root from its own
# location, so copying it under $TMP/scripts makes $TMP the root and leaves the real
# checksums.sha256 untouched.
mkdir -p "$TMP/scripts" "$TMP/.claude" "$TMP/.claude-plugin" "$TMP/payload"
cp "$GEN" "$TMP/scripts/generate-checksums.sh"
printf 'alpha\n' > "$TMP/payload/a.txt"
printf 'beta\n'  > "$TMP/payload/b.txt"
cat > "$TMP/.claude/manifest.json" <<'EOF'
{
  "version": "9.9.9",
  "files": {
    "payload/a.txt": { "source": "payload/a.txt", "target": "payload/a.txt", "action": "sync", "description": "fixture" },
    "payload/b.txt": { "source": "payload/b.txt", "target": "payload/b.txt", "action": "sync", "description": "fixture" }
  }
}
EOF
printf '{ "version": "9.9.9" }\n' > "$TMP/.claude-plugin/plugin.json"

# 1. Generation emits the space marker, never the binary '*' — on any hashing build.
bash "$TMP/scripts/generate-checksums.sh" >/dev/null 2>&1
star_lines="$(grep -c ' \*' "$TMP/checksums.sha256" || true)"
expect "no binary '*' marker in generated output" 0 "$star_lines"

# 2. A freshly generated manifest verifies clean.
verify_rc=0
bash "$TMP/scripts/generate-checksums.sh" --verify --quiet >/dev/null 2>&1 || verify_rc=$?
expect "round-trip verify" 0 "$verify_rc"

# 3. The count is real — the summary must report the files it actually checked, not zero.
#    Four: the two payload files plus manifest.json and plugin.json, which the generator
#    always hashes on top of whatever the manifest lists.
checked="$(bash "$TMP/scripts/generate-checksums.sh" --verify 2>&1 | sed -n 's/^checksums: \([0-9]*\) checked.*/\1/p')"
expect "verify checked every listed file" 4 "$checked"

# 4. A legacy '*'-marked manifest still verifies. This is the regression: before the fix the
#    star was read as part of the filename and every entry was reported MISSING.
sed 's/^\([0-9a-fA-F]*\)  /\1 */' "$TMP/checksums.sha256" > "$TMP/star.tmp"
mv "$TMP/star.tmp" "$TMP/checksums.sha256"
expect "fixture really is star-format" 4 "$(grep -c ' \*' "$TMP/checksums.sha256" || true)"
star_rc=0
bash "$TMP/scripts/generate-checksums.sh" --verify --quiet >/dev/null 2>&1 || star_rc=$?
expect "star-format manifest verifies" 0 "$star_rc"
star_missing="$(bash "$TMP/scripts/generate-checksums.sh" --verify 2>&1 | sed -n 's/.*, \([0-9]*\) missing.*/\1/p')"
expect "star-format reports nothing missing" 0 "$star_missing"

# 5. Verification still catches real tampering — the parser fix must not make it permissive.
printf 'tampered\n' > "$TMP/payload/a.txt"
tamper_rc=0
bash "$TMP/scripts/generate-checksums.sh" --verify --quiet >/dev/null 2>&1 || tamper_rc=$?
expect "tampered payload fails verify" 1 "$tamper_rc"
# `|| true`: this verify is meant to fail, and pipefail would otherwise abort the suite here.
tamper_bad="$(bash "$TMP/scripts/generate-checksums.sh" --verify 2>&1 | sed -n 's/.*checked, \([0-9]*\) mismatched.*/\1/p' || true)"
expect "tamper reported as mismatch, not missing" 1 "$tamper_bad"

# 6. A genuinely absent file is still reported missing and still fails.
rm -f "$TMP/payload/b.txt"
gone_rc=0
bash "$TMP/scripts/generate-checksums.sh" --verify --quiet >/dev/null 2>&1 || gone_rc=$?
expect "deleted payload fails verify" 1 "$gone_rc"

if [ "$fails" -ne 0 ]; then
  printf '%s check(s) failed\n' "$fails" >&2
  exit 1
fi

echo "PASS: test-checksum-format.sh"
