#!/usr/bin/env bash
set -euo pipefail

# check-instruction-load.sh reports CODEX-BYTES, SHADOWED-AGENTS,
# GLOBS-NOT-PATHS and LOCAL-UNIGNORED (spec R9 / SC4), each on its own fixture,
# and stays silent on the clean twin of every one.
#
# Every fixture is a fresh git repo under a mktemp -d sandbox; the real repo is
# never scanned. GIT_CEILING_DIRECTORIES keeps the "outside a git repo" case
# from discovering a parent repository.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK="$REPO_ROOT/scripts/check-instruction-load.sh"
RESOLVER="$REPO_ROOT/scripts/resolve-constitution.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
export TMPDIR="$SANDBOX"
export GIT_CEILING_DIRECTORIES="$SANDBOX"
unset MTK_CODEX_DOC_MAX_BYTES

fails=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf 'FAIL: %s — %s\n' "$1" "$2" >&2; fails=$((fails + 1)); }

# Fresh git repo; echoes its path. mktemp, not a counter: callers use $(...),
# and a counter bumped in that subshell would hand every fixture the same dir.
new_repo() {
  local d
  d="$(mktemp -d "$SANDBOX/r.XXXXXX")"
  git -C "$d" init -q
  printf '%s' "$d"
}

# bytes <file> <count> — write exactly <count> bytes.
bytes() {
  mkdir -p "$(dirname "$1")"
  python3 -c 'import sys; sys.stdout.write("a" * int(sys.argv[1]))' "$2" >"$1"
}

# run <root> [args...] — sets OUT and RC.
run() {
  local root="$1"; shift
  RC=0
  OUT="$(bash "$CHECK" --root "$root" "$@" 2>/dev/null)" || RC=$?
}

# expect_fires <label> <code> <path> — exactly one line for <code>, naming <path>.
expect_fires() {
  local label="$1" code="$2" path="$3" hits
  hits="$(grep -c "^$code " <<<"$OUT" || true)"
  if [ "$RC" -ne 1 ]; then fail "$label" "expected exit 1, got $RC (out: $OUT)"; return; fi
  if [ "$hits" -ne 1 ]; then fail "$label" "expected 1 $code line, got $hits (out: $OUT)"; return; fi
  if ! grep -qF "$code $path: " <<<"$OUT"; then fail "$label" "no '$code $path: ' line (out: $OUT)"; return; fi
  pass "$label"
}

expect_silent() {
  local label="$1"
  if [ "$RC" -ne 0 ] || [ -n "$OUT" ]; then fail "$label" "expected exit 0 and no output, got $RC (out: $OUT)"; return; fi
  pass "$label"
}

# A clean repo: small AGENTS.md, bare-import shim, paths: rules, ignored local file.
clean_repo() {
  local d; d="$(new_repo)"
  printf '# Constitution\n\nRules.\n' >"$d/AGENTS.md"
  printf '# Shim\n\n@AGENTS.md\n' >"$d/CLAUDE.md"
  mkdir -p "$d/.claude/rules"
  printf -- '---\npaths:\n  - "src/**"\n---\n# Rule\n' >"$d/.claude/rules/r.md"
  printf 'CLAUDE.local.md\n' >"$d/.gitignore"
  printf 'me\n' >"$d/CLAUDE.local.md"
  printf '%s' "$d"
}

echo "== clean =="
R="$(clean_repo)"; run "$R"; expect_silent "clean repo: exit 0, no output"
run "$R" --json
if [ "$RC" -eq 0 ] && [ "$OUT" = "[]" ]; then pass "clean repo --json: []"; else fail "clean repo --json" "got $RC '$OUT'"; fi

echo "== CODEX-BYTES =="
R="$(clean_repo)"; bytes "$R/AGENTS.md" 40000; run "$R"
expect_fires "root AGENTS.md over 32768 fires" CODEX-BYTES AGENTS.md
if grep -qF "40000 bytes" <<<"$OUT" && grep -qF "32768-byte limit" <<<"$OUT" && grep -qF "truncates" <<<"$OUT"; then
  pass "detail names total, limit and silent truncation"
else fail "CODEX-BYTES detail" "$OUT"; fi
R="$(clean_repo)"; bytes "$R/AGENTS.md" 32768; run "$R"; expect_silent "exactly at the limit stays silent"

R="$(clean_repo)"; bytes "$R/AGENTS.md" 20000; bytes "$R/pkg/AGENTS.md" 20000; run "$R"
expect_fires "nested chain root+pkg over limit fires on pkg" CODEX-BYTES pkg/AGENTS.md
if grep -qF "AGENTS.md + pkg/AGENTS.md is 40000 bytes" <<<"$OUT"; then pass "nested chain sums root + nested"; else fail "nested chain sum" "$OUT"; fi
R="$(clean_repo)"; bytes "$R/AGENTS.md" 10000; bytes "$R/pkg/AGENTS.md" 10000; run "$R"; expect_silent "nested chain under limit stays silent"
R="$(clean_repo)"; bytes "$R/AGENTS.md" 20000; bytes "$R/a/b/AGENTS.md" 20000; run "$R"
expect_fires "gap level (no file at a/) still chains root + a/b" CODEX-BYTES a/b/AGENTS.md

R="$(clean_repo)"; bytes "$R/AGENTS.md" 40000; bytes "$R/AGENTS.override.md" 100; run "$R"
expect_silent "AGENTS.override.md preferred: small override hides big AGENTS.md"
R="$(clean_repo)"; bytes "$R/AGENTS.md" 100; bytes "$R/AGENTS.override.md" 40000; run "$R"
expect_fires "AGENTS.override.md preferred: big override fires" CODEX-BYTES AGENTS.override.md

R="$(clean_repo)"; bytes "$R/node_modules/x/AGENTS.md" 40000; bytes "$R/.claude/worktrees/w/AGENTS.md" 40000
bytes "$R/.mtk/AGENTS.md" 40000; bytes "$R/sub/AGENTS.md" 40000; printf 'gitdir: /elsewhere\n' >"$R/sub/.git"; run "$R"
expect_silent "node_modules, .mtk, .claude/worktrees and nested checkouts are skipped"

R="$(clean_repo)"; bytes "$R/AGENTS.md" 1000; RC=0
OUT="$(MTK_CODEX_DOC_MAX_BYTES=500 bash "$CHECK" --root "$R" 2>/dev/null)" || RC=$?
expect_fires "MTK_CODEX_DOC_MAX_BYTES=500 lowers the limit" CODEX-BYTES AGENTS.md
if grep -qF "500-byte limit" <<<"$OUT"; then pass "override limit named in detail"; else fail "override limit detail" "$OUT"; fi
RC=0; MTK_CODEX_DOC_MAX_BYTES=abc bash "$CHECK" --root "$R" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 2 ]; then pass "non-numeric MTK_CODEX_DOC_MAX_BYTES → exit 2"; else fail "bad max bytes" "got $RC"; fi

echo "== SHADOWED-AGENTS =="
# Each fixture: <label> <CLAUDE.md content or '-' for absent> <expect fires 1|0>
shadow_case() {
  local label="$1" claude="$2" want="$3" d resolved agree
  d="$(new_repo)"
  printf '# Constitution\n\nRules.\n' >"$d/AGENTS.md"
  [ "$claude" = "-" ] || printf '%b' "$claude" >"$d/CLAUDE.md"
  run "$d"
  if [ "$want" -eq 1 ]; then expect_fires "$label" SHADOWED-AGENTS AGENTS.md; else expect_silent "$label"; fi
  # Agreement with the resolver on the same fixture.
  resolved="$(bash "$RESOLVER" --loaded "$d")"
  agree=0
  if [ "$resolved" = "$d/CLAUDE.md" ]; then [ "$RC" -eq 1 ] && agree=1; else [ "$RC" -eq 0 ] && agree=1; fi
  if [ "$agree" -eq 1 ]; then pass "$label — agrees with resolve-constitution.sh"; else fail "$label" "resolver says $resolved, check rc=$RC"; fi
}
shadow_case "real CLAUDE.md, no import → shadowed" '# Constitution\n\n## Critical Rules\n- x\n' 1
shadow_case "shim with bare @AGENTS.md → not shadowed" '# Shim\n\n@AGENTS.md\n' 0
shadow_case "import only inside backticks → shadowed" '# Shim\n\nSee `@AGENTS.md`.\n' 1
shadow_case "no CLAUDE.md → not shadowed" '-' 0
R="$(new_repo)"; printf '# only claude\n' >"$R/CLAUDE.md"; run "$R"; expect_silent "no AGENTS.md → nothing to shadow"
# Generator-marked AGENTS.md, no CLAUDE.md: canonical mode would answer CLAUDE.md
# (a file that does not exist); --loaded says AGENTS.md loads — not shadowed.
R="$(new_repo)"; printf '<!-- Auto-generated by MTK -->\n# Summary\n' >"$R/AGENTS.md"; run "$R"
expect_silent "generator-marked AGENTS.md with no CLAUDE.md → not shadowed"

echo "== GLOBS-NOT-PATHS =="
R="$(clean_repo)"; printf -- '---\nglobs: "src/**"\n---\n# Rule\n' >"$R/.claude/rules/cursor.md"; run "$R"
expect_fires "globs: without paths: fires" GLOBS-NOT-PATHS .claude/rules/cursor.md
R="$(clean_repo)"; mkdir -p "$R/.claude/rules/sub"; printf -- '---\nglobs:\n  - "src/**"\n---\n' >"$R/.claude/rules/sub/deep.md"; run "$R"
expect_fires "recursive: nested rule file fires" GLOBS-NOT-PATHS .claude/rules/sub/deep.md
R="$(clean_repo)"; printf -- '---\nglobs: "src/**"\npaths:\n  - "src/**"\n---\n' >"$R/.claude/rules/both.md"; run "$R"
expect_silent "globs: plus paths: stays silent"
R="$(clean_repo)"; printf -- '---\ndescription: x\n---\nglobs: in the body is prose\n' >"$R/.claude/rules/body.md"; run "$R"
expect_silent "globs: outside the frontmatter stays silent"
R="$(clean_repo)"; printf 'globs: no frontmatter at all\n' >"$R/.claude/rules/nofm.md"; run "$R"
expect_silent "file without frontmatter stays silent"

echo "== LOCAL-UNIGNORED =="
R="$(clean_repo)"; rm "$R/.gitignore"; run "$R"
expect_fires "CLAUDE.local.md not ignored fires" LOCAL-UNIGNORED CLAUDE.local.md
R="$(clean_repo)"; run "$R"; expect_silent "ignored CLAUDE.local.md stays silent"
R="$SANDBOX/nogit"; mkdir -p "$R"; printf 'me\n' >"$R/CLAUDE.local.md"; run "$R"
expect_silent "outside a git repo: skipped silently"

echo "== --json shape and usage =="
R="$(clean_repo)"; bytes "$R/AGENTS.md" 40000; rm "$R/.gitignore"
printf -- '---\nglobs: "x/**"\n---\n' >"$R/.claude/rules/g.md"
printf '# real\n' >"$R/CLAUDE.md"
run "$R" --json
shape="$(python3 -c '
import json, sys
a = json.loads(sys.stdin.read())
assert isinstance(a, list)
for o in a:
    assert set(o) == {"code", "path", "detail"}, o
    assert all(isinstance(v, str) and v for v in o.values()), o
print(" ".join(sorted(o["code"] for o in a)))
' <<<"$OUT" 2>&1)" || shape="PARSE-ERROR: $shape"
if [ "$RC" -eq 1 ] && [ "$shape" = "CODEX-BYTES GLOBS-NOT-PATHS LOCAL-UNIGNORED SHADOWED-AGENTS" ]; then
  pass "--json: array of {code,path,detail}, all four codes, exit 1"
else fail "--json shape" "rc=$RC shape=$shape out=$OUT"; fi
run "$R"
lines="$(grep -c '' <<<"$OUT" || true)"
if [ "$lines" -eq 4 ]; then pass "text mode: one finding per line"; else fail "text lines" "got $lines: $OUT"; fi
RC=0; bash "$CHECK" --bogus >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 2 ]; then pass "unknown flag → exit 2"; else fail "unknown flag" "got $RC"; fi
RC=0; bash "$CHECK" --root "$SANDBOX/missing" >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 2 ]; then pass "missing --root dir → exit 2"; else fail "missing root" "got $RC"; fi

echo "== sub-check could not run =="
# run_err <check script> <root> [args...] — sets OUT, ERR (first stderr line) and RC.
run_err() {
  local check="$1" root="$2"; shift 2
  RC=0
  OUT="$(bash "$check" --root "$root" "$@" 2>"$SANDBOX/err")" || RC=$?
  ERR="$(awk 'NF { print; exit }' "$SANDBOX/err")"
}
# A copy of the script next to a resolver that always fails (exit 3).
KIT="$SANDBOX/kit"; mkdir -p "$KIT/scripts"
cp "$CHECK" "$KIT/scripts/check-instruction-load.sh"
printf '#!/usr/bin/env bash\nexit 3\n' >"$KIT/scripts/resolve-constitution.sh"
R="$(clean_repo)"; run_err "$KIT/scripts/check-instruction-load.sh" "$R"
if [ "$RC" -eq 2 ] && [ -z "$OUT" ] && [ "$ERR" = "check-instruction-load: resolve-constitution.sh --loaded failed (exit 3); SHADOWED-AGENTS not checked" ]; then
  pass "resolver fails, nothing found → exit 2 + one 'SHADOWED-AGENTS not checked' stderr line"
else fail "resolver fails, nothing found" "rc=$RC out='$OUT' err='$ERR'"; fi
# Negative control: the same copy with a working resolver is clean (exit 0).
cp "$RESOLVER" "$KIT/scripts/resolve-constitution.sh"
run_err "$KIT/scripts/check-instruction-load.sh" "$R"
if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then pass "control: same copy, working resolver → exit 0, no stderr"
else fail "working-resolver control" "rc=$RC err='$ERR'"; fi
printf '#!/usr/bin/env bash\nexit 3\n' >"$KIT/scripts/resolve-constitution.sh"
printf -- '---\nglobs: "src/**"\n---\n' >"$R/.claude/rules/cursor.md"
run_err "$KIT/scripts/check-instruction-load.sh" "$R"
if [ "$RC" -eq 1 ] && grep -q '^GLOBS-NOT-PATHS ' <<<"$OUT" && [ "${ERR%SHADOWED-AGENTS not checked}" != "$ERR" ]; then
  pass "resolver fails, finding present → exit 1, finding on stdout, not-checked line still on stderr"
else fail "resolver fails with finding" "rc=$RC out='$OUT' err='$ERR'"; fi
# git check-ignore failing (exit 128) through a PATH shim; every other git call is real.
REAL_GIT="$(command -v git)"
mkdir -p "$SANDBOX/shim"
printf '#!/usr/bin/env bash\n[ "${3:-}" = check-ignore ] && exit 128\nexec "%s" "$@"\n' "$REAL_GIT" >"$SANDBOX/shim/git"
chmod +x "$SANDBOX/shim/git"
R="$(clean_repo)"; RC=0
OUT="$(PATH="$SANDBOX/shim:$PATH" bash "$CHECK" --root "$R" 2>"$SANDBOX/err")" || RC=$?
ERR="$(awk 'NF { print; exit }' "$SANDBOX/err")"
if [ "$RC" -eq 2 ] && [ -z "$OUT" ] && [ "$ERR" = "check-instruction-load: git check-ignore failed (exit 128); LOCAL-UNIGNORED not checked" ]; then
  pass "git check-ignore fails, nothing found → exit 2 + 'LOCAL-UNIGNORED not checked'"
else fail "git check-ignore fails" "rc=$RC out='$OUT' err='$ERR'"; fi

echo
if [ "$fails" -eq 0 ]; then echo "test-check-instruction-load: all passed"; else echo "test-check-instruction-load: $fails failed"; fi
exit "$fails"
