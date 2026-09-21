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


# 7. Constitution resolution: the Critical Rules section comes from the
#    RESOLVED constitution — AGENTS.md when it exists, is NOT generator-marked
#    (`Auto-generated by MTK` in its first 10 lines), and CLAUDE.md is absent or
#    a shim (`^@AGENTS.md`); otherwise CLAUDE.md. Legacy repos unchanged.
CONST="$(mktemp -d -t mtk-ctxconst-XXXXXX)"
trap 'rm -rf "$PROJ" "$CONST"' EXIT

# $1 = fixture name → a git repo with a one-file change_manifest sidecar.
make_const_proj() {
  local d="$CONST/$1"
  mkdir -p "$d/src" "$d/docs/specs"
  ( cd "$d" && git init -q . )
  printf 'def f():\n    return 1\n' > "$d/src/mod.py"
  cat > "$d/docs/specs/spec.json" <<'JSON'
{ "change_manifest": [ { "path": "src/mod.py" } ] }
JSON
  ( cd "$d" && git add -A && git -c user.email=t@t -c user.name=t commit -qm init )
  printf '%s\n' "$d"
}

AGENTS_CONST='# Fixture AGENTS\n\n## Critical Rules\n\n- **C9.1** The AGENTS rule.\n\n## Agents Only Heading\n\nbody\n'
CLAUDE_CONST='# Fixture CLAUDE\n\n## Critical Rules\n\n- **C9.9** The legacy CLAUDE rule.\n\n## Claude Only Heading\n\nbody\n'

run_const_pack() { # $1 = project dir, $2 = out path
  ( cd "$1" && CLAUDE_PROJECT_DIR="$1" MTK_HELPER_ROOT="$REPO_ROOT" \
      bash "$SCRIPT" const-uuid docs/specs/spec.json --out "$2" >/dev/null 2>&1 ) \
    || fail "build-context-pack exited non-zero for $1"
}

# 7a. AGENTS.md only.
D="$(make_const_proj agents-only)"; printf "$AGENTS_CONST" > "$D/AGENTS.md"
O="$D/pack.md"; run_const_pack "$D" "$O"
grep -q '^## AGENTS.md — Critical Rules' "$O" || fail "AGENTS.md-only: heading not sourced from AGENTS.md"
grep -q 'C9.1' "$O" || fail "AGENTS.md-only: rule body missing"
grep -q 'Agents Only Heading' "$O" || fail "AGENTS.md-only: TOC not built from AGENTS.md headings"
! grep -q '^## CLAUDE.md — Critical Rules' "$O" || fail "AGENTS.md-only: CLAUDE.md heading present"
ok "AGENTS.md-only repo: Critical Rules, body and TOC come from AGENTS.md"

# 7b. CLAUDE.md shim (`@AGENTS.md`) + AGENTS.md → AGENTS.md wins.
D="$(make_const_proj shim)"; printf "$AGENTS_CONST" > "$D/AGENTS.md"
{ printf '@AGENTS.md\n\n'; printf "$CLAUDE_CONST"; } > "$D/CLAUDE.md"
O="$D/pack.md"; run_const_pack "$D" "$O"
grep -q '^## AGENTS.md — Critical Rules' "$O" || fail "shim: heading not sourced from AGENTS.md"
grep -q 'C9.1' "$O" || fail "shim: AGENTS.md rule body missing"
! grep -q 'C9.9' "$O" || fail "shim: CLAUDE.md shim rules must not be packed"
! grep -q 'Claude Only Heading' "$O" || fail "shim: TOC must not come from the shim"
ok "CLAUDE.md shim resolves to AGENTS.md"

# 7c. Legacy: CLAUDE.md only, no AGENTS.md — output unchanged.
D="$(make_const_proj legacy)"; printf "$CLAUDE_CONST" > "$D/CLAUDE.md"
O="$D/pack.md"; run_const_pack "$D" "$O"
grep -q '^## CLAUDE.md — Critical Rules' "$O" || fail "legacy: heading not sourced from CLAUDE.md"
grep -q 'C9.9' "$O" || fail "legacy: CLAUDE.md rule body missing"
grep -q 'Claude Only Heading' "$O" || fail "legacy: TOC not built from CLAUDE.md headings"
! grep -q 'AGENTS.md — Critical Rules' "$O" || fail "legacy: AGENTS.md heading must not appear"
ok "legacy CLAUDE.md-only repo unchanged"

# 7d. Generator-marked AGENTS.md + a REAL CLAUDE.md constitution → the marker
#     disqualifies AGENTS.md, so the pack's rules must come from CLAUDE.md. The
#     shim line is present too, so without the marker clause AGENTS.md would win
#     and every subagent would be briefed from a references summary.
D="$(make_const_proj marked)"
{ printf '# AGENTS.md\n\n'
  printf '> Auto-generated by MTK. Sections marked `## Custom:` are preserved across regeneration.\n\n'
  printf "$AGENTS_CONST"
} > "$D/AGENTS.md"
{ printf '@AGENTS.md\n\n'; printf "$CLAUDE_CONST"; } > "$D/CLAUDE.md"
O="$D/pack.md"; run_const_pack "$D" "$O"
grep -q '^## CLAUDE.md — Critical Rules' "$O" || fail "marked AGENTS.md: heading not sourced from CLAUDE.md"
grep -q 'C9.9' "$O" || fail "marked AGENTS.md: CLAUDE.md rule body missing"
! grep -q 'C9.1' "$O" || fail "marked AGENTS.md: the generated summary's rules must not be packed"
! grep -q 'Agents Only Heading' "$O" || fail "marked AGENTS.md: TOC must not come from the generated summary"
ok "generator-marked AGENTS.md + real CLAUDE.md: rules come from CLAUDE.md"

# 7e. The marker only counts within the first 10 lines — a hand-authored
#     AGENTS.md that merely MENTIONS the string further down stays canonical.
D="$(make_const_proj late-marker)"
{ printf "$AGENTS_CONST"
  printf '\n## Notes\n\n'
  for i in 1 2 3 4 5 6 7 8 9 10; do printf 'filler %%s\n' "$i"; done
  printf '\nThe legacy summary carries "Auto-generated by MTK" in its header.\n'
} > "$D/AGENTS.md"
O="$D/pack.md"; run_const_pack "$D" "$O"
grep -q '^## AGENTS.md — Critical Rules' "$O" || fail "late marker: heading not sourced from AGENTS.md"
grep -q 'C9.1' "$O" || fail "late marker: AGENTS.md rule body missing"
ok "the marker string below line 10 does not demote a hand-authored AGENTS.md"

echo "test-build-context-pack: all checks passed"
