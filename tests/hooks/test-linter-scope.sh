#!/usr/bin/env bash
set -euo pipefail

# Test: pattern-pack scoping in hooks/pre-commit-linters.sh.
#
# Field report: a wiki page under docs/wiki/ quoted a vulnerable SQL line to
# explain it, RAW-SQL-INTERPOLATED (a stack-dotnet code rule) fired on the
# prose, and the commit was blocked — so the page got paraphrased into
# something less accurate. Code-scoped packs must skip prose files; secret
# rules must still apply everywhere.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LINTER="$REPO_ROOT/hooks/pre-commit-linters.sh"

echo "=== Linter Scope Test ==="
[ -f "$LINTER" ] || { echo "  FAIL  linter not found: $LINTER" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git -C "$WORK" init -q
git -C "$WORK" config user.email test@example.com
git -C "$WORK" config user.name test

mkdir -p "$WORK/docs/wiki" "$WORK/src"

# A documentation page that quotes the vulnerable line it is warning about,
# plus a real credential (which must still be caught).
cat > "$WORK/docs/wiki/sql-safety.md" <<'MD'
# SQL safety

The reporting endpoint used to build its query like this:

```csharp
context.Accounts.FromSqlRaw($"SELECT * FROM Accounts WHERE Id = {id}")
```

That is the injection we removed in #412.
MD

# Appended, not inlined: a literal AWS-shaped key in this file would (rightly)
# trip AWS-ACCESS-KEY on the toolkit's own commits. Split here, joined on write.
printf 'Do not paste keys like %s%s into a page either.\n' \
  'AKIA' 'IOSFODNN7EXAMPLE' >> "$WORK/docs/wiki/sql-safety.md"

# The same line in actual source must still be a critical finding.
cat > "$WORK/src/AccountRepository.cs" <<'CS'
public IQueryable<Account> ByIdUnsafe(string id) =>
    context.Accounts.FromSqlRaw($"SELECT * FROM Accounts WHERE Id = {id}");
CS

git -C "$WORK" add -A

OUT="$(cd "$WORK" && bash "$LINTER" --cached --stack dotnet)"

declare -a FAILS=()
assert_absent() {
  if printf '%s' "$OUT" | grep -q -- "$1"; then FAILS+=("$2"); else echo "  PASS  $2"; fi
}
assert_present() {
  if printf '%s' "$OUT" | grep -q -- "$1"; then echo "  PASS  $2"; else FAILS+=("$2"); fi
}

# 1. The code rule does not fire on the prose page.
assert_absent '"rule":"RAW-SQL-INTERPOLATED","file":"docs/wiki/sql-safety.md"' \
  'RAW-SQL-INTERPOLATED does not fire on a markdown page'

# 2. The same rule still fires on real source.
assert_present '"rule":"RAW-SQL-INTERPOLATED","file":"src/AccountRepository.cs"' \
  'RAW-SQL-INTERPOLATED still fires on a .cs file'

# 3. Secret rules are scope: all — a key in a doc is still a leak.
assert_present '"rule":"AWS-ACCESS-KEY","file":"docs/wiki/sql-safety.md"' \
  'AWS-ACCESS-KEY still fires on a markdown page'

# 4. The prose page alone must not block a commit.
OUT_DOC_ONLY="$(cd "$WORK" && git reset -q && git add docs/wiki/sql-safety.md \
  && sed -i.bak '/AKIA/d' docs/wiki/sql-safety.md && git add docs/wiki/sql-safety.md \
  && rm -f docs/wiki/sql-safety.md.bak && bash "$LINTER" --cached --stack dotnet)"
if printf '%s' "$OUT_DOC_ONLY" | grep -q '"verdict":"PASS"'; then
  echo "  PASS  a doc-only change with quoted vulnerable code does not block the commit"
else
  FAILS+=("doc-only change still blocks: $OUT_DOC_ONLY")
fi

# 5. Paths git would quote. By default git prints a non-ASCII name C-quoted
# (`+++ "b/\303\234ber.cs"`), and a name with a space gets a trailing tab on the
# `+++` line; a finding must still land on the right file, and a lone staged
# file must still be scanned at all. The key is joined at runtime, as above.
QW="$(mktemp -d)"
trap 'rm -rf "$WORK" "$QW"' EXIT
git -C "$QW" init -q
key_line() { printf 'var k = "%s%s";\n' 'AKIA' 'IOSFODNN7EXAMPLE'; }
key_line > "$QW/Über.cs"
git -C "$QW" add -A
OUT="$(cd "$QW" && bash "$LINTER" --cached --stack dotnet)"
assert_present '"rule":"AWS-ACCESS-KEY","file":"Über.cs"' \
  'a key in a lone staged non-ASCII file (Über.cs) is found and attributed to it'
assert_present '"verdict":"NEEDS_CHANGES"' \
  'a lone staged non-ASCII file with a key blocks the commit'

printf 'var ok = 1;\n' > "$QW/plain.cs"
git -C "$QW" add -A
OUT="$(cd "$QW" && bash "$LINTER" --cached --stack dotnet)"
assert_present '"rule":"AWS-ACCESS-KEY","file":"Über.cs"' \
  'with a second file staged the finding stays on Über.cs'
assert_absent '"rule":"AWS-ACCESS-KEY","file":"plain.cs"' \
  'with a second file staged the finding is not attributed to plain.cs'

git -C "$QW" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm base
key_line > "$QW/my secrets.cs"
printf 'var ok = 2;\n' > "$QW/a.cs"
git -C "$QW" add 'my secrets.cs' a.cs
OUT="$(cd "$QW" && bash "$LINTER" --cached --stack dotnet)"
assert_present '"rule":"AWS-ACCESS-KEY","file":"my secrets.cs","line":1' \
  'a key in a file whose name has a space is attributed to that file'
assert_absent '"rule":"AWS-ACCESS-KEY","file":"a.cs"' \
  'a key in a spaced file name is not attributed to a neighbour'

# A `"` in a name stays C-quoted even with quotepath off: unquoted for the
# finding, escaped for the JSON.
git -C "$QW" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm spaced
key_line > "$QW/say \"hi\".cs"
git -C "$QW" add 'say "hi".cs'
OUT="$(cd "$QW" && bash "$LINTER" --cached --stack dotnet)"
qfile="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(" ".join(f["file"] for f in json.load(sys.stdin)["findings"] if f["rule"] == "AWS-ACCESS-KEY"))' 2>/dev/null || echo INVALID-JSON)"
if [ "$qfile" = 'say "hi".cs' ]; then
  echo '  PASS  a key in a file whose name holds a double quote is attributed to it (valid JSON)'
else
  FAILS+=("quoted-name finding: got [$qfile]")
fi

# --range and --head parse the same quoted/unquoted names.
git -C "$QW" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm quoted
key_line > "$QW/Ärger.cs"
git -C "$QW" add 'Ärger.cs'
git -C "$QW" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm umlaut
OUT="$(cd "$QW" && bash "$LINTER" --range HEAD~1...HEAD --stack dotnet)"
assert_present '"rule":"AWS-ACCESS-KEY","file":"Ärger.cs"' \
  '--range attributes a key to a non-ASCII file'
key_line > "$QW/Öl.cs"
git -C "$QW" add -N 'Öl.cs'
OUT="$(cd "$QW" && bash "$LINTER" --head --stack dotnet)"
assert_present '"rule":"AWS-ACCESS-KEY","file":"Öl.cs"' \
  '--head attributes a key to a non-ASCII file'

# 6. Hostile file names. Git C-quotes a name holding a control character even
# with quotepath off (`+++ "b/tab\tname.cs"`); unquoted into the tab-separated
# record stream, a real TAB split the record (`"file":"tab","line":name.cs`, so
# the whole report failed json.loads while the hook exited 0) and a real newline
# split it in two. The report must stay valid JSON for any name git can stage,
# each finding on the file's real name, classified by that whole name.
# json_check <label> <rule> <real file name> [line]: OUT parses as strict JSON
# and holds that finding; json_only <label> <name>...: every finding's file is
# one of the names (no fragment of a split record).
json_check() {
  if printf '%s' "$OUT" | python3 -c '
import json, sys
rule, name, line = sys.argv[1:4]
d = json.loads(sys.stdin.read())
sys.exit(0 if any(f["rule"] == rule and f["file"] == name and (not line or str(f["line"]) == line)
                  for f in d["findings"]) else 1)' "$2" "$3" "${4:-}" 2>/dev/null; then
    echo "  PASS  $1"
  else
    FAILS+=("$1 — output: $OUT")
  fi
}
json_only() {
  local label="$1"; shift
  if printf '%s' "$OUT" | python3 -c '
import json, sys
names = set(sys.argv[1:])
d = json.loads(sys.stdin.read())
sys.exit(0 if all(f["file"] in names for f in d["findings"]) else 1)' "$@" 2>/dev/null; then
    echo "  PASS  $label"
  else
    FAILS+=("$label — output: $OUT")
  fi
}
json_absent() { # <label> <rule> <real file name>
  if printf '%s' "$OUT" | python3 -c '
import json, sys
rule, name = sys.argv[1:3]
d = json.loads(sys.stdin.read())
sys.exit(1 if any(f["rule"] == rule and f["file"] == name for f in d["findings"]) else 0)' "$2" "$3" 2>/dev/null; then
    echo "  PASS  $1"
  else
    FAILS+=("$1 — output: $OUT")
  fi
}
HW="$(mktemp -d)"
trap 'rm -rf "$WORK" "$QW" "$HW"' EXIT
git -C "$HW" init -q
TAB=$'\t'; LF=$'\n'; CR=$'\r'
SQL_LINE='    context.Accounts.FromSqlRaw($"SELECT * FROM Accounts WHERE Id = {id}");'
N_TAB="tab${TAB}name.cs"          # a TAB inside a code file name
N_NL="multi${LF}line.cs"          # a newline inside a code file name
N_PROSE="x${LF}.md"               # ends in a prose extension after the newline
N_CODE="notes.md${LF}impl.cs"     # a prose-looking first line, a code extension
N_SOH="c$(printf '\001')d.cs"     # another control character (git: \001)
for n in "$N_TAB" "$N_NL" "$N_PROSE" "$N_CODE" "$N_SOH"; do
  { key_line; printf '%s\n' "$SQL_LINE"; } > "$HW/$n"
done
git -C "$HW" add -A
OUT="$(cd "$HW" && bash "$LINTER" --cached --stack dotnet)"
json_check 'a TAB in a file name: valid JSON, key attributed to the real name' AWS-ACCESS-KEY "$N_TAB" 1
json_check 'a newline in a file name: valid JSON, key attributed to the real name' AWS-ACCESS-KEY "$N_NL" 1
json_check 'a name ending in .md after a newline: key attributed to the real name' AWS-ACCESS-KEY "$N_PROSE" 1
json_check 'a \001 in a file name: key attributed to the real name' AWS-ACCESS-KEY "$N_SOH" 1
json_check 'a code rule still fires on a TAB-named .cs file' RAW-SQL-INTERPOLATED "$N_TAB" 2
json_check 'a code rule still fires on a newline-named .cs file' RAW-SQL-INTERPOLATED "$N_NL" 2
json_check 'classified by the whole name: notes.md<LF>impl.cs is code' RAW-SQL-INTERPOLATED "$N_CODE" 2
json_absent 'classified by the whole name: x<LF>.md is prose (no code rule)' RAW-SQL-INTERPOLATED "$N_PROSE"
json_only 'no finding lands on a fragment of a split name' "$N_TAB" "$N_NL" "$N_PROSE" "$N_CODE" "$N_SOH"

# 7. Added-line text is never a header, and every added line is counted. With
# -U0 a line whose text starts with "++ " shows as "+++ …" inside a hunk: it must
# be scanned (not skipped, not taken for a `+++ b/<file>` header), and neither
# it nor an empty added line may shift the line numbers after it.
git -C "$HW" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm hostile
{ printf '++ b/evil.cs\n\n'; key_line; printf '++ %s' "$(key_line)"; printf '\n'; } > "$HW/plus.cs"
git -C "$HW" add plus.cs
OUT="$(cd "$HW" && bash "$LINTER" --cached --stack dotnet)"
json_check 'a key after a "++ b/evil.cs" line and an empty line keeps its line number (3)' AWS-ACCESS-KEY plus.cs 3
json_check 'a key on a line starting with "++ " is scanned (line 4)' AWS-ACCESS-KEY plus.cs 4
json_only 'a "++ b/evil.cs" added line is not taken for a header' plus.cs

# 8. Content that needs escaping: a TAB and a CR inside the evidence, and a run
# of backslashes the 120-character preview cut used to split mid-escape (a lone
# trailing `\` then escaped the closing quote).
git -C "$HW" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm plus
{ printf 'var k = "%s%s";%s// note%s\n' 'AKIA' 'IOSFODNN7EXAMPLE' "$TAB" "$CR"
  printf '%s%s %s\n' 'AKIA' 'IOSFODNN7EXAMPLE' "$(printf '%*s' 200 '' | tr ' ' '\\')"
  printf '%s%s \001 \033[0m \177 &\n' 'AKIA' 'IOSFODNN7EXAMPLE'; } > "$HW/esc.cs"
git -C "$HW" add esc.cs
OUT="$(cd "$HW" && bash "$LINTER" --cached --stack dotnet)"
json_check 'a TAB and CR in the evidence: valid JSON' AWS-ACCESS-KEY esc.cs 1
json_check 'a backslash run at the preview cut: valid JSON' AWS-ACCESS-KEY esc.cs 2
json_check 'SOH, ESC and DEL in the evidence: valid JSON (\u00XX escapes)' AWS-ACCESS-KEY esc.cs 3

echo ""
if [ ${#FAILS[@]} -gt 0 ]; then
  printf '  FAIL  %s\n' "${FAILS[@]}" >&2
  exit 1
fi
echo "========================================"
echo "TEST PASSED — linter pack scoping holds"
