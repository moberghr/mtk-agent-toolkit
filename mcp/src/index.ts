import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { resolveReferences } from "./tools/resolve-references.js";
import { solutionStructure } from "./tools/solution-structure.js";
import {
  manifest,
  analytics,
  audit,
  referencesIndex,
  activeStack,
} from "./tools/state.js";

const server = new Server(
  { name: "mtk-context", version: "0.2.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "mtk_resolve_references",
      description:
        "Given a list of file paths, returns which MTK reference documents should be loaded based on manifest applyTo glob matching. Replaces manual glob matching in context-engineering skill.",
      inputSchema: {
        type: "object" as const,
        properties: {
          files: {
            type: "array",
            items: { type: "string" },
            description: "List of file paths to match against manifest applyTo globs",
          },
        },
        required: ["files"],
      },
    },
    {
      name: "mtk_solution_structure",
      description:
        "Parses the project/solution structure and returns projects, dependencies, and test projects. Supports .NET (.sln/.csproj), Python (pyproject.toml), and TypeScript (package.json workspaces).",
      inputSchema: {
        type: "object" as const,
        properties: {
          filter: {
            type: "string",
            description: "Optional filter: project name or module path to scope results",
          },
        },
      },
    },
    {
      name: "mtk_manifest",
      description: "Returns parsed contents of .claude/manifest.json (toolkit version, file inventory, protected paths). Read-only.",
      inputSchema: { type: "object" as const, properties: {} },
    },
    {
      name: "mtk_analytics",
      description: "Returns parsed contents of .claude/analytics.json (toolkit usage stats). Read-only.",
      inputSchema: { type: "object" as const, properties: {} },
    },
    {
      name: "mtk_audit",
      description: "Returns architecture-principles.md as a structured list of tagged principles ({tag, confidence, statement, evidence}) plus the raw markdown. Read-only.",
      inputSchema: { type: "object" as const, properties: {} },
    },
    {
      name: "mtk_references_index",
      description: "Returns parsed entries from .claude/references.index (path, alwaysApply, description, globs). Read-only.",
      inputSchema: { type: "object" as const, properties: {} },
    },
    {
      name: "mtk_active_stack",
      description: "Returns the active tech stack name from .claude/tech-stack (e.g. dotnet, python, typescript). Read-only.",
      inputSchema: { type: "object" as const, properties: {} },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "mtk_resolve_references":
      return resolveReferences(args as { files: string[] });
    case "mtk_solution_structure":
      return solutionStructure(args as { filter?: string });
    case "mtk_manifest":
      return manifest();
    case "mtk_analytics":
      return analytics();
    case "mtk_audit":
      return audit();
    case "mtk_references_index":
      return referencesIndex();
    case "mtk_active_stack":
      return activeStack();
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((error) => {
  console.error("MTK MCP server error:", error);
  process.exit(1);
});
