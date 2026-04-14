---
paths:
  - "**/*.ts"
  - "**/*.tsx"
  - "**/tsconfig.json"
  - "**/biome.json"
---

# TypeScript Analyzer Configuration

Recommended type checker and linter configuration for serious TypeScript software.

## Recommended Tools

### TypeScript Strict Mode

Enable in `tsconfig.json`:

```json
{
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true,
    "exactOptionalPropertyTypes": true,
    "noFallthroughCasesInSwitch": true,
    "forceConsistentCasingInFileNames": true
  }
}
```

### Biome (linter + formatter)

Add `biome.json`:

```json
{
  "linter": {
    "enabled": true,
    "rules": {
      "recommended": true,
      "suspicious": { "noExplicitAny": "error" },
      "complexity": { "noBannedTypes": "error" },
      "security": { "noDangerouslySetInnerHtml": "error" }
    }
  }
}
```

## Critical Rules

| Rule | Tool | What It Catches | Severity |
|------|------|----------------|----------|
| TS7006 | tsc | Implicit `any` parameter | error |
| TS2345 | tsc | Argument type mismatch | error |
| noExplicitAny | biome | Use of `any` type | error |
| noDangerouslySetInnerHtml | biome | XSS vulnerability | critical |
| noConsoleLog | biome | Console output in production | warning |

## Integration with MTK

```bash
npx tsc --noEmit 2>&1 | hooks/parse-build-diagnostics.sh --format tsc > .mtk/analyzer-output.json
```
