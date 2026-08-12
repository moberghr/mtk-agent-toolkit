#!/usr/bin/env bash
set -euo pipefail

# security-gate.sh blocks destructive database operations. It matched only the command
# text, so `bash rebuild.sh` slipped past while the identical statements typed inline were
# blocked. These cases pin both halves plus the allow path.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$REPO_ROOT/hooks/security-gate.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0

# Runs the gate with COMMAND as the Bash payload; echoes the exit code.
run_gate() {
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$1" \
    | "$GATE" >/dev/null 2>&1 && echo 0 || echo $?
}

expect() {
  local label="$1" want="$2" got="$3"
  if [ "$got" != "$want" ]; then
    printf 'FAIL: %s — expected exit %s, got %s\n' "$label" "$want" "$got" >&2
    fails=$((fails + 1))
  fi
}

# 1. Inline DROP SCHEMA is blocked (pre-existing behaviour, must not regress).
expect "inline DROP SCHEMA" 2 "$(run_gate '"psql -c \"DROP SCHEMA public CASCADE;\""')"

# 2. The same statements inside a script are blocked. This is the regression under test.
cat > "$TMP/rebuild.sh" <<'EOF'
#!/usr/bin/env bash
psql "$CONN" -c "DROP SCHEMA IF EXISTS warp CASCADE;" -c "CREATE SCHEMA public;"
EOF
expect "DROP SCHEMA inside an executed script" 2 "$(run_gate "\"bash $TMP/rebuild.sh\"")"

# 3. A .sql file fed to psql is blocked.
printf 'TRUNCATE TABLE users;\n' > "$TMP/wipe.sql"
expect "TRUNCATE inside a .sql file" 2 "$(run_gate "\"psql -f $TMP/wipe.sql\"")"

# 4. A harmless script is allowed — the gate must not block every .sh it sees.
cat > "$TMP/safe.sh" <<'EOF'
#!/usr/bin/env bash
echo "SELECT count(*) FROM users;"
EOF
expect "harmless script" 0 "$(run_gate "\"bash $TMP/safe.sh\"")"

# 5. A referenced file that does not exist must not blow up the gate.
expect "missing script" 0 "$(run_gate '"bash /nonexistent/does-not-exist.sh"')"

# 5a. Merely naming a destructive script must not be blocked — staging, reading or
# editing a file executes nothing, and blocking that would make the gate unusable.
expect "git add of a destructive script" 0 "$(run_gate "\"git add $TMP/rebuild.sh\"")"
expect "reading a destructive script"    0 "$(run_gate "\"head -20 $TMP/rebuild.sh\"")"
expect "reading a destructive .sql"      0 "$(run_gate "\"wc -l $TMP/wipe.sql\"")"

# 5b. Executed directly rather than via an interpreter.
chmod +x "$TMP/rebuild.sh"
expect "directly executed script" 2 "$(run_gate "\"$TMP/rebuild.sh\"")"

# 5c. The gate must not block this very suite. This file has to contain the statements it
# asserts on, so scanning it denied `bash tests/hooks/test-security-gate.sh` outright and
# made the suite unrunnable through the Bash tool. Both spellings of the path, because the
# gate resolves a relative reference against the caller's working directory.
expect "this suite, absolute path" 0 "$(run_gate "\"bash $REPO_ROOT/tests/hooks/test-security-gate.sh\"")"
expect "this suite, relative path" 0 "$(cd "$REPO_ROOT" && run_gate '"bash tests/hooks/test-security-gate.sh"')"

# 5d. The carve-out is scoped to this repo's tests/ tree. A tests/-shaped path belonging to
# some other checkout is still read and still blocked — otherwise the exemption would be a
# hole any caller could walk through by naming its script tests/anything.sh.
mkdir -p "$TMP/tests/hooks"
cp "$TMP/rebuild.sh" "$TMP/tests/hooks/rebuild.sh"
expect "tests/ path outside this repo" 2 "$(run_gate "\"bash $TMP/tests/hooks/rebuild.sh\"")"

# 6. Non-Bash payloads are ignored.
expect "non-Bash payload" 0 "$(printf '{"tool_name":"Read","tool_input":{"file_path":"x"}}' | "$GATE" >/dev/null 2>&1 && echo 0 || echo $?)"

if [ "$fails" -ne 0 ]; then
  printf '%s check(s) failed\n' "$fails" >&2
  exit 1
fi

echo "PASS: test-security-gate.sh"
