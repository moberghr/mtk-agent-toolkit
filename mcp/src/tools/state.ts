// state.ts — five read-only tools that expose canonical MTK state to agents.
// Read-only by construction; the validator grep gate enforces this.
// Bash fallback for every tool is documented in docs/integrations/mtk-mcp.md.

import { readFileSync, existsSync } from "fs";
import { join } from "path";

type ToolResult = {
  content: Array<{ type: "text"; text: string }>;
};

function asJson(payload: unknown): ToolResult {
  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(payload, null, 2),
      },
    ],
  };
}

function readJsonFile(path: string): unknown | null {
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf-8"));
  } catch (err) {
    return { __parse_error: (err as Error).message, path };
  }
}

function readTextFile(path: string): string | null {
  if (!existsSync(path)) return null;
  return readFileSync(path, "utf-8");
}

// -----------------------------------------------------------------------------
// mtk_manifest — .claude/manifest.json
// -----------------------------------------------------------------------------
export async function manifest(): Promise<ToolResult> {
  const cwd = process.cwd();
  const path = join(cwd, ".claude", "manifest.json");
  const data = readJsonFile(path);
  if (data === null) {
    return asJson({ error: "manifest not found", path });
  }
  return asJson(data);
}

// -----------------------------------------------------------------------------
// mtk_analytics — .claude/analytics.json
// -----------------------------------------------------------------------------
export async function analytics(): Promise<ToolResult> {
  const cwd = process.cwd();
  const path = join(cwd, ".claude", "analytics.json");
  const data = readJsonFile(path);
  if (data === null) {
    return asJson({ error: "analytics not found", path });
  }
  return asJson(data);
}

// -----------------------------------------------------------------------------
// mtk_audit — parse architecture-principles.md into tagged principles
// -----------------------------------------------------------------------------
const TAG_RE = /\[(EXTRACTED|INFERRED:[0-9.]+|AMBIGUOUS)\]/;

function parsePrinciples(raw: string): Array<Record<string, unknown>> {
  const principles: Array<Record<string, unknown>> = [];
  const lines = raw.split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("-")) continue;
    const match = trimmed.match(TAG_RE);
    if (!match) continue;
    const tag = match[1];
    let kind: "EXTRACTED" | "INFERRED" | "AMBIGUOUS" = "EXTRACTED";
    let confidence: number | null = null;
    if (tag === "EXTRACTED") {
      kind = "EXTRACTED";
      confidence = 1.0;
    } else if (tag === "AMBIGUOUS") {
      kind = "AMBIGUOUS";
    } else {
      kind = "INFERRED";
      const parts = tag.split(":");
      const parsed = Number.parseFloat(parts[1]);
      confidence = Number.isFinite(parsed) ? parsed : null;
    }
    const body = trimmed.replace(/^-+\s*/, "").replace(TAG_RE, "").trim();
    let evidence: string | null = null;
    const evidenceMatch = body.match(/Evidence:\s*(.+)$/i);
    let statement = body;
    if (evidenceMatch) {
      evidence = evidenceMatch[1].trim();
      statement = body.slice(0, evidenceMatch.index).replace(/[.\s]+$/, "").trim();
    }
    principles.push({ tag: kind, confidence, statement, evidence });
  }
  return principles;
}

export async function audit(): Promise<ToolResult> {
  const cwd = process.cwd();
  const path = join(cwd, ".claude", "references", "architecture-principles.md");
  const raw = readTextFile(path);
  if (raw === null) {
    return asJson({ error: "audit not found", path, principles: [] });
  }
  return asJson({
    path,
    principles: parsePrinciples(raw),
    raw,
  });
}

// -----------------------------------------------------------------------------
// mtk_references_index — parse .claude/references.index TSV
// -----------------------------------------------------------------------------
export async function referencesIndex(): Promise<ToolResult> {
  const cwd = process.cwd();
  const path = join(cwd, ".claude", "references.index");
  const raw = readTextFile(path);
  if (raw === null) {
    return asJson({ error: "references.index not found", path, entries: [] });
  }
  const entries: Array<Record<string, unknown>> = [];
  const lines = raw.split(/\r?\n/).filter((line) => line && !line.startsWith("#"));
  for (const line of lines) {
    const cols = line.split("\t");
    if (cols.length < 4) continue;
    const [filePath, alwaysApply, description, globs] = cols;
    entries.push({
      path: filePath,
      alwaysApply: alwaysApply === "true",
      description,
      globs: globs.split(",").map((g) => g.trim()).filter(Boolean),
    });
  }
  return asJson({ path, entries });
}

// -----------------------------------------------------------------------------
// mtk_active_stack — .claude/tech-stack
// -----------------------------------------------------------------------------
export async function activeStack(): Promise<ToolResult> {
  const cwd = process.cwd();
  const path = join(cwd, ".claude", "tech-stack");
  const raw = readTextFile(path);
  if (raw === null) {
    return asJson({ stack: null, path });
  }
  const stack = raw.replace(/\s+/g, "");
  return asJson({ stack: stack || null, path });
}
