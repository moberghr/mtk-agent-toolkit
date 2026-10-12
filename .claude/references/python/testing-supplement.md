---
description: Python testing supplement — pytest, fixtures, mocking at boundaries, real test databases
globs: ["**/test_*.py", "**/*_test.py", "**/tests/**/*.py"]
alwaysApply: false
tools: [pytest, hypothesis]
---
# Python Testing Supplement

> **Precedence:** project rules in `.claude/rules/testing.md` override this file.

## Test Framework

- **pytest is the default.** `pytest-asyncio` for async tests (or `asyncio_mode = "auto"`), `pytest-django` for Django. Shared fixtures live in `conftest.py`; prefer `factory_boy` for test data.

## Test Database

- SQLite in-memory is fine for pure logic, not for anything that depends on Postgres behavior.
- **SQLAlchemy projects:** testcontainers-python with a Postgres container.
- **Django projects:** `pytest-django` with `--reuse-db` or `--create-db` against a real Postgres test database.

## Mocking

- Mock at boundaries (HTTP clients, queues, external services), never internal collaborators.
- Use respx for mocking HTTPX clients, vcrpy for recorded HTTP interactions.
- `freezegun` for time-dependent tests.
