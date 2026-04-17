---
paths:
  - "**/*.cs"
  - "**/*.csproj"
  - "**/Directory.Build.props"
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

## Integration with MTK

Build output from `dotnet build` includes these analyzer warnings. The toolkit's `hooks/parse-build-diagnostics.sh` parser converts them into review-finding-schema findings with `source: "analyzer"` and `confidence: 100`.

During the implement workflow's batches, pipe build output to capture analyzer findings:
```bash
dotnet build 2>&1 | tee /dev/tty | hooks/parse-build-diagnostics.sh > .mtk/analyzer-output.json
```
