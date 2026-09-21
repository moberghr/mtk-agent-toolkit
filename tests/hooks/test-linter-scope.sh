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

echo ""
if [ ${#FAILS[@]} -gt 0 ]; then
  printf '  FAIL  %s\n' "${FAILS[@]}" >&2
  exit 1
fi
echo "========================================"
echo "TEST PASSED — linter pack scoping holds"
