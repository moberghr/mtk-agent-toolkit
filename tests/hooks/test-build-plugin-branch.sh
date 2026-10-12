#!/usr/bin/env bash
set -euo pipefail

# build-plugin-branch.sh builds the slim `plugin` release branch the Claude
# directory tracks (spec 2026-10-01-plugin-release-branch, SC1-SC4).
#
# WHY. The directory portal times out validating the whole repo; a tree holding
# only the runtime payload validates. The script must drop dev-only paths and
# unlisted docs, trim the manifest to what it kept, regenerate checksums that
# verify clean, append (never force) one commit per changed release, and leave
# the caller's branch, index and working tree exactly as they were. It must
# build exactly the --source it is given (never the working tree), refuse to
# clobber a branch another writer moved, fail when checksums cannot be produced
# or do not verify, and reject bad usage with exit 2 before touching any ref.
#
# Every ref is created in throwaway fixture repos under one mktemp sandbox.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD="$REPO_ROOT/scripts/build-plugin-branch.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; }

SBX="$(mktemp -d -t mtk-plugin-branch-XXXXXX)"
trap 'rm -rf "$SBX"' EXIT

export GIT_AUTHOR_NAME="Fixture" GIT_AUTHOR_EMAIL="fixture@example.invalid"
export GIT_COMMITTER_NAME="Fixture" GIT_COMMITTER_EMAIL="fixture@example.invalid"
# Isolate fixture git from the developer's config (commit signing, hooksPath, autocrlf).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

[ -f "$BUILD" ] || fail "script under test missing: $BUILD"

# make_fixture <dir>: a committed plugin-shaped repo on branch main.
# The manifest has a key that differs from its source (skills/a -> hooks/a.sh),
# top-level fields beside `files` (including a nested coding-guidelines.files
# map and a protected list), and a stale committed checksums.sha256 that lists
# a dev-only file.
make_fixture() {
  local fx="$1"
  mkdir -p "$fx"
  git -C "$fx" init -q
  git -C "$fx" symbolic-ref HEAD refs/heads/main
  mkdir -p "$fx/.claude-plugin" "$fx/.claude" "$fx/hooks" "$fx/docs/specs" "$fx/docs/plans" \
           "$fx/tests" "$fx/evals" "$fx/examples" "$fx/.github/workflows" "$fx/scripts"
  printf '{"name":"fx","version":"1.2.3"}\n' > "$fx/.claude-plugin/plugin.json"
  printf '# fx\n' > "$fx/README.md"
  printf '#!/usr/bin/env bash\necho a\n' > "$fx/hooks/a.sh"; chmod +x "$fx/hooks/a.sh"
  printf 'keep\n' > "$fx/docs/keep.md"
  printf 'drop\n' > "$fx/docs/drop.md"
  printf 'spec\n' > "$fx/docs/specs/s.md"
  printf 'plan\n' > "$fx/docs/plans/p.md"
  printf 'echo t\n' > "$fx/tests/t.sh"
  printf '{}\n' > "$fx/evals/e.json"
  printf 'x\n' > "$fx/examples/x.md"
  printf 'on: push\n' > "$fx/.github/workflows/w.yml"
  cp "$REPO_ROOT/scripts/generate-checksums.sh" "$fx/scripts/generate-checksums.sh"
  printf '# MTK release checksum manifest v1.2.3\n%064d  tests/t.sh\n%064d  evals/e.json\n' 0 0 \
    > "$fx/checksums.sha256"
  python3 - "$fx/.claude/manifest.json" <<'PY'
import json, sys
keyed = {"README.md": "README.md", "skills/a": "hooks/a.sh", "docs/keep.md": "docs/keep.md",
         "tests/t.sh": "tests/t.sh", "evals/e.json": "evals/e.json",
         "examples/x.md": "examples/x.md", ".github/workflows/w.yml": ".github/workflows/w.yml",
         "scripts/generate-checksums.sh": "scripts/generate-checksums.sh"}
files = {k: {"source": s, "target": s, "action": "sync", "description": "fixture file " + s}
         for k, s in keyed.items()}
m = {"version": "1.2.3", "source": "https://example.invalid/fx",
     "coding-guidelines": {"repo": "example/guidelines", "sha": "abc123",
                           "files": {"CodingStyle.md": "sha256:deadbeef"}},
     "files": files,
     "protected": ["CLAUDE.md", "AGENTS.md"]}
with open(sys.argv[1], "w") as fh:
    json.dump(m, fh, indent=2)
    fh.write("\n")
PY
  git -C "$fx" add -A
  git -C "$fx" commit -q -m "fixture"
}

# run_capture <cmd...>: sets RC, OUT, ERR without tripping set -e.
run_capture() {
  RC=0
  "$@" >"$SBX/out.txt" 2>"$SBX/err.txt" || RC=$?
  OUT="$(cat "$SBX/out.txt")"
  ERR="$(cat "$SBX/err.txt")"
}

refs_of() { git -C "$1" for-each-ref --format='%(refname) %(objectname)'; }

# A path with a space proves every path the script handles is quoted.
FX="$SBX/fixture repo"
make_fixture "$FX"

run_build() { bash "$BUILD" --repo "$FX" "$@"; }
head_sha() { git -C "$FX" rev-parse HEAD; }
blob_of() { git -C "$FX" show "$1:$2"; }

assert_untouched() {
  local before="$1" label="$2" branch status
  branch="$(git -C "$FX" symbolic-ref --short HEAD)"
  [ "$branch" = "main" ] || fail "$label: current branch changed to '$branch'"
  [ "$(head_sha)" = "$before" ] || fail "$label: HEAD moved"
  status="$(git -C "$FX" status --porcelain)"
  [ -z "$status" ] || fail "$label: working tree/index dirty: $status"
}

# --- first build -------------------------------------------------------------
before="$(head_sha)"
src1_short="$(git -C "$FX" rev-parse --short HEAD)"
out="$(run_build 2>&1)" || fail "first build exited non-zero. Output: $out"
assert_untouched "$before" "first build"

git -C "$FX" rev-parse -q --verify refs/heads/plugin >/dev/null || fail "plugin branch not created. Output: $out"
parents="$(git -C "$FX" rev-list --parents -n 1 plugin)"
[ "$(printf '%s\n' "$parents" | awk '{print NF}')" = "1" ] || fail "first plugin commit is not a root commit: $parents"
msg="$(git -C "$FX" log -1 --format=%B plugin)"
[ "$msg" = "release: fx v1.2.3 (from $src1_short)" ] || fail "unexpected first commit message: '$msg'"
ok "first build is a root commit with message 'release: fx v1.2.3 (from $src1_short)'"

tree_list="$(git -C "$FX" ls-tree -r --name-only plugin)"
has() { grep -qxF "$1" <<<"$tree_list"; }
has_prefix() { grep -q "^$1" <<<"$tree_list"; }

for p in tests/ evals/ examples/ .github/ docs/specs/ docs/plans/; do
  ! has_prefix "$p" || fail "plugin tree still contains $p"
done
! has docs/drop.md || fail "plugin tree still contains unlisted docs/drop.md"
for p in docs/keep.md hooks/a.sh README.md scripts/generate-checksums.sh; do
  has "$p" || fail "plugin tree is missing $p"
done
ok "SC1: dev-only paths and unlisted docs dropped; listed docs, hooks, README, checksum script kept"

[ "$(git -C "$FX" ls-tree plugin hooks/a.sh | awk '{print $1}')" = "100755" ] \
  || fail "hooks/a.sh lost its executable bit on the plugin branch"
ok "executable bit preserved on the plugin branch"

sums="$(blob_of plugin checksums.sha256)"
for p in tests/t.sh evals/e.json; do
  ! grep -q "  $p\$" <<<"$sums" || fail "plugin checksums.sha256 still lists $p: $sums"
done
for p in hooks/a.sh .claude/manifest.json; do
  grep -q "  $p\$" <<<"$sums" || fail "plugin checksums.sha256 does not list $p: $sums"
done
ok "stale committed checksums.sha256 replaced: no dev-only entries, runtime files listed"

# --- SC2: manifest trimmed, checksums verify clean ---------------------------
X="$SBX/extract one"; mkdir -p "$X"
git -C "$FX" archive plugin | tar -x -C "$X"
missing_src="$(python3 - "$X" <<'PY'
import json, os, sys
root = sys.argv[1]
m = json.load(open(os.path.join(root, ".claude/manifest.json")))
f = m["files"]
entries = f.values() if isinstance(f, dict) else f
for e in entries:
    s = e["source"]
    if not os.path.isfile(os.path.join(root, s)) or s.startswith(("tests/", "evals/")):
        print(s)
PY
)"
[ -z "$missing_src" ] || fail "trimmed manifest still lists absent/dev sources: $missing_src"

entries="$(python3 - "$X/.claude/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for k in sorted(m["files"]):
    print(k + "=" + m["files"][k]["source"])
PY
)"
expected_entries="README.md=README.md
docs/keep.md=docs/keep.md
scripts/generate-checksums.sh=scripts/generate-checksums.sh
skills/a=hooks/a.sh"
[ "$entries" = "$expected_entries" ] || fail "trimmed manifest entries differ. Got:
$entries
Expected:
$expected_entries"
ok "W3/W5: trimmed manifest has exactly 4 entries, key skills/a still maps to source hooks/a.sh"

git -C "$FX" show HEAD:.claude/manifest.json > "$SBX/manifest.orig.json"
top_diff="$(python3 - "$X/.claude/manifest.json" "$SBX/manifest.orig.json" <<'PY'
import json, sys
new = json.load(open(sys.argv[1]))
old = json.load(open(sys.argv[2]))
strip = lambda m: {k: v for k, v in m.items() if k != "files"}
if strip(new) != strip(old):
    print("top-level fields changed: %r != %r" % (strip(new), strip(old)))
if new.get("coding-guidelines", {}).get("files") != {"CodingStyle.md": "sha256:deadbeef"}:
    print("coding-guidelines.files lost: %r" % new.get("coding-guidelines"))
if list(new) != list(old):
    print("top-level key order changed: %r != %r" % (list(new), list(old)))
PY
)"
[ -z "$top_diff" ] || fail "W4: $top_diff"
ok "W4: top-level manifest fields (version, source, coding-guidelines incl. nested files, protected) preserved"

verify_out="$( cd "$X" && bash scripts/generate-checksums.sh --verify --quiet 2>&1 )" \
  || fail "checksum verify failed on the plugin tree: $verify_out"
# 4 manifest sources + .claude/manifest.json + .claude-plugin/plugin.json
case "$verify_out" in
  "checksums: 6 checked, 0 mismatched, 0 missing"*) ;;
  *) fail "unexpected verify summary (want 6 checked, 0 mismatched, 0 missing): $verify_out" ;;
esac
ok "SC2: every manifest source exists on the plugin branch; $verify_out"

# --- SC3: idempotent rebuild, then one appended commit -----------------------
tip1="$(git -C "$FX" rev-parse plugin)"
before="$(head_sha)"
out="$(run_build 2>&1)" || fail "no-change rebuild exited non-zero. Output: $out"
[ "$(git -C "$FX" rev-parse plugin)" = "$tip1" ] || fail "no-change rebuild created a commit"
grep -q 'already up to date' <<<"$out" || fail "no-change rebuild did not say it was up to date. Output: $out"
assert_untouched "$before" "no-change rebuild"
ok "SC3: rebuild with no source change creates no commit"

old_sha="$(head_sha)"
old_short="$(git -C "$FX" rev-parse --short HEAD)"
printf '#!/usr/bin/env bash\necho a2\n' > "$FX/hooks/a.sh"
git -C "$FX" commit -q -am "change hook"
before="$(head_sha)"
out="$(run_build 2>&1)" || fail "rebuild after change exited non-zero. Output: $out"
tip2="$(git -C "$FX" rev-parse plugin)"
[ "$tip2" != "$tip1" ] || fail "rebuild after a source change created no commit"
[ "$(git -C "$FX" rev-parse plugin^)" = "$tip1" ] || fail "new plugin commit's parent is not the previous tip"
[ "$(git -C "$FX" rev-list --count "$tip1..$tip2")" = "1" ] || fail "rebuild added more than one commit"
assert_untouched "$before" "rebuild after change"
ok "SC3: source change appends exactly one commit on the previous plugin tip"

# --- C1: --source is what gets built, never the working tree ------------------
out="$(run_build --branch c1 --source "$old_sha" 2>&1)" || fail "--source <sha> build failed. Output: $out"
[ "$(blob_of c1 hooks/a.sh)" = "$(printf '#!/usr/bin/env bash\necho a')" ] \
  || fail "--source <older sha> did not build the old hooks/a.sh: $(blob_of c1 hooks/a.sh)"
msg="$(git -C "$FX" log -1 --format=%B c1)"
[ "$msg" = "release: fx v1.2.3 (from $old_short)" ] || fail "--source <sha> commit message does not name $old_short: '$msg'"
[ "$(git -C "$FX" rev-parse plugin)" = "$tip2" ] || fail "--branch c1 moved the plugin branch"
ok "C1/W4: --source <older sha> builds that commit's content on --branch c1, plugin untouched"

git -C "$FX" tag -a v-old -m "old release" "$old_sha"
out="$(run_build --branch c1tag --source v-old 2>&1)" || fail "--source <annotated tag> build failed. Output: $out"
[ "$(blob_of c1tag hooks/a.sh)" = "$(printf '#!/usr/bin/env bash\necho a')" ] \
  || fail "--source <annotated tag> did not build the tagged hooks/a.sh"
msg="$(git -C "$FX" log -1 --format=%B c1tag)"
[ "$msg" = "release: fx v1.2.3 (from $old_short)" ] || fail "annotated-tag build message does not name the tagged commit: '$msg'"
ok "C1: --source <annotated tag> builds the tagged commit"

committed_hook="$(blob_of HEAD hooks/a.sh)"
printf '#!/usr/bin/env bash\necho DIRTY\n' > "$FX/hooks/a.sh"
printf 'untracked\n' > "$FX/hooks/untracked.sh"
out="$(run_build --branch c1dirty 2>&1)" || fail "build with a dirty work tree failed. Output: $out"
[ "$(blob_of c1dirty hooks/a.sh)" = "$committed_hook" ] || fail "uncommitted edit leaked into the plugin tree"
dirty_list="$(git -C "$FX" ls-tree -r --name-only c1dirty)"
! grep -qxF hooks/untracked.sh <<<"$dirty_list" || fail "untracked file leaked into the plugin tree"
grep -q DIRTY "$FX/hooks/a.sh" || fail "the build touched the caller's dirty working-tree file"
printf '%s\n' "$committed_hook" > "$FX/hooks/a.sh"
rm -f "$FX/hooks/untracked.sh"
assert_untouched "$before" "after restoring the dirty work tree"
ok "C1: uncommitted and untracked working-tree changes are not built (and are left in place)"

ok "SC4: branch stays main, HEAD unchanged, status clean across every build"

# --- F1: origin-only parent with an identical tree ----------------------------
git -C "$FX" update-ref refs/remotes/origin/plugin "$tip2"
git -C "$FX" update-ref -d refs/heads/plugin
out="$(run_build 2>&1)" || fail "up-to-date build with only origin/plugin exited non-zero. Output: $out"
grep -q 'already up to date' <<<"$out" || fail "origin-only up-to-date build did not say so. Output: $out"
[ "$(git -C "$FX" rev-parse -q --verify refs/heads/plugin || true)" = "$tip2" ] \
  || fail "origin-only up-to-date build did not create refs/heads/plugin at the origin tip"
ok "F1: origin-only + unchanged tree: exit 0, up to date, refs/heads/plugin created at the origin tip"

# --- remote-only parent ------------------------------------------------------
git -C "$FX" update-ref -d refs/heads/plugin
printf '#!/usr/bin/env bash\necho a3\n' > "$FX/hooks/a.sh"
git -C "$FX" commit -q -am "change hook again"
before="$(head_sha)"
out="$(run_build 2>&1)" || fail "build with only origin/plugin exited non-zero. Output: $out"
tip3="$(git -C "$FX" rev-parse plugin)"
[ "$tip3" != "$tip2" ] || fail "build with only origin/plugin created no commit"
[ "$(git -C "$FX" rev-parse plugin^)" = "$tip2" ] || fail "new commit's parent is not the origin/plugin tip"
assert_untouched "$before" "remote-parent build"
ok "with only refs/remotes/origin/plugin, the new commit's parent is the remote tip"

# --- C2: a branch moved mid-build is never clobbered --------------------------
REAL_GIT="$(command -v git)"
mkdir -p "$SBX/bin"
cat > "$SBX/bin/git" <<'SH'
#!/usr/bin/env bash
# Test double: on the build's update-ref, first move the branch like a concurrent writer.
if [ -n "${MOVE_PLUGIN_TO:-}" ]; then
  for a in "$@"; do
    if [ "$a" = "update-ref" ]; then
      "$REAL_GIT" -C "$MOVE_REPO" update-ref refs/heads/plugin "$MOVE_PLUGIN_TO"
      break
    fi
  done
fi
exec "$REAL_GIT" "$@"
SH
chmod +x "$SBX/bin/git"
other="$(git -C "$FX" commit-tree "$tip3^{tree}" -m "other writer")"
printf '#!/usr/bin/env bash\necho a4\n' > "$FX/hooks/a.sh"
git -C "$FX" commit -q -am "change hook for the race"
run_capture env REAL_GIT="$REAL_GIT" MOVE_REPO="$FX" MOVE_PLUGIN_TO="$other" PATH="$SBX/bin:$PATH" \
  bash "$BUILD" --repo "$FX"
[ "$RC" = "1" ] || fail "C2: build over a moved branch exited $RC, want 1. Out: $OUT Err: $ERR"
case "$ERR" in *"moved during the build"*) ;; *) fail "C2: stderr does not say the branch moved: $ERR" ;; esac
[ "$(git -C "$FX" rev-parse plugin)" = "$other" ] || fail "C2: the other writer's plugin commit was clobbered"
ok "C2: branch moved during the build -> exit 1, 'moved during the build', other writer's commit kept"

# --- C3: checksum generation / verification failures -------------------------
C3A="$SBX/c3 gen fails"
make_fixture "$C3A"
printf '#!/usr/bin/env bash\necho "stub generator broke" >&2\nexit 1\n' > "$C3A/scripts/generate-checksums.sh"
git -C "$C3A" commit -q -am "broken generator"
run_capture bash "$BUILD" --repo "$C3A"
[ "$RC" = "1" ] || fail "C3: failing generator exited $RC, want 1. Err: $ERR"
case "$ERR" in *"generate-checksums.sh failed"*) ;; *) fail "C3: missing 'generate-checksums.sh failed' message: $ERR" ;; esac
! git -C "$C3A" rev-parse -q --verify refs/heads/plugin >/dev/null || fail "C3: plugin ref created despite generator failure"
ok "C3: generator failure -> exit 1, 'generate-checksums.sh failed', no plugin ref"

C3B="$SBX/c3 bad hash"
make_fixture "$C3B"
cp "$C3B/scripts/generate-checksums.sh" "$C3B/scripts/real-gen.sh"
cat > "$C3B/scripts/generate-checksums.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# Stub: generates a checksum file with a wrong hash; --verify uses the real verifier.
cd "$(dirname "$0")/.."
if [ "${1:-}" = "--verify" ]; then exec bash scripts/real-gen.sh "$@"; fi
printf '# MTK release checksum manifest v1.2.3\n%064d  README.md\n' 0 > checksums.sha256
echo "Wrote checksums.sha256 (wrong on purpose)"
SH
git -C "$C3B" add -A
git -C "$C3B" commit -q -m "generator writes a wrong hash"
run_capture bash "$BUILD" --repo "$C3B"
[ "$RC" = "1" ] || fail "C3: wrong-hash generator exited $RC, want 1. Err: $ERR"
case "$ERR" in *"do not verify"*) ;; *) fail "C3: missing 'do not verify' message: $ERR" ;; esac
! git -C "$C3B" rev-parse -q --verify refs/heads/plugin >/dev/null || fail "C3: plugin ref created despite failed verify"
ok "C3: checksums that do not verify -> exit 1, 'do not verify', no plugin ref"

# --- W1: usage and environment errors exit 2 and create no ref ---------------
W1="$SBX/w1 usage"
make_fixture "$W1"

expect_exit() {
  local want="$1" label="$2" repo="$3" needle="$4" before_refs
  shift 4
  before_refs="$(refs_of "$repo")"
  run_capture bash "$BUILD" "$@"
  [ "$RC" = "$want" ] || fail "W1 $label: exited $RC, want $want. Out: $OUT Err: $ERR"
  case "$ERR$OUT" in *"$needle"*) ;; *) fail "W1 $label: output lacks '$needle'. Out: $OUT Err: $ERR" ;; esac
  [ "$(refs_of "$repo")" = "$before_refs" ] || fail "W1 $label: refs changed"
  ok "W1: $label -> exit $want ($needle)"
}

mkdir -p "$SBX/not a repo"
expect_exit 2 "invalid --branch" "$W1" "invalid branch name" --repo "$W1" --branch 'bad..name'
expect_exit 2 "bad --source" "$W1" "does not name a commit" --repo "$W1" --source no-such-ref
expect_exit 2 "--repo not a work tree" "$W1" "is not a git work tree" --repo "$SBX/not a repo"
expect_exit 2 "unknown arg" "$W1" "Unknown arg: --bogus" --repo "$W1" --bogus
expect_exit 2 "flag missing its value" "$W1" "--source needs a value" --repo "$W1" --source

W1M="$SBX/w1 no manifest"; make_fixture "$W1M"
git -C "$W1M" rm -q .claude/manifest.json; git -C "$W1M" commit -q -m "drop manifest"
expect_exit 2 "missing manifest" "$W1M" "has no .claude/manifest.json" --repo "$W1M"

W1P="$SBX/w1 no plugin json"; make_fixture "$W1P"
git -C "$W1P" rm -q .claude-plugin/plugin.json; git -C "$W1P" commit -q -m "drop plugin.json"
expect_exit 2 "missing plugin.json" "$W1P" "has no .claude-plugin/plugin.json" --repo "$W1P"

W1G="$SBX/w1 no generator"; make_fixture "$W1G"
git -C "$W1G" rm -q scripts/generate-checksums.sh; git -C "$W1G" commit -q -m "drop generator"
expect_exit 2 "missing generate-checksums.sh" "$W1G" "has no scripts/generate-checksums.sh" --repo "$W1G"

expect_exit 0 "--help" "$W1" "Usage:" --help

echo "All build-plugin-branch tests passed."
