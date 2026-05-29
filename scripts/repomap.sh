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
#   dotnet     : signal `defer-to-mcp` so setup-audit drives `mcp__csharp-lsp__csharp_symbols`,
#                else tree-sitter-c-sharp, else fallback.
#   python/ts  : tree-sitter AST walker (scripts/repomap-tree-sitter.py)
#
# Output: JSON on disk with schema:
#   { "stack": "...", "symbols": [{name, kind, file, refs}], "edges": [...], "token_estimate": N, "fit": "<ranked|full|defer-to-mcp|fallback>" }
#
# IMPORTANT: this script SCANS the current working directory (the target repo), not its own
# location. The script may live in the plugin cache ($CLAUDE_PLUGIN_ROOT/scripts), so it must
# never cd into its own parent — doing so would scan and mis-detect the plugin itself.

# Locate sibling helper scripts by the script's own dir, but SCAN the target repo (cwd).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
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
    STACK=$(tr -d '[:space:]' < .claude/tech-stack)
  else
    echo "repomap: no stack specified and .claude/tech-stack missing" >&2
    exit 2
  fi
fi

mkdir -p "$(dirname "$OUT")"

# Emit a stub JSON so downstream `json.load` never throws on a missing file.
emit_stub() {
  local fit="$1" reason="$2"
  python3 -c "
import json, sys
json.dump({
  'stack': '$STACK',
  'symbols': [],
  'edges': [],
  'token_estimate': 0,
  'fit': '$fit',
  'fallback_reason': '$reason'
}, sys.stdout, indent=2)
" > "$OUT"
}

emit_fallback() {
  local reason="$1"
  emit_stub "fallback" "$reason"
  echo "repomap: fallback (${reason}) — audit will proceed without symbol graph (stub written to $OUT)" >&2
}

case "$STACK" in
  dotnet)
    if python3 -c "import tree_sitter_c_sharp" 2>/dev/null; then
      python3 "$SCRIPT_DIR/repomap-tree-sitter.py" --stack dotnet --budget "$BUDGET" --out "$OUT"
      exit $?
    fi
    # No local AST parser — signal the audit skill to drive the csharp-lsp MCP if reachable.
    # A defer-to-mcp stub (not a bare fallback) tells setup-audit it may still get real symbols.
    emit_stub "defer-to-mcp" "no-treesitter-csharp"
    echo "repomap: defer-to-mcp — setup-audit should call mcp__csharp-lsp__csharp_symbols; falls back to llm-only if unreachable (stub written to $OUT)" >&2
    exit 0
    ;;
  python)
    if python3 -c "import tree_sitter_python" 2>/dev/null; then
      python3 "$SCRIPT_DIR/repomap-tree-sitter.py" --stack python --budget "$BUDGET" --out "$OUT"
      exit $?
    fi
    emit_fallback "no-treesitter-python"
    ;;
  typescript)
    if python3 -c "import tree_sitter_typescript" 2>/dev/null; then
      python3 "$SCRIPT_DIR/repomap-tree-sitter.py" --stack typescript --budget "$BUDGET" --out "$OUT"
      exit $?
    fi
    emit_fallback "no-treesitter-typescript"
    ;;
  *)
    emit_fallback "unknown-stack:${STACK}"
    ;;
esac
