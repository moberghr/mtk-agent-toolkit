#!/usr/bin/env bash
set -euo pipefail

# build-context-pack.sh must carry a shared CHANGE MAP — the symbols each
# manifest file declares and the files that reference them — so reviewer lanes
# read one call graph instead of each re-deriving it.
#
# WHY. In a 2026-09 field run (beacon) three of four reviewer lanes rebuilt the
# same cross-source call graph of the touched symbols; roughly a third of all
# reviewer tokens was that duplicated work. The pack is built once per run and
# every lane already reads it, so it is the one place the graph belongs.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/build-context-pack.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; }

PROJ="$(mktemp -d -t mtk-ctxpack-XXXXXX)"
trap 'rm -rf "$PROJ"' EXIT
( cd "$PROJ" && git init -q . )
mkdir -p "$PROJ/src/Gates" "$PROJ/src/Handlers" "$PROJ/tests" "$PROJ/docs/specs" "$PROJ/lib"

cat > "$PROJ/src/Gates/SqlExecutionGate.cs" <<'CS'
namespace Beacon.Gates;
public interface ISqlExecutionGate { bool Validate(string sql); }
public sealed class SqlExecutionGate : ISqlExecutionGate
{
    public bool Validate(string sql) => !sql.Contains("DROP");
    private static string Normalize(string s) => s.Trim();
}
CS
cat > "$PROJ/src/Handlers/RunQueryHandler.cs" <<'CS'
namespace Beacon.Handlers;
public class RunQueryHandler
{
    private readonly ISqlExecutionGate _gate;
    public RunQueryHandler(ISqlExecutionGate gate) { _gate = gate; }
    public bool Handle(string sql) => _gate.Validate(sql);
}
CS
cat > "$PROJ/tests/SqlExecutionGateTests.cs" <<'CS'
public class SqlExecutionGateTests { void T() { var g = new SqlExecutionGate(); g.Validate("x"); } }
CS
cat > "$PROJ/lib/helpers.py" <<'PY'
def normalize_sql(sql):
    return sql.strip()

class GateRegistry:
    pass
PY
cat > "$PROJ/lib/caller.py" <<'PY'
from helpers import normalize_sql
print(normalize_sql("x"))
PY
# A minified bundle mentioning the symbol must not count as a referrer.
printf 'var SqlExecutionGate=1;' > "$PROJ/lib/bundle.min.js"
( cd "$PROJ" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init )

cat > "$PROJ/docs/specs/2026-09-09-gate.json" <<'JSON'
{ "change_manifest": [
    { "path": "src/Gates/SqlExecutionGate.cs" },
    { "path": "lib/helpers.py" },
    { "path": "src/Missing/NotYetCreated.cs" }
] }
JSON

OUT="$PROJ/.mtk/pack.md"
( cd "$PROJ" && CLAUDE_PROJECT_DIR="$PROJ" MTK_HELPER_ROOT="$REPO_ROOT" \
    bash "$SCRIPT" test-uuid docs/specs/2026-09-09-gate.json --stack dotnet --out "$OUT" >"$PROJ/run.out" 2>"$PROJ/run.err" ) \
  || fail "build-context-pack exited non-zero: $(cat "$PROJ/run.err")"
[ -f "$OUT" ] || fail "pack not written at $OUT"

# 1. Section present.
grep -q '^## Change map' "$OUT" || fail "no '## Change map' section in the pack"
ok "Change map section present"

# 2. Declared symbols per manifest file (C# and Python shapes).
grep -q 'ISqlExecutionGate' "$OUT" || fail "interface ISqlExecutionGate not listed"
grep -q 'SqlExecutionGate'  "$OUT" || fail "class SqlExecutionGate not listed"
grep -q 'normalize_sql'     "$OUT" || fail "python def normalize_sql not listed"
grep -q 'GateRegistry'      "$OUT" || fail "python class GateRegistry not listed"
ok "declared symbols listed for C# and Python manifest files"

# 3. Referrers: files outside the manifest that mention a declared symbol.
grep -q 'src/Handlers/RunQueryHandler.cs' "$OUT" || fail "referrer RunQueryHandler.cs missing for ISqlExecutionGate"
grep -q 'tests/SqlExecutionGateTests.cs'  "$OUT" || fail "referrer test file missing for SqlExecutionGate"
grep -q 'lib/caller.py'                   "$OUT" || fail "referrer caller.py missing for normalize_sql"
ok "referrers listed across the repo"

# 4. Noise control: minified bundles never count; private helpers are skipped;
#    a manifest path that does not exist yet is named as new, not an error.
! grep -q 'bundle.min.js' "$OUT" || fail "minified bundle counted as a referrer"
! grep -qE '(^|[^A-Za-z])Normalize[^_]' "$OUT" || fail "private static helper Normalize should not be mapped"
grep -q 'NotYetCreated.cs' "$OUT" || fail "missing manifest path not named"
grep -qi 'new file' "$OUT" || fail "missing manifest path not marked as a new file"
ok "minified/private noise excluded; new files named"

# 5. Inventory line so --dry-run / stdout shows the section was built.
grep -q 'change map' "$PROJ/run.out" || grep -q 'change map' "$OUT" || fail "no change-map inventory line"
ok "inventory reports the change map"

# 6. Opt-out.
OUT2="$PROJ/.mtk/pack2.md"
( cd "$PROJ" && CLAUDE_PROJECT_DIR="$PROJ" MTK_HELPER_ROOT="$REPO_ROOT" MTK_CONTEXT_PACK_CHANGE_MAP=0 \
    bash "$SCRIPT" test-uuid docs/specs/2026-09-09-gate.json --stack dotnet --out "$OUT2" >/dev/null 2>&1 ) \
  || fail "opt-out run exited non-zero"
! grep -q '^## Change map' "$OUT2" || fail "MTK_CONTEXT_PACK_CHANGE_MAP=0 did not suppress the section"
ok "MTK_CONTEXT_PACK_CHANGE_MAP=0 suppresses the change map"

echo "test-build-context-pack: all checks passed"
