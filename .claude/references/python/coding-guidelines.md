---
description: Python coding guidelines (placeholder until team formalizes)
globs: ["**/*.py"]
alwaysApply: false
status: placeholder
---
# Python Coding Guidelines — Placeholder

> **STATUS: placeholder — `setup-bootstrap` will NOT ship this file to target repos.**
>
> When the team starts its first Python project, replace this content with the real guidelines and remove `status: placeholder` from the frontmatter. From then on, `setup-bootstrap` will include the file.
>
> This file exists in the toolkit so the Python tech stack has a stable reference path.
> When you start a Python project, fill this in with team-specific style decisions.

## Default Starting Point

Until this file is written, default to:

- **PEP 8** for layout and naming
- **PEP 484** type hints on all public functions
- **PEP 257** docstring conventions
- **`ruff format`** as the canonical formatter (or `black` if the project chose it)
- **`ruff check`** for linting with default rules + project-specific additions

## Sections to Author Later

When this file gets written for real, structure it like the C# guidelines:

1. **Naming conventions** — modules, classes, functions, constants, private members
2. **Layout conventions** — imports order, line length, docstring placement
3. **Type hints** — when required, when `Any` is acceptable, generic vs concrete
4. **Async patterns** — when to use async, sync wrappers, sync-in-async pitfalls
5. **Error handling** — exceptions vs Result-style, custom exception hierarchy
6. **Framework-specific** — FastAPI router style, Django view style, Pydantic model style
7. **Testing style** — fixture naming, parametrize patterns, mock placement
8. **Common anti-patterns** — mutable default arguments, broad except, late binding closures

## How To Update

When you author this file:
1. Reference real code from your first Python project
2. Decide between `ruff` and `black` + `flake8` + `isort` (recommend ruff for new projects)
3. Commit the decisions before scaling the project
4. Update `tech-stack-python/SKILL.md` to remove the "placeholder" warning
