#!/usr/bin/env bash
# repomap.sh — deterministic symbol-graph extractor for setup-audit.
set -euo pipefail

# Contract:
#   repomap.sh <stack> [--budget=<tokens>] [--out=<path>]
#     stack        : dotnet | python | typescript | auto (default: read .claude/tech-stack)
#     --budget     : max tokens for ranked output (default: 4000)
#     --out        : JSON output path (default: .claude/.mtk-cache/repomap.json)
#
# Strategy (per stack):
#   dotnet     : delegate to `mcp__csharp-lsp__csharp_symbols` if reachable (MCP),
#                else tree-sitter-c-sharp, else print "fallback: llm-only" and exit 0 with empty graph.
#   python/ts  : tree-sitter AST walker (scripts/repomap-tree-sitter.py)
#
# Output: JSON on disk with schema:
#   { "stack": "...", "symbols": [{name, kind, file, refs}], "edges": [...], "token_estimate": N, "fit": "<ranked|full|fallback>" }

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

STACK="${1:-auto}"
BUDGET=4000
OUT=".claude/.mtk-cache/repomap.json"

for arg in "$@"; do
  case "$arg" in
    --budget=*) BUDGET="${arg#--budget=}" ;;
    --out=*)    OUT="${arg#--out=}" ;;
  esac
done

if [[ "$STACK" == "auto" ]]; then
  if [[ -f .claude/tech-stack ]]; then
    STACK=$(cat .claude/tech-stack | tr -d '[:space:]')
  else
    echo "repomap: no stack specified and .claude/tech-stack missing" >&2
    exit 2
  fi
fi

mkdir -p "$(dirname "$OUT")"

emit_fallback() {
  local reason="$1"
  python3 -c "
import json, sys
json.dump({
  'stack': '$STACK',
  'symbols': [],
  'edges': [],
  'token_estimate': 0,
  'fit': 'fallback',
  'fallback_reason': '$reason'
}, sys.stdout, indent=2)
" > "$OUT"
  echo "repomap: fallback (${reason}) — audit will proceed without symbol graph" >&2
}

case "$STACK" in
  dotnet)
    if command -v dotnet >/dev/null 2>&1 && [[ -n "${MTK_CSHARP_LSP:-}" ]]; then
      # LSP path is expected to be driven by Claude via the csharp-lsp MCP.
      # This script emits a placeholder marker; the skill wires the actual MCP calls.
      python3 -c "
import json, sys
json.dump({'stack':'dotnet','symbols':[],'edges':[],'token_estimate':0,'fit':'defer-to-mcp','note':'setup-audit will call mcp__csharp-lsp__csharp_symbols directly'}, sys.stdout, indent=2)
" > "$OUT"
      exit 0
    fi
    if python3 -c "import tree_sitter_c_sharp" 2>/dev/null; then
      python3 scripts/repomap-tree-sitter.py --stack dotnet --budget "$BUDGET" --out "$OUT"
      exit $?
    fi
    emit_fallback "no-lsp-no-treesitter"
    ;;
  python)
    if python3 -c "import tree_sitter_python" 2>/dev/null; then
      python3 scripts/repomap-tree-sitter.py --stack python --budget "$BUDGET" --out "$OUT"
      exit $?
    fi
    emit_fallback "no-treesitter-python"
    ;;
  typescript)
    if python3 -c "import tree_sitter_typescript" 2>/dev/null; then
      python3 scripts/repomap-tree-sitter.py --stack typescript --budget "$BUDGET" --out "$OUT"
      exit $?
    fi
    emit_fallback "no-treesitter-typescript"
    ;;
  *)
    emit_fallback "unknown-stack:${STACK}"
    ;;
esac
