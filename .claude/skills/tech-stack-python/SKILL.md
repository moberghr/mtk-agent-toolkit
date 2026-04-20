---
name: tech-stack-python
description: Provides Python-specific build commands, test commands, ORM guidance, framework patterns, and reference file paths for workflow skills.
license: MIT
compatibility:
  - claude-code
  - codex
trigger: tech-stack-context
skip_when: never-skip-when-active-stack
type: tech-stack
user-invocable: false
---

# Tech Stack: Python

## Overview

This tech stack skill provides Python-specific context for the generic workflow skills (`spec-driven-development`, `incremental-implementation`, `test-driven-development`) and for review agents. It is loaded when `.claude/tech-stack` contains `python`.

## When To Use

Loaded automatically by commands and skills when the active tech stack is `python`. Not invoked directly.

## Build & Test Commands

Python is interpreted, so there's no separate compile step. Use type checking and tests as your verification gates.

- **Type check (compile-equivalent):** `mypy .` or `pyright` (whichever the project uses)
- **Test (batch):** `pytest <path/to/module>` or `pytest -k <pattern>`
- **Test (full):** `pytest`
- **Format:** `ruff format "$CLAUDE_FILE"` (or `black "$CLAUDE_FILE"` if the project uses black)
- **Lint:** `ruff check "$CLAUDE_FILE"` (or `flake8` / `pylint` per project)

If the project uses `tox`, the full test command is `tox`. If Poetry: `poetry run pytest`. If a Makefile or `justfile` exists, prefer the project-defined targets (`make test`, `just test`).

## File Extensions & Markers

How `setup-bootstrap` detects this stack in a repository:

| Marker | Confidence |
|---|---|
| `pyproject.toml` | High |
| `setup.py` or `setup.cfg` | High |
| `requirements.txt` | Medium |
| `Pipfile` or `poetry.lock` | High |
| `.python-version` | Low (supplemental) |

Detection command:
```bash
find . -maxdepth 2 -name "pyproject.toml" -o -name "setup.py" -o -name "requirements.txt" -o -name "Pipfile" 2>/dev/null | head -3
```

## ORM & Data Layer Guidance

**SQLAlchemy rules (when SQLAlchemy is detected):**

- Use `select()` (SQLAlchemy 2.0 style) over the legacy `Query` API.
- For read-only queries, use `expire_on_commit=False` or detached sessions to avoid unnecessary lazy-load round trips.
- Avoid implicit lazy loading in production code paths — eager-load with `joinedload` or `selectinload` explicitly. Implicit lazy loading is a common N+1 source.
- Always use `with session.begin():` or explicit transaction boundaries for writes.
- One commit per request/handler unless multiple aggregates demand otherwise.
- Use `Session.execute(select(...))` returning DTOs, not full ORM objects, when you only need projection.

**Django ORM rules (when Django is detected):**

- Use `select_related` (foreign keys) and `prefetch_related` (many-to-many, reverse foreign) to avoid N+1.
- Wrap multi-step writes in `transaction.atomic()`.
- Use `.values()` or `.values_list()` for read-only projections.
- Avoid `.all()` without filters in production paths — pagination required.

**Test provider rules:**

- SQLite in-memory is fine for pure logic tests, but **does not validate Postgres-specific behavior** (JSONB, arrays, full-text search, advisory locks).
- Use `testcontainers-python` or a real test database when database semantics matter.
- For Django: prefer `--keepdb` or `pytest-django` with a real Postgres test database for integration suites.

**Reference:** `.claude/references/python/sqlalchemy-checklist.md`

## Framework Patterns

**FastAPI (when detected):**

- Use Pydantic models for request/response validation. No raw dict in/out of endpoints.
- Use `Depends()` for dependency injection (DB sessions, auth, settings).
- Routers: one per domain area, mounted under `/api/v1/...`.
- Async endpoints when doing async I/O; sync endpoints when wrapping sync I/O (don't fake async).

**Django (when detected):**

- Class-based views or function-based views — match the project's existing choice.
- Forms / serializers (DRF) for validation. No raw `request.POST` access in business logic.
- Apps as bounded contexts; don't cross-import models between apps without justification.

**Reference:** `.claude/references/python/fastapi-patterns.md`

## Test Level Guidance

- **Unit tests:** pure logic, validators, mappings, branching rules. Use `pytest` parametrize for edge cases.
- **Integration tests:** endpoints, persistence, authentication, serialization. Use FastAPI `TestClient` or Django `Client` / DRF `APIClient`.
- **End-to-end tests:** only when the project already uses them (Playwright, Selenium).
- For SQLAlchemy/Django ORM behavior: do NOT default to SQLite in-memory if the production database is Postgres and you depend on Postgres features.
- Use fixtures (`conftest.py`) for shared setup. Prefer `factory_boy` or `pytest-factoryboy` for test data.
- Mock at boundaries (HTTP clients, message queues), not internal collaborators.

## Coding Style Reference

Path: `.claude/references/python/coding-guidelines.md`

Source: To be authored when the team starts its first Python project. The placeholder file lists the structure to follow. PEP 8 + ruff defaults are a reasonable starting point.

Key conventions to start with (until guidelines are written):
- PEP 8 formatting via `ruff format` or `black`
- PEP 484 type hints on all public functions
- Explicit imports (no `from x import *`)
- `snake_case` for variables/functions, `PascalCase` for classes, `SCREAMING_SNAKE` for constants
- Docstrings (Google or NumPy style) on public APIs
- f-strings over `.format()` or `%` formatting
- Use `pathlib.Path` over `os.path` for new code

## Analyzer Configuration

See `.claude/references/python/analyzer-config.md` for recommended ruff rules and mypy strict settings.

Lint with analyzer capture:
```bash
ruff check --output-format json . | hooks/parse-build-diagnostics.sh --format ruff > .mtk/analyzer-output.json
```

## Recommended Tooling

See `.claude/references/python/recommended-tooling.md` for MCP servers, plugins, and editor integrations that noticeably improve Claude Code productivity on Python projects — notably `context7` (current framework docs), Pyright/basedpyright LSP, and Ruff LSP. Paired with the stack-agnostic `.claude/references/recommended-tooling.md`. `setup-bootstrap` prints both during onboarding; install is manual.

## Reference Files

These files are loaded by commands and review agents when the active stack is `python`:

- `.claude/references/python/coding-guidelines.md` — Python style guide (placeholder until written)
- `.claude/references/python/sqlalchemy-checklist.md` — SQLAlchemy review and implementation checklist
- `.claude/references/python/fastapi-patterns.md` — FastAPI/Django patterns
- `.claude/references/python/testing-supplement.md` — pytest patterns, fixtures, mocking
- `.claude/references/python/performance-supplement.md` — async, connection pooling, profiling
- `.claude/references/python/recommended-tooling.md` — Recommended MCPs / plugins / editor integrations for Python

## Settings Additions

Merge these into the project's `.claude/settings.json` during `setup-bootstrap`:

### allowedTools (merge: union)
- `Bash(python:*)`
- `Bash(python3:*)`
- `Bash(pytest:*)`
- `Bash(mypy:*)`
- `Bash(ruff:*)`
- `Bash(black:*)`
- `Bash(poetry:*)`
- `Bash(pip:*)`
- `Bash(tox:*)`

### deny (merge: union)
- `Read(**/.env.production)`
- `Read(**/secrets.yaml)`

### hooks.PostToolUse (merge: append)
- matcher: `Write(*.py)|Edit(*.py)`
- command: `ruff format "$CLAUDE_FILE" 2>/dev/null && ruff check --fix "$CLAUDE_FILE" 2>/dev/null || true`

## Format Command

```bash
ruff format "$CLAUDE_FILE" 2>/dev/null && ruff check --fix "$CLAUDE_FILE" 2>/dev/null || true
```

Triggered on: `Write(*.py)|Edit(*.py)`

## Scan Recipes

These bash commands are used by `setup-audit.md` when auditing a Python repository.

### Project Structure
```bash
# Project metadata
find . -maxdepth 2 -name "pyproject.toml" -o -name "setup.py" -o -name "setup.cfg" 2>/dev/null
find . -maxdepth 2 -name "requirements*.txt" -o -name "Pipfile" -o -name "poetry.lock" 2>/dev/null
# Python version
cat .python-version 2>/dev/null
grep -E "python_requires|python =" pyproject.toml setup.py setup.cfg 2>/dev/null | head -5
# Top-level packages
find . -maxdepth 3 -name "__init__.py" -not -path "*/.venv/*" -not -path "*/venv/*" -not -path "*/site-packages/*" | head -20
# Folder structure
find . -type d -maxdepth 3 -not -path "*/.venv/*" -not -path "*/venv/*" -not -path "*/__pycache__/*" -not -path "*/.git/*" -not -path "*/node_modules/*" | sort
```

### Patterns In Use
```bash
# Web framework
grep -rl "from fastapi\|import fastapi" --include="*.py" | head -10
grep -rl "from django\|django.urls\|django.db.models" --include="*.py" | head -10
grep -rl "from flask\|import flask" --include="*.py" | head -10
# ORM
grep -rl "from sqlalchemy\|sqlalchemy.orm\|sqlalchemy.ext" --include="*.py" | head -10
grep -rl "models.Model\|django.db" --include="*.py" | head -10
# Validation
grep -rl "from pydantic\|BaseModel\|pydantic.Field" --include="*.py" | head -10
grep -rl "marshmallow\|Schema" --include="*.py" | head -10
# Async
grep -rl "async def\|await\|asyncio" --include="*.py" | head -10
# Type checking
find . -name "mypy.ini" -o -name "pyrightconfig.json" 2>/dev/null
grep -E "mypy|pyright" pyproject.toml setup.cfg 2>/dev/null | head -5
```

### Data Layer
```bash
# SQLAlchemy patterns
grep -rl "declarative_base\|DeclarativeBase\|Mapped\[" --include="*.py" | head -5
grep -rl "session.execute\|session.query\|select(" --include="*.py" | head -5
# Migrations
find . -name "alembic.ini" 2>/dev/null
find . -path "*/migrations/*" -name "*.py" -not -path "*/.venv/*" | head -10
# Django ORM patterns
grep -rl "select_related\|prefetch_related" --include="*.py" | head -5
grep -rl "transaction.atomic" --include="*.py" | head -5
# N+1 risks
grep -rn "lazy=" --include="*.py" | head -5
# Connection management
grep -rn "create_engine\|sessionmaker\|SessionLocal" --include="*.py" | head -5
```

### Infrastructure
```bash
# AWS / cloud SDKs
grep -rl "import boto3\|from boto3" --include="*.py" | head -10
# Lambda handlers
grep -rl "def lambda_handler\|def handler" --include="*.py" | head -5
# Docker
find . -name "Dockerfile" -o -name "docker-compose*" -o -name ".dockerignore"
# IaC
find . -name "*.tf" -o -name "serverless.yml" -o -name "cdk.json" 2>/dev/null | head -10
# Messaging
grep -rl "celery\|kafka\|rabbitmq\|redis" --include="*.py" | head -10
# Secrets
grep -rl "boto3.client('secretsmanager')\|hvac\|os.environ" --include="*.py" | head -5
```

### Naming Conventions
```bash
# Sample router/view files
find . -name "*router*.py" -o -name "*views*.py" -not -path "*/.venv/*" | head -10
find . -name "*handler*.py" -not -path "*/.venv/*" -not -path "*test*" | head -10
# Sample model files
find . -name "models.py" -o -name "*model*.py" -not -path "*/.venv/*" -not -path "*test*" | head -10
```

### Testing Patterns
```bash
# Test framework
grep -rl "import pytest\|from pytest" --include="*.py" | head -5
grep -rh "pytest\|tox" pyproject.toml setup.cfg requirements*.txt 2>/dev/null | sort -u
# Test organization
find . -path "*test*" -name "*.py" -not -path "*/.venv/*" -not -path "*/__pycache__/*" | head -20
# Fixtures
find . -name "conftest.py" -not -path "*/.venv/*" | head -10
# Mocking
grep -rl "from unittest.mock\|import mock\|pytest_mock\|monkeypatch" --include="*.py" | head -5
# Test data factories
grep -rl "factory_boy\|FactoryBoy\|pytest_factoryboy" --include="*.py" | head -5
# Test database
grep -rl "testcontainers\|pytest-django\|pytest-postgresql" --include="*.py" | head -5
```

### Configuration
```bash
# Settings / config
grep -rl "from pydantic_settings\|BaseSettings\|os.environ.get" --include="*.py" | head -10
find . -name "settings.py" -o -name "config.py" -o -name ".env.example" -not -path "*/.venv/*" | head -10
# Logging
grep -rl "import logging\|getLogger\|loguru\|structlog" --include="*.py" | head -10
```

## Verification

- [ ] Tech stack skill is loaded when `.claude/tech-stack` contains `python`
- [ ] Build (type check) and test commands execute correctly for the target project
- [ ] Reference files exist at the paths listed in `## Reference Files`
- [ ] Scan recipes produce meaningful output for a Python repository
