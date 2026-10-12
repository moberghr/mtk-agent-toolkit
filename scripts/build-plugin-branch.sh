#!/usr/bin/env bash
set -euo pipefail

# build-plugin-branch.sh — Build the slim `plugin` release branch for MTK.
#
# The Claude plugin directory times out validating the whole repo, so each
# release also publishes a branch holding only the runtime payload. This script
# exports the tree of a source ref, drops dev-only paths (tests/, evals/,
# examples/, .github/, docs/specs/, docs/plans/ and every docs/ file the
# manifest does not list), trims .claude/manifest.json to the files it kept,
# regenerates checksums.sha256 with the exported tree's own
# scripts/generate-checksums.sh, and appends one commit to the target branch.
#
# It never touches the caller's branch, index or working tree (the export goes
# to a temp dir and the tree is built through a temporary index), never pushes,
# and never forces: the new commit's parent is the local branch tip, else the
# refs/remotes/origin/<branch> tip, else none (first build). An unchanged tree
# is a no-op. The release workflow pushes the branch.
#
# Usage:
#   bash scripts/build-plugin-branch.sh [--source <ref>] [--branch <name>] [--repo <dir>]
#     --source <ref>   ref to export (default: HEAD — uncommitted changes are not included)
#     --branch <name>  branch to append to (default: plugin)
#     --repo <dir>     repository (default: git toplevel of the current directory)
#     -h, --help       print this header
#
# Exit codes:
#   0  commit created, or branch already up to date
#   1  build failed (checksums did not verify, or the branch moved during the build)
#   2  usage or environment error (bad args, not a repo, missing python3/manifest/plugin.json/generate-checksums.sh)

die() { echo "ERROR: $1" >&2; exit "${2:-2}"; }

repo=""
source_ref="HEAD"
branch="plugin"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   [ $# -ge 2 ] || die "--repo needs a value"; repo="$2"; shift 2 ;;
    --source) [ $# -ge 2 ] || die "--source needs a value"; source_ref="$2"; shift 2 ;;
    --branch) [ $# -ge 2 ] || die "--branch needs a value"; branch="$2"; shift 2 ;;
    -h|--help)
      # Render the full header comment block (first '# ' line down to the first
      # non-comment line) — never slice by absolute line count.
      awk '/^# /{f=1} f{ if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
      exit 0
      ;;
    *) die "Unknown arg: $1 (see --help)" ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 is required (manifest trimming)"

if [ -z "$repo" ]; then
  repo="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository — pass --repo <dir>"
else
  repo="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || die "--repo is not a git work tree: $repo"
fi
git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "invalid branch name: $branch"
src_commit="$(git -C "$repo" rev-parse -q --verify "$source_ref^{commit}")" || die "--source does not name a commit: $source_ref"
src_short="$(git -C "$repo" rev-parse --short "$src_commit")"

tmp="$(mktemp -d -t mtk-plugin-branch-XXXXXX)"
cleanup() { if [ -n "${tmp:-}" ]; then rm -rf "$tmp"; fi; }
trap cleanup EXIT
tree_dir="$tmp/tree"            # exported payload — the temporary work tree
index_file="$tmp/index/index"   # does not exist yet: git starts from an empty index
mkdir -p "$tree_dir" "$tmp/index"

# --- export ------------------------------------------------------------------
# Pin line endings so a runner-level core.autocrlf/eol setting cannot rewrite the payload.
git -C "$repo" -c core.autocrlf=false -c core.eol=lf archive "$src_commit" | tar -x -C "$tree_dir"

manifest="$tree_dir/.claude/manifest.json"
plugin_json="$tree_dir/.claude-plugin/plugin.json"
[ -f "$manifest" ]    || die "$source_ref has no .claude/manifest.json"
[ -f "$plugin_json" ] || die "$source_ref has no .claude-plugin/plugin.json"
[ -f "$tree_dir/scripts/generate-checksums.sh" ] || die "$source_ref has no scripts/generate-checksums.sh — cannot regenerate checksums"

# --- drop dev-only paths and unlisted docs -----------------------------------
for d in tests evals examples .github docs/specs docs/plans; do
  rm -rf "${tree_dir:?}/$d"
done

sources_file="$tmp/sources.txt"
python3 - "$manifest" > "$sources_file" <<'PY'
import json, sys
files = json.load(open(sys.argv[1], encoding="utf-8")).get("files", {})
entries = files.values() if isinstance(files, dict) else files
for e in entries:
    if isinstance(e, dict) and isinstance(e.get("source"), str):
        print(e["source"])
PY

if [ -d "$tree_dir/docs" ]; then
  docs_list="$tmp/docs.txt"
  ( cd "$tree_dir" && find docs \( -type f -o -type l \) ) > "$docs_list"
  while IFS= read -r rel; do
    grep -qxF -- "$rel" "$sources_file" || rm -f "$tree_dir/$rel"
  done < "$docs_list"
fi
find "$tree_dir" -mindepth 1 -depth -type d -empty -exec rmdir {} \;

# --- trim manifest to the files that remain ----------------------------------
python3 - "$manifest" "$tree_dir" <<'PY'
import json, os, sys
path, root = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    m = json.load(fh)
files = m.get("files", {})
present = lambda e: isinstance(e, dict) and isinstance(e.get("source"), str) \
    and os.path.lexists(os.path.join(root, e["source"]))
if isinstance(files, dict):
    m["files"] = {k: v for k, v in files.items() if present(v)}
else:
    m["files"] = [e for e in files if present(e)]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(m, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY

# --- regenerate and verify checksums with the exported tree's own script -----
if ! gen_out="$(bash "$tree_dir/scripts/generate-checksums.sh" 2>&1)"; then
  die "generate-checksums.sh failed on the exported tree: $gen_out" 1
fi
if ! verify_out="$(bash "$tree_dir/scripts/generate-checksums.sh" --verify --quiet 2>&1)"; then
  die "checksums do not verify on the exported tree: $verify_out" 1
fi

# --- build the tree object through a temporary index -------------------------
GIT_INDEX_FILE="$index_file" git -C "$repo" -c core.autocrlf=false --work-tree="$tree_dir" add -A -f
tree="$(GIT_INDEX_FILE="$index_file" git -C "$repo" write-tree)"

# --- parent: local tip, else origin tip, else root commit --------------------
local_tip="$(git -C "$repo" rev-parse -q --verify "refs/heads/$branch^{commit}" || true)"
parent="$local_tip"
if [ -z "$parent" ]; then
  parent="$(git -C "$repo" rev-parse -q --verify "refs/remotes/origin/$branch^{commit}" || true)"
fi

if [ -n "$parent" ] && [ "$(git -C "$repo" rev-parse "$parent^{tree}")" = "$tree" ]; then
  # Parent came from origin: create the local branch at it so the caller's push
  # of refs/heads/$branch is a no-op rather than "src refspec does not match any".
  if [ -z "$local_tip" ]; then
    git -C "$repo" update-ref -m "build-plugin-branch: track origin/$branch" "refs/heads/$branch" "$parent" "" \
      || die "refs/heads/$branch moved during the build (created by another writer) — re-run" 1
  fi
  echo "$branch branch already up to date ($(git -C "$repo" rev-parse --short "$parent"))"
  exit 0
fi

read_plugin_field() {
  python3 - "$plugin_json" "$1" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2], "?"))
PY
}
name="$(read_plugin_field name)"
version="$(read_plugin_field version)"

msg="release: $name v$version (from $src_short)"
if [ -n "$parent" ]; then
  commit="$(git -C "$repo" commit-tree "$tree" -p "$parent" -m "$msg")"
else
  commit="$(git -C "$repo" commit-tree "$tree" -m "$msg")"
fi

# Old-value guard: the local ref must still be at the tip we built on (or still
# absent, when the parent came from origin or there was none) — a concurrent
# move fails here instead of being clobbered.
if ! git -C "$repo" update-ref -m "build-plugin-branch: $msg" "refs/heads/$branch" "$commit" "$local_tip"; then
  die "refs/heads/$branch moved during the build — re-run" 1
fi

count="$(git -C "$repo" ls-tree -r --name-only "$commit" | wc -l | tr -d ' ')"
echo "$branch -> $commit ($msg)"
echo "files: $count"
echo "$gen_out"
echo "$verify_out"
