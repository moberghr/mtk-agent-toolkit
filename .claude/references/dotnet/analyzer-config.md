---
description: .NET analyzer configuration (Directory.Build.props, .editorconfig conventions)
globs: ["**/*.cs", "**/*.csproj", "**/Directory.Build.props"]
alwaysApply: false
---
# .NET Analyzer Configuration

Recommended Roslyn analyzer packages and configuration for serious .NET software. These analyzers surface semantic issues that regex-based linting cannot detect.

## Recommended Packages

Add to `Directory.Build.props` to apply across all projects:

```xml
<ItemGroup>
  <PackageReference Include="Microsoft.CodeAnalysis.NetAnalyzers" Version="9.*" />
  <PackageReference Include="Microsoft.EntityFrameworkCore.Analyzers" Version="9.*" />
  <PackageReference Include="Meziantou.Analyzer" Version="2.*" />
  <PackageReference Include="Roslynator.Analyzers" Version="4.*" />
  <PackageReference Include="StyleCop.Analyzers" Version="1.*" />
  <PackageReference Include="SonarAnalyzer.CSharp" Version="9.*" />
</ItemGroup>

<PropertyGroup>
  <EnableNETAnalyzers>true</EnableNETAnalyzers>
  <AnalysisLevel>latest-recommended</AnalysisLevel>
  <EnforceCodeStyleInBuild>true</EnforceCodeStyleInBuild>
</PropertyGroup>
```

## Critical Rules to Enable

These rules catch issues the toolkit's coding guidelines specifically call out:

| Rule ID | Package | What It Catches | Recommended Severity |
|---------|---------|----------------|---------------------|
| EF1001 | EF Core Analyzers | Client-side evaluation (LINQ evaluated in memory, not DB) | error |
| CA2007 | NetAnalyzers | Missing ConfigureAwait on awaited tasks | warning |
| CA1848 | NetAnalyzers | Use LoggerMessage delegates for high-perf logging | suggestion |
| CA2100 | NetAnalyzers | SQL injection vulnerability in raw queries | error |
| CA1816 | NetAnalyzers | Dispose pattern violations | warning |
| CA2000 | NetAnalyzers | Dispose objects before losing scope | warning |
| VSTHRD100 | Thread Safety | Async void methods (should be async Task) | error |
| MA0004 | Meziantou | Use ConfigureAwait(false) in library code | warning |
| MA0006 | Meziantou | Use string.Equals with StringComparison | suggestion |
| RCS1090 | Roslynator | Add call to ConfigureAwait | warning |

## .editorconfig Severity Overrides

Add to `.editorconfig` at the solution root to enforce critical rules:

```ini
# EF Core — client-side evaluation is always a bug in production
dotnet_diagnostic.EF1001.severity = error

# SQL injection — never acceptable
dotnet_diagnostic.CA2100.severity = error

# Async void — crashes instead of throwing
dotnet_diagnostic.VSTHRD100.severity = error

# Dispose violations — resource leaks
dotnet_diagnostic.CA2000.severity = warning
dotnet_diagnostic.CA1816.severity = warning
```

## The analyzer wall — most common warnings-as-errors failures

In a repo with `TreatWarningsAsErrors` plus StyleCop + SonarAnalyzer, the *analyzer wall* — not MTK's own rules — is what actually catches most build-gate failures during an implementation run. In one six-phase field port, **every** build repair cycle (21 of 21) was one of these analyzers, and none was documented anywhere in `.claude/`, so each phase re-diagnosed the same handful from scratch. Write the common ones down; it removes most of the repair cycles outright.

These are the recurring offenders and the fix that clears each (the fix, not a suppression — reach for `#pragma`/`// NOSONAR` only when the rule is genuinely wrong for the case):

| Rule | Package | What it flags | Fix |
|---|---|---|---|
| SA1118 | StyleCop | A single argument spans multiple lines | Extract the multi-line expression into a local, pass the local |
| SA1512 | StyleCop | A single-line comment is followed by a blank line | Remove the blank line after the comment |
| SA1514 | StyleCop | A documentation header is not preceded by a blank line | Add a blank line before the `///` block |
| S125 | Sonar | Commented-out code | Delete it — version control is the archive, not a comment |
| S3267 | Sonar | A loop that could be a LINQ `Where`/`Select` | Rewrite as the LINQ expression, or justify and suppress |
| S1172 | Sonar | Unused method parameter | Remove it, or `_`-discard if an interface forces the signature |
| MA0006 | Meziantou | `==` on strings instead of `string.Equals` | Use `string.Equals(a, b, StringComparison.Ordinal)` |
| CA1852 | NetAnalyzers | Internal type can be sealed | Add `sealed` |

**The SA1512 / SA1514 collision.** A banner `//` comment placed directly above a `///` doc comment is unfixable by satisfying both rules: SA1512 forbids the blank line *after* the banner, and SA1514 demands the blank line *before* the doc comment — the same line cannot be both present and absent. Do not stack a banner comment immediately above a documentation comment; move the banner elsewhere or fold it into the `///` summary. This collision surfaces **only under `dotnet format`**, not under `dotnet build` (see below).

## `dotnet format --verify-no-changes` is a separate gate from `dotnet build`

A green `dotnet build` — even with warnings-as-errors — is **not** evidence that `dotnet format --verify-no-changes` will pass. They run different analyzer sets: `build` enforces the compiler + analyzer diagnostics wired into the build, while `format` enforces whitespace/layout/`.editorconfig` rules (many StyleCop `SAxxxx` layout rules, and collisions like SA1512/SA1514 above) that the build never evaluates. Run **both** as independent gates in every implementation loop; treating build-green as format-green is a recurring, avoidable end-of-phase failure.

Never run a bare `dotnet format` to "just fix it" — analyzer code-fixes can rewrite far more than layout (a documented incident had it rewrite every `DbSet<T>` declaration as nullable). Use `--verify-no-changes` to detect, then fix the specific reported lines by hand.

## Integration with MTK

Build output from `dotnet build` includes these analyzer warnings. The toolkit's `hooks/parse-build-diagnostics.sh` parser converts them into review-finding-schema findings with `source: "analyzer"` and `confidence: 100`.

During the implement workflow's batches, pipe build output to capture analyzer findings:
```bash
dotnet build 2>&1 | tee /dev/tty | hooks/parse-build-diagnostics.sh > .mtk/analyzer-output.json
```
