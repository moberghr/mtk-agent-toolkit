#!/usr/bin/env bash
set -euo pipefail

# mtk_command_is_verification (hooks/lib/hook-io.sh) decides which Bash calls
# count as fresh verification evidence. It used to match a runner token
# anywhere in the command, so `echo dotnet test` and `grep dotnet test README`
# stamped the ledger as verified. A runner now counts only in command position:
# the start of the command, or after && || ; | ( or a backtick, behind the
# wrappers a real invocation uses (cd <dir> &&, env, VAR=x, time, timeout,
# docker compose run <svc>). As an argument of echo/printf/grep/rg/cat, or
# inside a quoted string, it never counts.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

is_verification() {
  bash -c '
    source "'"$REPO_ROOT"'/hooks/lib/hook-io.sh"
    mtk_command_is_verification "$1" && echo yes || echo no
  ' _ "$1"
}

yes_cases=(
  'dotnet test'
  'dotnet build -c Release'
  'pytest'
  'pytest tests/ -q'
  'cd services/api && dotnet test'
  'cd "services/my api" && pytest'
  'env CI=1 pytest'
  'env -u HOME CI=1 npm test'
  'CI=1 DOTNET_NOLOGO=1 dotnet test --no-build'
  'time cargo test'
  'timeout 600 dotnet test'
  'docker compose run --rm tests pytest'
  'docker compose run --rm -e CI=1 tests pytest -q'
  'docker-compose run api npm test'
  'npm install && npm test'
  'npm run build'
  'pnpm run test:unit'
  'yarn test'
  'bun test'
  'make test'
  'go test ./...'
  'ruff check .'
  'mypy src'
  'npx tsc --noEmit'
  'uv run pytest'
  'python -m pytest tests/'
  'bash scripts/validate-toolkit.sh'
  './scripts/validate-toolkit.sh'
  'bash scripts/run-benchmarks.sh'
  'bash scripts/mtk-verify-run.sh -- ./run-integration.sh'
  'bash "${CLAUDE_PLUGIN_ROOT}/scripts/mtk-verify-run.sh" -- dotnet test'
  'bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-toolkit.sh'
  '(cd api; dotnet test)'
  'git stash list; pytest'
  'out=`pytest -q`'
  'pytest tests/ || true'
  'pytest | tee log.txt'
  'if pytest; then echo ok; fi'
  'DOTNET test'
  'cat <<EOF
pytest'
)
no_cases=(
  'echo dotnet test'
  'grep dotnet test README'
  'grep -rn "dotnet test" docs/'
  'rg pytest .'
  'cat pytest.ini'
  'printf "%s\n" "npm test"'
  'git commit -m "run dotnet test before merging"'
  "git commit -m 'fix: pytest flake'"
  'echo "cd x && pytest"'
  'ls tests/'
  'git status'
  'npm install'
  'dotnet restore'
  'cat <<EOF > notes.md
pytest
EOF'
  'vim pytest.ini'
  'cat "${CLAUDE_PLUGIN_ROOT}/scripts/validate-toolkit.sh"'
  'cat ${CLAUDE_PLUGIN_ROOT}/scripts/validate-toolkit.sh'
  'bash -c "pytest"'
  'mkdir -p tests && touch tests/pytest_cache'
  'pytest --collect-only'
  'pytest --co -q'
  'pytest --help'
  'pytest --version'
  'dotnet test --list-tests'
  'npm test -- --help'
)

for c in "${yes_cases[@]}"; do
  [ "$(is_verification "$c")" = "yes" ] || fail "must count as verification: $c"
done
printf '  PASS  %d real-world runner shapes register\n' "${#yes_cases[@]}"

for c in "${no_cases[@]}"; do
  [ "$(is_verification "$c")" = "no" ] || fail "must NOT count as verification: $c"
done
printf '  PASS  %d mentions (echo/grep/quoted/heredoc) do not register\n' "${#no_cases[@]}"

printf '\nAll verification-recognition checks passed.\n'
