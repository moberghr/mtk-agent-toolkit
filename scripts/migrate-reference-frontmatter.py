#!/usr/bin/env python3
"""One-shot migration: ensure every .claude/references/**/*.md has
YAML frontmatter with `description`, `globs`, `alwaysApply` fields.

Rewrites existing `paths:` lists into `globs:` (same semantics, new name).
Runs idempotently. Not kept in the toolkit long-term — delete after v7.0.0
ships and every downstream repo has re-run setup.
"""
from __future__ import annotations
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REF_DIR = ROOT / ".claude" / "references"

# Per-file defaults. Keys are relative to .claude/references/.
DEFAULTS: dict[str, dict[str, object]] = {
    "domain-finance.md": {
        "description": "Finance domain supplement — money/payment/ledger invariants and audit requirements",
        "globs": ["**/Money*.cs", "**/Payment*.cs", "**/Ledger*.cs", "**/*Transaction*.py", "**/*.test.ts"],
        "alwaysApply": False,
    },
    "security-checklist.md": {
        "description": "Baseline security checklist for any serious software change",
        "globs": ["**/*"],
        "alwaysApply": True,
    },
    "performance-checklist.md": {
        "description": "Generic performance checklist — applies to hot paths and release-blocking changes",
        "globs": ["**/*"],
        "alwaysApply": False,
    },
    "testing-patterns.md": {
        "description": "Generic testing guidance — patterns, coverage heuristics, anti-patterns",
        "globs": ["**/*Test*", "**/*test_*", "**/*.spec.*", "**/*.test.*"],
        "alwaysApply": False,
    },
    "recommended-tooling.md": {
        "description": "Cross-stack recommended tooling (shellcheck, shfmt, jq, etc.)",
        "globs": ["**/*"],
        "alwaysApply": False,
    },
    "pre-commit-review-list.md": {
        "description": "Critical rules checked by the pre-commit-review skill before every commit",
        "globs": ["**/*"],
        "alwaysApply": False,
    },
    "review-finding-schema.md": {
        "description": "Schema for review findings emitted by code-review-and-quality",
        "globs": ["**/*"],
        "alwaysApply": False,
    },
    # .NET stack
    "dotnet/coding-guidelines.md": {
        "description": ".NET coding guidelines (pulled from moberghr/coding-guidelines at pinned SHA)",
        "globs": ["**/*.cs", "**/*.csproj"],
        "alwaysApply": False,
    },
    "dotnet/ef-core-checklist.md": {
        "description": "EF Core checklist — NoTracking, query splitting, migrations, projection pitfalls",
        "globs": ["**/*.cs", "**/Migrations/**/*.cs"],
        "alwaysApply": False,
    },
    "dotnet/mediatr-slice-patterns.md": {
        "description": "MediatR vertical-slice patterns for CQRS handler design",
        "globs": ["**/Handlers/**/*.cs", "**/Features/**/*.cs"],
        "alwaysApply": False,
    },
    "dotnet/performance-supplement.md": {
        "description": ".NET-specific performance guidance — allocation, Span<T>, async, EF query shape",
        "globs": ["**/*.cs"],
        "alwaysApply": False,
    },
    "dotnet/recommended-tooling.md": {
        "description": ".NET recommended tooling (dotnet-format, BenchmarkDotNet, Verify, etc.)",
        "globs": ["**/*.cs", "**/*.csproj"],
        "alwaysApply": False,
    },
    "dotnet/testing-supplement.md": {
        "description": ".NET testing supplement — xUnit, fixtures, TestContainers, snapshot testing",
        "globs": ["**/*Tests.cs", "**/*.Tests/**/*.cs"],
        "alwaysApply": False,
    },
    "dotnet/analyzer-config.md": {
        "description": ".NET analyzer configuration (Directory.Build.props, .editorconfig conventions)",
        "globs": ["**/*.cs", "**/*.csproj", "**/Directory.Build.props"],
        "alwaysApply": False,
    },
    # Python stack
    "python/coding-guidelines.md": {
        "description": "Python coding guidelines (placeholder until team formalizes)",
        "globs": ["**/*.py"],
        "alwaysApply": False,
    },
    "python/fastapi-patterns.md": {
        "description": "FastAPI patterns — dependency injection, pydantic models, router composition",
        "globs": ["**/*.py"],
        "alwaysApply": False,
    },
    "python/performance-supplement.md": {
        "description": "Python performance guidance — async, C extensions, profiler usage",
        "globs": ["**/*.py"],
        "alwaysApply": False,
    },
    "python/recommended-tooling.md": {
        "description": "Python recommended tooling (ruff, mypy, pytest, uv)",
        "globs": ["**/*.py", "**/pyproject.toml"],
        "alwaysApply": False,
    },
    "python/sqlalchemy-checklist.md": {
        "description": "SQLAlchemy checklist — session scope, N+1, eager loading, migrations",
        "globs": ["**/*.py"],
        "alwaysApply": False,
    },
    "python/testing-supplement.md": {
        "description": "Python testing supplement — pytest fixtures, parametrize, hypothesis",
        "globs": ["**/test_*.py", "**/*_test.py", "**/tests/**/*.py"],
        "alwaysApply": False,
    },
    "python/analyzer-config.md": {
        "description": "Python analyzer configuration (ruff.toml, pyproject.toml)",
        "globs": ["**/*.py", "**/pyproject.toml", "**/ruff.toml"],
        "alwaysApply": False,
    },
    # TypeScript stack
    "typescript/coding-guidelines.md": {
        "description": "TypeScript coding guidelines (strict tsconfig, Biome, ESM, naming)",
        "globs": ["**/*.ts", "**/*.tsx"],
        "alwaysApply": False,
    },
    "typescript/data-layer-checklist.md": {
        "description": "TypeScript data-layer checklist (Drizzle/Prisma/Kysely conventions)",
        "globs": ["**/*.ts"],
        "alwaysApply": False,
    },
    "typescript/framework-patterns.md": {
        "description": "TypeScript framework patterns (React, Next.js, Tauri, Node)",
        "globs": ["**/*.ts", "**/*.tsx"],
        "alwaysApply": False,
    },
    "typescript/performance-supplement.md": {
        "description": "TypeScript performance guidance — bundle size, render perf, memo patterns",
        "globs": ["**/*.ts", "**/*.tsx"],
        "alwaysApply": False,
    },
    "typescript/recommended-tooling.md": {
        "description": "TypeScript recommended tooling (Biome, Vitest, Playwright)",
        "globs": ["**/*.ts", "**/*.tsx", "**/package.json"],
        "alwaysApply": False,
    },
    "typescript/testing-supplement.md": {
        "description": "TypeScript testing supplement — Vitest, Testing Library, Playwright",
        "globs": ["**/*.test.ts", "**/*.spec.ts", "**/*.test.tsx"],
        "alwaysApply": False,
    },
    "typescript/analyzer-config.md": {
        "description": "TypeScript analyzer configuration (tsconfig.json, biome.json)",
        "globs": ["**/*.ts", "**/*.tsx", "**/tsconfig.json", "**/biome.json"],
        "alwaysApply": False,
    },
}


FM_RE = re.compile(r"^---\n(.*?\n)---\n", re.DOTALL)


def build_frontmatter(desc: str, globs: list[str], always: bool) -> str:
    globs_inline = "[" + ", ".join(f'"{g}"' for g in globs) + "]"
    always_str = "true" if always else "false"
    return (
        "---\n"
        f"description: {desc}\n"
        f"globs: {globs_inline}\n"
        f"alwaysApply: {always_str}\n"
        "---\n"
    )


def migrate(file: Path) -> bool:
    rel = file.relative_to(REF_DIR).as_posix()
    defaults = DEFAULTS.get(rel)
    if not defaults:
        print(f"WARN: no defaults for {rel}", file=sys.stderr)
        return False
    body = file.read_text()
    m = FM_RE.match(body)
    remainder = body[m.end():] if m else body
    # Check if already in new format
    if m and "description:" in m.group(1) and "globs:" in m.group(1) and "alwaysApply:" in m.group(1):
        # Already migrated — leave as-is
        return False
    new_fm = build_frontmatter(defaults["description"], defaults["globs"], defaults["alwaysApply"])  # type: ignore[arg-type]
    file.write_text(new_fm + remainder.lstrip("\n"))
    return True


def main() -> int:
    changed = 0
    for file in sorted(REF_DIR.rglob("*.md")):
        if migrate(file):
            changed += 1
            print(f"migrated: {file.relative_to(ROOT)}")
    print(f"done — {changed} file(s) updated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
