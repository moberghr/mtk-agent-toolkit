---
paths:
  - "**/*.py"
  - "**/pyproject.toml"
  - "**/ruff.toml"
---

# Python Analyzer Configuration

Recommended linter and type checker configuration for serious Python software.

## Recommended Tools

### ruff (linter + formatter)

Add to `pyproject.toml`:

```toml
[tool.ruff]
target-version = "py312"
line-length = 120

[tool.ruff.lint]
select = [
  "E",    # pycodestyle errors
  "F",    # pyflakes
  "I",    # isort
  "N",    # pep8-naming
  "S",    # bandit security
  "B",    # bugbear
  "A",    # builtins shadowing
  "C4",   # comprehension simplification
  "PT",   # pytest style
  "RET",  # return statement consistency
  "SIM",  # code simplification
  "ARG",  # unused arguments
  "ERA",  # commented-out code
  "PL",   # pylint rules
]
```

### mypy (type checker)

```toml
[tool.mypy]
strict = true
warn_return_any = true
warn_unused_configs = true
disallow_untyped_defs = true
```

## Critical Rules

| Rule | Tool | What It Catches | Severity |
|------|------|----------------|----------|
| S101 | ruff/bandit | Use of `assert` in production code | critical |
| S105-S107 | ruff/bandit | Hardcoded passwords, secrets, temp file paths | critical |
| S608 | ruff/bandit | SQL injection via string formatting | critical |
| B006 | ruff/bugbear | Mutable default arguments | warning |
| B904 | ruff/bugbear | Missing `from` in `raise ... from` | warning |
| PL-R1722 | ruff/pylint | Use `sys.exit()` instead of `exit()` | warning |

## Integration with MTK

```bash
ruff check --output-format json . | hooks/parse-build-diagnostics.sh --format ruff > .mtk/analyzer-output.json
```
