# Python Testing Supplement

Stack-specific testing guidance for Python projects. Read alongside `.claude/references/testing-patterns.md`.

## Test Framework

- **pytest** is the default. Use `pytest-asyncio` for async tests, `pytest-django` for Django.
- Avoid `unittest.TestCase` for new tests — pytest's function style is more flexible.

## Fixtures

- Shared fixtures live in `conftest.py` at the appropriate scope (package, module).
- Use `@pytest.fixture(scope="...")` thoughtfully — `function` is the default and safest.
- Prefer `factory_boy` or `pytest-factoryboy` for test data over inline construction.
- Use `monkeypatch` for environment / module-level patching, `mock.patch` for object-level.

## Parametrize

- Use `@pytest.mark.parametrize` for table-driven tests instead of multiple near-duplicate test functions.
- Keep parameter IDs readable: `pytest.param(..., id="empty-input")`.

## Test Database

- SQLite in-memory: fine for unit tests of pure logic, NOT for tests that depend on Postgres-specific behavior.
- For real integration tests:
  - **SQLAlchemy projects:** `testcontainers-python` with a Postgres container.
  - **Django projects:** `pytest-django` with `--reuse-db` or `--create-db` against a real Postgres test database.

## Mocking

- Mock at boundaries (HTTP clients, message queues, external services). Don't mock internal collaborators.
- Use `respx` for mocking HTTPX clients, `vcrpy` for recorded HTTP interactions.
- Use `freezegun` for time-dependent tests.

## Async Tests

- Mark async tests with `@pytest.mark.asyncio` (or set `asyncio_mode = "auto"` in `pyproject.toml`).
- Use `httpx.AsyncClient` for async FastAPI endpoint tests.

## Review Questions

- Does the chosen test provider actually validate the database behavior in question?
- Are mocks placed at boundaries, not on internal logic?
- Is async/sync boundary handled correctly in the test setup?
- Are fixtures scoped appropriately to avoid test pollution?
