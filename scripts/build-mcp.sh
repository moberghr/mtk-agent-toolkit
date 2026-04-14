#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MCP_DIR="$ROOT_DIR/mcp"
DIST_DIR="$ROOT_DIR/dist"

if [ ! -d "$MCP_DIR" ]; then
  echo "ERROR: mcp/ directory not found" >&2
  exit 1
fi

cd "$MCP_DIR"

# Install deps if needed
if [ ! -d "node_modules" ]; then
  echo "Installing MCP dependencies..."
  npm install
fi

# Build
echo "Building MCP server..."
npm run build

# Verify output
if [ ! -f "$DIST_DIR/mtk-mcp-server.cjs" ]; then
  echo "ERROR: Build failed — dist/mtk-mcp-server.cjs not created" >&2
  exit 1
fi

chmod +x "$DIST_DIR/mtk-mcp-server.cjs"
echo "MCP server built: dist/mtk-mcp-server.cjs ($(wc -c < "$DIST_DIR/mtk-mcp-server.cjs") bytes)"
