#!/usr/bin/env bash
set -euo pipefail

# Test: scripts/update-guidelines.sh — the coding-guidelines pin.
# No network: the remote is a local git repo (MTK_GUIDELINES_REMOTE) and the
# raw-file base is a file:// tree laid out as <base>/<sha>/<file>
# (MTK_GUIDELINES_BASE_URL).
#   (a) --fetch with a matching sha256 writes the file
#   (b) --fetch with a sha256 mismatch exits 1 and leaves --out untouched
#   (c) --fetch of a file missing at the pinned SHA exits 1, --out untouched
#   (d) --bump writes the new SHA and new hashes in place (toolkit manifest)
#   (e) --bump when already at HEAD writes nothing
#   (f) --bump with one unfetchable file writes nothing (no partial pin)
#   (g) --bump with an unreachable remote exits 1, writes nothing
#   (h) a pin read from $CLAUDE_PLUGIN_ROOT is never written there; it lands
#       in the repo-local .claude/mtk-version.json, other keys preserved
#   (i) the script never names a branch: no fetch URL is built from `main`

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
UG="$REPO_ROOT/scripts/update-guidelines.sh"

echo "=== update-guidelines Test ==="
[ -x "$UG" ] || { echo "  FAIL  script not executable: $UG" >&2; exit 1; }

declare -a FAILS=()
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILS+=("$1"); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

sha256() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

# --- upstream: a local git repo with two commits ---------------------------
UP="$T/upstream"
mkdir -p "$UP"
git -C "$UP" init -q
git -C "$UP" config user.email t@example.com
git -C "$UP" config user.name T
echo "style v1" > "$UP/CodingStyle.md"
git -C "$UP" add -A && git -C "$UP" commit -qm v1
OLD_SHA="$(git -C "$UP" rev-parse HEAD)"
echo "style v2" > "$UP/CodingStyle.md"
git -C "$UP" commit -qam v2
NEW_SHA="$(git -C "$UP" rev-parse HEAD)"

RAW="$T/raw"
for sha in "$OLD_SHA" "$NEW_SHA"; do
  mkdir -p "$RAW/$sha"
  git -C "$UP" show "$sha:CodingStyle.md" > "$RAW/$sha/CodingStyle.md"
done
OLD_HASH="$(sha256 "$RAW/$OLD_SHA/CodingStyle.md")"
NEW_HASH="$(sha256 "$RAW/$NEW_SHA/CodingStyle.md")"

export MTK_GUIDELINES_REMOTE="$UP"
export MTK_GUIDELINES_BASE_URL="file://$RAW"
unset CLAUDE_PLUGIN_ROOT

write_manifest() { # <path> <sha> <hash>
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
{
  "version": "9.9.9",
  "coding-guidelines": {
    "repo": "moberghr/coding-guidelines",
    "sha": "$2",
    "files": { "CodingStyle.md": "sha256:$3" }
  }
}
EOF
}
pin_sha() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["coding-guidelines"]["sha"])' "$1"; }

# --- (a) fetch, matching hash ----------------------------------------------
W="$T/a"; mkdir -p "$W"; write_manifest "$W/.claude/manifest.json" "$OLD_SHA" "$OLD_HASH"
if (cd "$W" && bash "$UG" --fetch CodingStyle.md --out out/cg.md >/dev/null 2>&1) \
   && [ "$(cat "$W/out/cg.md")" = "style v1" ]; then pass "(a) fetch verifies and writes"
else fail "(a) fetch with matching sha256 did not write the file"; fi

# --- (b) fetch, mismatched hash --------------------------------------------
W="$T/b"; mkdir -p "$W/out"; write_manifest "$W/.claude/manifest.json" "$OLD_SHA" "$NEW_HASH"
echo "keep" > "$W/out/cg.md"
rc=0; (cd "$W" && bash "$UG" --fetch CodingStyle.md --out out/cg.md >/dev/null 2>&1) || rc=$?
if [ "$rc" = 1 ] && [ "$(cat "$W/out/cg.md")" = "keep" ]; then pass "(b) sha256 mismatch fails closed"
else fail "(b) mismatch: rc=$rc, out=$(cat "$W/out/cg.md")"; fi

# --- (c) fetch, file absent at SHA -----------------------------------------
W="$T/c"; mkdir -p "$W"; write_manifest "$W/.claude/manifest.json" "$(printf 'a%.0s' {1..40})" "$OLD_HASH"
rc=0; (cd "$W" && bash "$UG" --fetch CodingStyle.md --out out/cg.md >/dev/null 2>&1) || rc=$?
if [ "$rc" = 1 ] && [ ! -e "$W/out/cg.md" ]; then pass "(c) failed fetch writes nothing"
else fail "(c) failed fetch: rc=$rc"; fi

# --- (d) bump in place -----------------------------------------------------
W="$T/d"; mkdir -p "$W"; write_manifest "$W/.claude/manifest.json" "$OLD_SHA" "$OLD_HASH"
out="$(cd "$W" && bash "$UG" --bump 2>&1)" || true
got_hash="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["coding-guidelines"]["files"]["CodingStyle.md"])' "$W/.claude/manifest.json")"
if [ "$(pin_sha "$W/.claude/manifest.json")" = "$NEW_SHA" ] && [ "$got_hash" = "sha256:$NEW_HASH" ] \
   && grep -q '"version": "9.9.9"' "$W/.claude/manifest.json" && [[ "$out" == *"$OLD_SHA -> $NEW_SHA"* ]]; then
  pass "(d) bump writes new sha and hash in place"
else fail "(d) bump: $out"; fi

# --- (e) already at HEAD ---------------------------------------------------
before="$(sha256 "$W/.claude/manifest.json")"
out="$(cd "$W" && bash "$UG" --bump 2>&1)" || true
if [[ "$out" == *"Already at HEAD"* ]] && [ "$before" = "$(sha256 "$W/.claude/manifest.json")" ]; then
  pass "(e) already current writes nothing"
else fail "(e) already-at-HEAD: $out"; fi

# --- (f) one unfetchable file ----------------------------------------------
W="$T/f"; mkdir -p "$W/.claude"
cat > "$W/.claude/manifest.json" <<EOF
{ "coding-guidelines": { "repo": "x/y", "sha": "$OLD_SHA",
  "files": { "CodingStyle.md": "sha256:$OLD_HASH", "Missing.md": "sha256:00" } } }
EOF
before="$(sha256 "$W/.claude/manifest.json")"
rc=0; (cd "$W" && bash "$UG" --bump >/dev/null 2>&1) || rc=$?
if [ "$rc" = 1 ] && [ "$before" = "$(sha256 "$W/.claude/manifest.json")" ]; then pass "(f) partial fetch writes no pin"
else fail "(f) partial fetch: rc=$rc"; fi

# --- (g) unreachable remote ------------------------------------------------
W="$T/g"; mkdir -p "$W"; write_manifest "$W/.claude/manifest.json" "$OLD_SHA" "$OLD_HASH"
before="$(sha256 "$W/.claude/manifest.json")"
rc=0; (cd "$W" && MTK_GUIDELINES_REMOTE="$T/nope" bash "$UG" --bump >/dev/null 2>&1) || rc=$?
if [ "$rc" = 1 ] && [ "$before" = "$(sha256 "$W/.claude/manifest.json")" ]; then pass "(g) unreachable remote writes nothing"
else fail "(g) unreachable remote: rc=$rc"; fi

# --- (h) plugin-cache pin -> repo-local mtk-version.json -------------------
PLUG="$T/plugin"; write_manifest "$PLUG/.claude/manifest.json" "$OLD_SHA" "$OLD_HASH"
plug_before="$(sha256 "$PLUG/.claude/manifest.json")"
W="$T/h"; mkdir -p "$W/.claude"
echo '{ "version": "1.2.3", "installed": "2026-01-01" }' > "$W/.claude/mtk-version.json"
(cd "$W" && CLAUDE_PLUGIN_ROOT="$PLUG" bash "$UG" --bump >/dev/null 2>&1) || true
if [ "$plug_before" = "$(sha256 "$PLUG/.claude/manifest.json")" ] \
   && [ "$(pin_sha "$W/.claude/mtk-version.json")" = "$NEW_SHA" ] \
   && grep -q '"installed": "2026-01-01"' "$W/.claude/mtk-version.json"; then
  pass "(h) plugin cache untouched; pin written repo-local"
else fail "(h) plugin-cache write rule"; fi

# --- (i) never a branch name in the fetch URL ------------------------------
if grep -nE '/(main|master)/|HEAD/' "$UG" >/dev/null; then fail "(i) script builds a branch-name fetch URL"
else pass "(i) fetch URLs are SHA-addressed only"; fi

echo
if [ "${#FAILS[@]}" -eq 0 ]; then echo "All update-guidelines tests passed."; exit 0; fi
echo "${#FAILS[@]} failure(s)"; exit 1
