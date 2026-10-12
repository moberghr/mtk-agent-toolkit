import { readFileSync, existsSync, readdirSync, statSync } from "fs";
import { join, basename, dirname, relative } from "path";

interface Project {
  name: string;
  path: string;
  type: "source" | "test" | "shared" | "unknown";
  dependencies: string[];
}

interface SolutionStructure {
  format: "dotnet" | "python" | "typescript" | "unknown";
  root: string;
  projects: Project[];
  testProjects: string[];
  sharedProjects: string[];
}

function parseDotnetSolution(cwd: string): SolutionStructure {
  const result: SolutionStructure = {
    format: "dotnet",
    root: cwd,
    projects: [],
    testProjects: [],
    sharedProjects: [],
  };

  // Find .sln or .slnx files
  const slnFiles = readdirSync(cwd).filter(
    (f) => f.endsWith(".sln") || f.endsWith(".slnx")
  );

  if (slnFiles.length === 0) {
    // Try to find .csproj files directly
    findCsprojFiles(cwd, cwd, result);
    return result;
  }

  const slnContent = readFileSync(join(cwd, slnFiles[0]), "utf-8");

  // Parse .sln format: Project("{GUID}") = "Name", "Path.csproj", "{GUID}"
  const projectRegex =
    /Project\("[^"]*"\)\s*=\s*"([^"]+)",\s*"([^"]+)"/g;
  let match;

  while ((match = projectRegex.exec(slnContent)) !== null) {
    const name = match[1];
    const projectPath = match[2].replace(/\\/g, "/");

    if (!projectPath.endsWith(".csproj")) continue;

    const fullPath = join(cwd, projectPath);
    if (!existsSync(fullPath)) continue;

    const project = parseCsproj(cwd, fullPath, name);
    result.projects.push(project);

    if (project.type === "test") {
      result.testProjects.push(project.name);
    } else if (project.type === "shared") {
      result.sharedProjects.push(project.name);
    }
  }

  return result;
}

function parseCsproj(
  solutionRoot: string,
  csprojPath: string,
  name: string
): Project {
  const content = readFileSync(csprojPath, "utf-8");
  const relPath = relative(solutionRoot, csprojPath);

  // Determine project type from name and content
  const isTest =
    /test/i.test(name) ||
    content.includes("Microsoft.NET.Test.Sdk") ||
    content.includes("xunit") ||
    content.includes("NUnit");

  const isShared =
    /shared|common|core\.abstractions/i.test(name) ||
    relPath.startsWith("shared/");

  // Extract ProjectReference dependencies
  const deps: string[] = [];
  const refRegex = /<ProjectReference\s+Include="([^"]+)"/g;
  let refMatch;
  while ((refMatch = refRegex.exec(content)) !== null) {
    const refPath = refMatch[1].replace(/\\/g, "/");
    // Extract project name from path
    const refName = basename(refPath, ".csproj");
    deps.push(refName);
  }

  return {
    name,
    path: relPath,
    type: isTest ? "test" : isShared ? "shared" : "source",
    dependencies: deps,
  };
}

function findCsprojFiles(
  root: string,
  dir: string,
  result: SolutionStructure
): void {
  try {
    const entries = readdirSync(dir);
    for (const entry of entries) {
      if (
        entry === "node_modules" ||
        entry === "bin" ||
        entry === "obj" ||
        entry.startsWith(".")
      )
        continue;
      const fullPath = join(dir, entry);
      const stat = statSync(fullPath);
      if (stat.isDirectory()) {
        findCsprojFiles(root, fullPath, result);
      } else if (entry.endsWith(".csproj")) {
        const name = basename(entry, ".csproj");
        const project = parseCsproj(root, fullPath, name);
        result.projects.push(project);
        if (project.type === "test") result.testProjects.push(name);
        if (project.type === "shared") result.sharedProjects.push(name);
      }
    }
  } catch {
    // Permission errors or similar — skip
  }
}

function parsePythonProject(cwd: string): SolutionStructure {
  const result: SolutionStructure = {
    format: "python",
    root: cwd,
    projects: [],
    testProjects: [],
    sharedProjects: [],
  };

  const pyprojectPath = join(cwd, "pyproject.toml");
  if (existsSync(pyprojectPath)) {
    const content = readFileSync(pyprojectPath, "utf-8");
    const nameMatch = content.match(/^name\s*=\s*"([^"]+)"/m);
    const name = nameMatch ? nameMatch[1] : basename(cwd);
    result.projects.push({
      name,
      path: ".",
      type: "source",
      dependencies: [],
    });
  }

  // Detect test directories
  for (const testDir of ["tests", "test"]) {
    if (existsSync(join(cwd, testDir))) {
      result.testProjects.push(testDir);
      result.projects.push({
        name: testDir,
        path: testDir,
        type: "test",
        dependencies: [],
      });
    }
  }

  return result;
}

function parseTypeScriptProject(cwd: string): SolutionStructure {
  const result: SolutionStructure = {
    format: "typescript",
    root: cwd,
    projects: [],
    testProjects: [],
    sharedProjects: [],
  };

  const pkgPath = join(cwd, "package.json");
  if (!existsSync(pkgPath)) return result;

  const pkg = JSON.parse(readFileSync(pkgPath, "utf-8"));

  // Check for workspaces (monorepo)
  const workspaces: string[] = Array.isArray(pkg.workspaces)
    ? pkg.workspaces
    : pkg.workspaces?.packages || [];

  if (workspaces.length > 0) {
    // Resolve workspace globs
    for (const ws of workspaces) {
      const wsBase = ws.replace(/\/\*$/, "");
      const wsDir = join(cwd, wsBase);
      if (!existsSync(wsDir)) continue;

      try {
        const entries = readdirSync(wsDir);
        for (const entry of entries) {
          const entryPath = join(wsDir, entry);
          const entryPkgPath = join(entryPath, "package.json");
          if (existsSync(entryPkgPath)) {
            const entryPkg = JSON.parse(
              readFileSync(entryPkgPath, "utf-8")
            );
            const name = entryPkg.name || entry;
            const isTest = /test/i.test(name) || /test/i.test(entry);
            const relPath = relative(cwd, entryPath);

            result.projects.push({
              name,
              path: relPath,
              type: isTest ? "test" : "source",
              dependencies: Object.keys(entryPkg.dependencies || {}),
            });

            if (isTest) result.testProjects.push(name);
          }
        }
      } catch {
        // Skip unreadable directories
      }
    }
  } else {
    // Single-package project
    result.projects.push({
      name: pkg.name || basename(cwd),
      path: ".",
      type: "source",
      dependencies: Object.keys(pkg.dependencies || {}),
    });
  }

  return result;
}

export async function solutionStructure(args: { filter?: string }) {
  const cwd = process.cwd();

  // Detect project type
  let structure: SolutionStructure;

  const hasSln = readdirSync(cwd).some(
    (f) => f.endsWith(".sln") || f.endsWith(".slnx")
  );
  const hasCsproj = readdirSync(cwd).some((f) => f.endsWith(".csproj"));
  const hasPyproject = existsSync(join(cwd, "pyproject.toml"));
  const hasPkgJson = existsSync(join(cwd, "package.json"));

  if (hasSln || hasCsproj) {
    structure = parseDotnetSolution(cwd);
  } else if (hasPyproject) {
    structure = parsePythonProject(cwd);
  } else if (hasPkgJson) {
    structure = parseTypeScriptProject(cwd);
  } else {
    return {
      content: [
        {
          type: "text" as const,
          text: JSON.stringify({
            format: "unknown",
            error: "No recognized project structure found (.sln, .csproj, pyproject.toml, package.json)",
          }),
        },
      ],
    };
  }

  // Apply filter if provided
  if (args.filter) {
    const filter = args.filter.toLowerCase();
    structure.projects = structure.projects.filter(
      (p) =>
        p.name.toLowerCase().includes(filter) ||
        p.path.toLowerCase().includes(filter)
    );
  }

  return {
    content: [
      {
        type: "text" as const,
        text: JSON.stringify(structure, null, 2),
      },
    ],
  };
}
