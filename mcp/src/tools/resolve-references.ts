import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { minimatch } from "minimatch";

interface ManifestEntry {
  source: string;
  target: string;
  action: string;
  description: string;
  applyTo?: string[];
  stack?: string;
}

interface ManifestFile {
  files: Record<string, ManifestEntry>;
}

interface ResolvedReference {
  path: string;
  description: string;
  matchedBy: string; // The applyTo glob that matched
  matchedFile: string; // The input file that triggered the match
}

interface ResolveResult {
  references: ResolvedReference[];
  alwaysOn: Array<{ path: string; description: string }>;
  activeStack: string | null;
  techStackSkill: string | null;
}

export async function resolveReferences(args: { files: string[] }) {
  const cwd = process.cwd();
  const manifestPath = join(cwd, ".claude", "manifest.json");

  if (!existsSync(manifestPath)) {
    return {
      content: [
        {
          type: "text" as const,
          text: JSON.stringify({
            error: "No .claude/manifest.json found in current directory",
            fallback: "Use manual glob matching per context-engineering skill",
          }),
        },
      ],
    };
  }

  const manifest: ManifestFile = JSON.parse(readFileSync(manifestPath, "utf-8"));

  // Detect active tech stack
  const techStackPath = join(cwd, ".claude", "tech-stack");
  const activeStack = existsSync(techStackPath)
    ? readFileSync(techStackPath, "utf-8").trim()
    : null;

  const result: ResolveResult = {
    references: [],
    alwaysOn: [],
    activeStack,
    techStackSkill: activeStack
      ? `.claude/skills/tech-stack-${activeStack}/SKILL.md`
      : null,
  };

  const seen = new Set<string>();

  for (const [, entry] of Object.entries(manifest.files)) {
    // Skip non-reference files
    if (!entry.source.includes("references/") && !entry.source.includes("rules/")) {
      continue;
    }

    // Skip stack-filtered files that don't match active stack
    if (entry.stack && activeStack && entry.stack !== activeStack) {
      continue;
    }

    if (entry.applyTo && entry.applyTo.length > 0) {
      // Path-scoped reference — match against input files
      for (const glob of entry.applyTo) {
        for (const file of args.files) {
          if (minimatch(file, glob, { matchBase: true })) {
            const key = entry.source;
            if (!seen.has(key)) {
              seen.add(key);
              result.references.push({
                path: entry.source,
                description: entry.description,
                matchedBy: glob,
                matchedFile: file,
              });
            }
          }
        }
      }
    } else {
      // Always-on reference (no applyTo) — include if path exists
      const fullPath = join(cwd, entry.source);
      if (existsSync(fullPath) && !seen.has(entry.source)) {
        seen.add(entry.source);
        result.alwaysOn.push({
          path: entry.source,
          description: entry.description,
        });
      }
    }
  }

  return {
    content: [
      {
        type: "text" as const,
        text: JSON.stringify(result, null, 2),
      },
    ],
  };
}
