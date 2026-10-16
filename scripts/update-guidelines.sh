#!/usr/bin/env bash
set -euo pipefail

# update-guidelines.sh — the coding-guidelines pin, fetched and bumped by SHA.
#
# The external guidelines (moberghr/coding-guidelines) are pinned by commit SHA
# plus a sha256 per file. Nothing here ever fetches a branch name: every fetch
# is <base>/<40-char sha>/<file>, and every fetched byte is hashed before use.
#
# Usage:
#   bash scripts/update-guidelines.sh --fetch <file> --out <path>
#       Fetch <file> (e.g. CodingStyle.md) at the pinned SHA, verify its sha256
#       against the pin, then move it to <path>. On any failure <path> is left
#       untouched and the exit code is 1 (fail closed).
#   bash scripts/update-guidelines.sh --bump
#       Resolve the remote HEAD to a SHA, fetch every pinned file at that SHA,
#       hash them all, and only then write the new pin. Any failed fetch writes
#       nothing. Prints old -> new SHA and each changed hash.
#   bash scripts/update-guidelines.sh --show
#       Print the pin file in use, its SHA and its files.
#
# Pin resolution (read): ./.claude/mtk-version.json when it carries a
# `coding-guidelines` block (a repo that pinned its own guidelines), else
# ./.claude/manifest.json (the toolkit repo itself), else
# $CLAUDE_PLUGIN_ROOT/.claude/manifest.json.
# Pin write (--bump): the file it was read from, except that a pin read from
# the plugin cache is never written there — it goes to the repo-local
# ./.claude/mtk-version.json `coding-guidelines` block (other keys untouched).
#
# Environment (test seams; defaults hit GitHub):
#   MTK_GUIDELINES_REMOTE    git remote for `git ls-remote <remote> HEAD`
#   MTK_GUIDELINES_BASE_URL  raw-file base; a file is fetched from
#                            "$BASE/<sha>/<file>" (file:// works)
#
# Exit codes: 0 ok / already current, 1 fetch, hash or remote failure,
# 2 usage or missing pin.

MODE=""
FETCH_FILE=""
OUT=""

usage() {
  sed -n '4,36p' "$0" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --fetch) MODE=fetch; FETCH_FILE="${2:-}"; shift 2 || usage ;;
    --out) OUT="${2:-}"; shift 2 || usage ;;
    --bump) MODE=bump; shift ;;
    --show) MODE=show; shift ;;
    -h|--help) usage ;;
    *) echo "update-guidelines: unknown argument '$1'" >&2; usage ;;
  esac
done

[ -n "$MODE" ] || usage
command -v python3 >/dev/null 2>&1 || { echo "update-guidelines: python3 is required" >&2; exit 2; }

has_pin() {
  [ -f "$1" ] && python3 - "$1" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
cg = d.get("coding-guidelines")
sys.exit(0 if isinstance(cg, dict) and cg.get("sha") and isinstance(cg.get("files"), dict) else 1)
PY
}

PIN=""
PIN_KIND=""
if has_pin ".claude/mtk-version.json"; then
  PIN=".claude/mtk-version.json"; PIN_KIND=local
elif has_pin ".claude/manifest.json"; then
  PIN=".claude/manifest.json"; PIN_KIND=local
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && has_pin "${CLAUDE_PLUGIN_ROOT}/.claude/manifest.json"; then
  PIN="${CLAUDE_PLUGIN_ROOT}/.claude/manifest.json"; PIN_KIND=plugin
else
  echo "update-guidelines: no coding-guidelines pin found (.claude/mtk-version.json, .claude/manifest.json, \$CLAUDE_PLUGIN_ROOT/.claude/manifest.json)" >&2
  exit 2
fi

pin_field() {
  python3 - "$PIN" "$1" <<'PY'
import json, sys
cg = json.load(open(sys.argv[1]))["coding-guidelines"]
key = sys.argv[2]
if key == "files":
    for name, digest in cg["files"].items():
        print(f"{name}\t{digest.split(':', 1)[-1]}")
else:
    print(cg.get(key, ""))
PY
}

REPO="$(pin_field repo)"
[ -n "$REPO" ] || REPO="moberghr/coding-guidelines"
SHA="$(pin_field sha)"
BASE="${MTK_GUIDELINES_BASE_URL:-https://raw.githubusercontent.com/$REPO}"
REMOTE="${MTK_GUIDELINES_REMOTE:-https://github.com/$REPO}"

valid_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
valid_name() { [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$1" != *..* ]] && [[ "$1" != /* ]]; }

sha256_of() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# fetch_at <sha> <file> <dest>; curl -f so an HTTP error page is a failure, not content.
fetch_at() {
  curl -fsSL "$BASE/$1/$2" -o "$3" 2>/dev/null
}

valid_sha "$SHA" || { echo "update-guidelines: pinned sha in $PIN is not a 40-char hex SHA ('$SHA')" >&2; exit 2; }

case "$MODE" in
  show)
    echo "pin: $PIN"
    echo "repo: $REPO"
    echo "sha: $SHA"
    pin_field files | while IFS=$'\t' read -r name digest; do echo "file: $name sha256:$digest"; done
    ;;

  fetch)
    [ -n "$FETCH_FILE" ] && [ -n "$OUT" ] || { echo "update-guidelines: --fetch needs <file> and --out <path>" >&2; exit 2; }
    valid_name "$FETCH_FILE" || { echo "update-guidelines: refusing file name '$FETCH_FILE'" >&2; exit 2; }
    EXPECTED="$(pin_field files | awk -F'\t' -v f="$FETCH_FILE" '$1 == f { print $2 }')"
    [ -n "$EXPECTED" ] || { echo "update-guidelines: '$FETCH_FILE' is not pinned in $PIN" >&2; exit 2; }
    if ! fetch_at "$SHA" "$FETCH_FILE" "$WORK/file"; then
      echo "update-guidelines: fetch failed for $FETCH_FILE@$SHA — $OUT left untouched" >&2
      exit 1
    fi
    ACTUAL="$(sha256_of "$WORK/file")"
    if [ "$ACTUAL" != "$EXPECTED" ]; then
      echo "update-guidelines: sha256 mismatch for $FETCH_FILE@$SHA: got $ACTUAL expected $EXPECTED — $OUT left untouched" >&2
      exit 1
    fi
    mkdir -p "$(dirname "$OUT")"
    mv "$WORK/file" "$OUT"
    echo "fetched $FETCH_FILE@$SHA -> $OUT (sha256 verified)"
    ;;

  bump)
    NEW_SHA="$(git ls-remote "$REMOTE" HEAD 2>/dev/null | awk 'NR==1 { print $1 }')" || NEW_SHA=""
    if ! valid_sha "$NEW_SHA"; then
      echo "update-guidelines: git ls-remote did not return a 40-char SHA (got '$NEW_SHA') — unreachable remote; nothing written" >&2
      exit 1
    fi
    if [ "$NEW_SHA" = "$SHA" ]; then
      echo "Already at HEAD ($SHA). Nothing to do."
      exit 0
    fi
    # Hash every file before writing anything: no partial pin updates.
    : > "$WORK/hashes"
    while IFS=$'\t' read -r name digest; do
      valid_name "$name" || { echo "update-guidelines: refusing pinned file name '$name'" >&2; exit 2; }
      if ! fetch_at "$NEW_SHA" "$name" "$WORK/f"; then
        echo "update-guidelines: fetch failed for $name@$NEW_SHA — pin left untouched" >&2
        exit 1
      fi
      printf '%s\t%s\t%s\n' "$name" "$digest" "$(sha256_of "$WORK/f")" >> "$WORK/hashes"
    done < <(pin_field files)

    TARGET="$PIN"
    [ "$PIN_KIND" = plugin ] && TARGET=".claude/mtk-version.json"
    python3 - "$TARGET" "$REPO" "$NEW_SHA" "$WORK/hashes" <<'PY'
import json, os, sys
target, repo, sha, hashes = sys.argv[1:5]
data = json.load(open(target)) if os.path.exists(target) else {}
cg = data.get("coding-guidelines") if isinstance(data.get("coding-guidelines"), dict) else {}
cg["repo"] = cg.get("repo") or repo
cg["sha"] = sha
files = {}
for line in open(hashes):
    name, _old, new = line.rstrip("\n").split("\t")
    files[name] = f"sha256:{new}"
cg["files"] = files
data["coding-guidelines"] = cg
os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
tmp = target + ".tmp"
with open(tmp, "w") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
os.replace(tmp, target)
PY
    echo "coding-guidelines: $SHA -> $NEW_SHA"
    while IFS=$'\t' read -r name old new; do
      if [ "$old" = "$new" ]; then echo "  $name: unchanged"; else echo "  $name: sha256 $old -> $new"; fi
    done < "$WORK/hashes"
    echo "Guidelines pin updated in $TARGET."
    ;;
esac
