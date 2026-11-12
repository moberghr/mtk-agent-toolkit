#!/usr/bin/env bash
set -euo pipefail

# verify-references.sh scans instruction files for backtick path tokens and
# prints `STALE in <file>: '<token>' …` (exit 3) for ones that resolve nowhere.
# Before this fix every placeholder or glob token was read as a literal path,
# so the toolkit's own rule files always reported seven false positives — and a
# linter that always reports noise gets ignored, so real rot hides. Now:
#   - placeholder segments (<x>, {x}, $VAR, ${VAR}, YYYY-MM-DD, …) become `*`;
#   - a glob resolves when any path matches it (root, src/, git index);
#   - an unmatched pattern or a missing path that is git-ignored is skipped;
#   - a bare `name/` directory resolves at any depth of the git index;
#   - `<!-- verify-references: ignore -->` on a line, or a glob listed in
#     .claude/verify-references.ignore, opts a token out;
#   - true positives keep their exact line format and exit 3, and the skip
#     summary goes to stderr only.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VR="$REPO_ROOT/scripts/verify-references.sh"
[ -f "$VR" ] || { echo "FAIL: script not found: $VR"; exit 1; }

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
# Hermetic git: a developer's global excludes (e.g. `.claude/skills/`) would
# otherwise hide fixture files from the index and mark probes as ignored.
mkdir -p "$SBX/home/.config"
export HOME="$SBX/home" XDG_CONFIG_HOME="$SBX/home/.config" GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_GLOBAL GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
P="$SBX/repo"
mkdir -p "$P"
git -C "$P" init -q

fails=0
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
pass() { echo "PASS: $1"; }

# run <doc> — sets OUT (stdout), ERR (stderr), RC (exit code).
run() {
  RC=0
  OUT="$(cd "$P" && bash "$VR" "$1" 2>"$SBX/err")" || RC=$?
  ERR="$(cat "$SBX/err")"
}

CLEAN_LINE="verify-references: no stale references found"

# --- Fixture repo: mirrors the shapes MTK's own rule files reference --------
mkdir -p "$P/hooks/lib" "$P/.claude/skills/tech-stack-dotnet" "$P/.claude/skills/fix" \
  "$P/scripts" "$P/docs/handoffs" "$P/docs/notes" "$P/docs/specs"
printf '.mtk/\n.claude/local-state.json\n' > "$P/.gitignore"
printf '#!/usr/bin/env bash\n' > "$P/hooks/lib/hook-io.sh"
printf -- '---\nname: tech-stack-dotnet\n---\n' > "$P/.claude/skills/tech-stack-dotnet/SKILL.md"
printf -- '---\nname: fix\n---\n' > "$P/.claude/skills/fix/SKILL.md"
printf '#!/usr/bin/env bash\n' > "$P/scripts/build.sh"
printf '*\n' > "$P/docs/handoffs/.gitignore"          # self-ignoring runtime dir, as the handoff writer makes it
printf 'note\n' > "$P/docs/notes/today.md"
printf 'spec\n' > "$P/docs/specs/2026-01-01-thing.md"
git -C "$P" add -A

# --- 1. The seven shapes from MTK's rule files (plus placeholder siblings) --
cat > "$P/shapes.md" <<'EOF'
# Shapes
- Target repos' `.claude/mtk-version.json` stamps are written by setup. <!-- verify-references: ignore -->
- `.claude/local-state.json` is git-ignored local state.
- Compaction archives: `.mtk/sessions/*/compact-*.md`.
- Telemetry goes to `.mtk/sessions/<session>/telemetry.json` only when `.mtk/` is ignored.
- Recent notes: the first `docs/handoffs/*.md` modified < 24h.
- Everything else under `hooks/` is on-demand, including the sourced helpers in `lib/`.
- Per-stack context lives in `tech-stack-{name}/SKILL.md`.
- Skill directory `.claude/skills/<skill-name>/SKILL.md` must match its name.
- Plugin paths: `${CLAUDE_PLUGIN_ROOT}/scripts/build.sh` and `$MTK_ROOT/hooks/lib/hook-io.sh`.
- Specs: `docs/specs/YYYY-MM-DD-<slug>.md`; any skill: `.claude/skills/…/SKILL.md`.
EOF
run shapes.md
if [ "$RC" -eq 0 ] && [ "$OUT" = "$CLEAN_LINE" ]; then
  pass "the seven rule-file shapes and their placeholder siblings are not reported"
else
  fail "shapes must resolve or be skipped (rc 0, clean stdout). rc=$RC stdout: $OUT"
fi
case "$ERR" in *skipped*) pass "skip summary goes to stderr" ;; *) fail "expected a skip summary on stderr. stderr: $ERR" ;; esac
case "$OUT" in *skipped*) fail "skip summary must not reach stdout. stdout: $OUT" ;; esac

# --- 2. Pattern whose fixed prefix exists but nothing matches → reported ----
cat > "$P/prefix.md" <<'EOF'
- Every skill ships `.claude/skills/<skill-name>/README.md`.
- Python helpers: `hooks/lib/*.py`.
EOF
run prefix.md
want1="STALE in prefix.md: '.claude/skills/<skill-name>/README.md' "
want2="STALE in prefix.md: 'hooks/lib/*.py' "
case "$OUT" in *"$want1"*) pass "placeholder pattern with an existing prefix and no match is STALE" ;; *) fail "expected '${want1}...'. stdout: $OUT" ;; esac
case "$OUT" in *"$want2"*) pass "glob with an existing prefix and no match is STALE" ;; *) fail "expected '${want2}...'. stdout: $OUT" ;; esac
[ "$RC" -eq 3 ] && pass "unmatched patterns exit 3" || fail "unmatched patterns must exit 3, got $RC"

# --- 3. Plain missing path → unchanged line format and exit code ------------
printf -- '- Auth lives in `src/legacy/auth.ts`.\n' > "$P/missing.md"
run missing.md
if [ "$RC" -eq 3 ] && [ "$OUT" = "STALE in missing.md: 'src/legacy/auth.ts' looks like a path but resolves nowhere (root, src/, or git index)" ]; then
  pass "plain missing path: exact STALE line, exit 3"
else
  fail "plain missing path must keep its exact line and exit 3. rc=$RC stdout: $OUT"
fi
case "$ERR" in *"1 stale reference(s) found"*) pass "stale count on stderr unchanged" ;; *) fail "expected '1 stale reference(s) found' on stderr. stderr: $ERR" ;; esac

# A bare known-prefix directory that exists nowhere is still a claim.
printf -- '- Domain code lives in `services/`.\n' > "$P/bare.md"
run bare.md
case "$OUT" in *"STALE in bare.md: 'services/' "*) pass "bare directory that exists nowhere is STALE" ;; *) fail "a bare 'services/' with no such directory must be STALE. stdout: $OUT" ;; esac

# --- 4. Globs that match real files → not reported --------------------------
# docs/notes/today.md is tracked (index match); drafts/wip.md exists only on
# disk, untracked (root-glob match).
mkdir -p "$P/drafts"
printf 'wip\n' > "$P/drafts/wip.md"
printf -- '- Build scripts: `scripts/*.sh`; notes: `docs/notes/*.md`; drafts: `drafts/*.md`.\n' > "$P/globs.md"
run globs.md
if [ "$RC" -eq 0 ] && [ "$OUT" = "$CLEAN_LINE" ]; then
  pass "globs that match real files are not reported"
else
  fail "matching globs must not be reported. rc=$RC stdout: $OUT"
fi

# --- 5. Author opt-outs: inline comment and ignore file ---------------------
cat > "$P/optout.md" <<'EOF'
- `config/removed.json` was retired on purpose. <!-- verify-references: ignore -->
- `vendor/gone/client.js` is listed in the ignore file.
EOF
printf -- '- `config/removed.json` is mentioned again without the comment.\n' > "$P/control.md"
mkdir -p "$P/.claude"
printf '# vendored code is fetched at build time\n\n  vendor/**  \n' > "$P/.claude/verify-references.ignore"
run optout.md
if [ "$RC" -eq 0 ] && [ "$OUT" = "$CLEAN_LINE" ]; then
  pass "inline ignore comment and ignore-file glob opt tokens out"
else
  fail "opted-out tokens must not be reported. rc=$RC stdout: $OUT"
fi
run control.md
case "$OUT" in *"STALE in control.md: 'config/removed.json' "*) pass "the same token without the comment is still reported" ;; *) fail "control token without the comment must be STALE. stdout: $OUT" ;; esac
rm -f "$P/.claude/verify-references.ignore"
run optout.md
case "$OUT" in *"STALE in optout.md: 'vendor/gone/client.js' "*) pass "without the ignore file the vendored token is reported" ;; *) fail "removing the ignore file must re-arm the vendor token. stdout: $OUT" ;; esac
case "$OUT" in *"config/removed.json"*) fail "the commented line must stay skipped. stdout: $OUT" ;; esac

# --- 6. Clean file → only the existing success line, nothing on stderr ------
printf -- '- Build with `scripts/build.sh`.\n' > "$P/clean.md"
run clean.md
if [ "$RC" -eq 0 ] && [ "$OUT" = "$CLEAN_LINE" ] && [ -z "$ERR" ]; then
  pass "clean file: unchanged stdout, empty stderr, exit 0"
else
  fail "clean file must print only '$CLEAN_LINE'. rc=$RC stdout: $OUT stderr: $ERR"
fi

if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "All verify-references checks passed"
