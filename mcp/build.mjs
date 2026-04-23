#!/usr/bin/env node
// Build entry point for the MTK MCP server.
//
// Invoked via `npm run build`. Uses esbuild's JS API instead of the CLI so the
// banner string (which contains characters that cmd.exe mangles under single
// quotes) is passed in-process and stays portable across bash, zsh, and cmd.
import { build } from "esbuild";

await build({
  entryPoints: ["src/index.ts"],
  bundle: true,
  platform: "node",
  target: "node18",
  format: "cjs",
  outfile: "../dist/mtk-mcp-server.cjs",
  banner: { js: "#!/usr/bin/env node" },
});
