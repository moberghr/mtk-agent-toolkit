#!/usr/bin/env bash
set -euo pipefail

QUIET="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_DIR="$ROOT_DIR/mcp"
DIST_DIR="$ROOT_DIR/dist"

log() { [ "$QUIET" = "--quiet" ] || echo "$@"; }
log_err() { echo "$@" >&2; }

if [ ! -d "$MCP_DIR" ]; then
  log_err "ERROR: mcp/ directory not found"
  exit 1
fi

# Require node
if ! command -v node >/dev/null 2>&1; then
  log_err "ERROR: node not found — MCP server requires Node.js >= 18"
  exit 1
fi

cd "$MCP_DIR"

# Install deps if needed
if [ ! -d "node_modules" ]; then
  log "Installing MCP dependencies..."
  npm install --no-audit --no-fund ${QUIET:+--silent} 2>&1 | { [ "$QUIET" = "--quiet" ] && cat >/dev/null || cat; }
fi

# Build
log "Building MCP server..."
mkdir -p "$DIST_DIR"
npm run build ${QUIET:+--silent} 2>&1 | { [ "$QUIET" = "--quiet" ] && cat >/dev/null || cat; }

# Verify output
if [ ! -f "$DIST_DIR/mtk-mcp-server.cjs" ]; then
  log_err "ERROR: Build failed — dist/mtk-mcp-server.cjs not created"
  exit 1
fi

chmod +x "$DIST_DIR/mtk-mcp-server.cjs"
log "MCP server built: dist/mtk-mcp-server.cjs ($(wc -c < "$DIST_DIR/mtk-mcp-server.cjs") bytes)"
