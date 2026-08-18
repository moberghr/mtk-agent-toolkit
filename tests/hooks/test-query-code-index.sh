#!/usr/bin/env bash
set -euo pipefail

# Test: scripts/query-code-index.sh (F6 — grep-friendly CODE_INDEX query
# companion). Asserts `find <keyword>` locates a known row (prefixed with its
# domain) and returns non-zero for a non-matching keyword, and that
# `callers <symbol>` produces at least one file:line result against this repo.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
QUERY="$REPO_ROOT/scripts/query-code-index.sh"

echo "=== query-code-index Test (F6) ==="
[ -f "$QUERY" ] || { echo "  FAIL  script not found: $QUERY" >&2; exit 1; }

declare -a FAILS=()

# --- Fixture: a small CODE_INDEX.md in a temp dir ---
TMPDIR_FIXTURE="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_FIXTURE"; }
trap cleanup EXIT

FIXTURE="$TMPDIR_FIXTURE/CODE_INDEX.md"
cat > "$FIXTURE" <<'EOF'
# Code Index

> Capability index — what the codebase can do, not where files live.

## Authentication & Authorization

| Capability | Entry point | Notes |
|---|---|---|
| issue access token | `src/auth/Token.cs:IssueToken` | rotates every 15min |
| verify password | `src/auth/Password.cs:Verify` | Argon2id only |

## Persistence

| Capability | Entry point | Notes |
|---|---|---|
| open db connection | `src/db/Conn.cs:Open` | pooled; do not reimplement |
| view entry log | `src/audit/Log.cs:ViewEntry` | shows capability grants at entry |
| parse config[env] | `src/config/Parser.cs:Parse` | matches literal a.b.c keys only |
| 1.0 -+ 2.0 | 3:4 | (.,/*) |
EOF

# --- find: known row is found, prefixed with its domain ---
echo ""; echo "--- find: matching keyword ---"
if out="$(bash "$QUERY" find "access token" --file "$FIXTURE" 2>/dev/null)"; then
  if printf '%s' "$out" | grep -q '\[Authentication & Authorization\]' \
     && printf '%s' "$out" | grep -q 'src/auth/Token.cs:IssueToken' \
     && printf '%s' "$out" | grep -q 'rotates every 15min'; then
    echo "  PASS  matching row found with domain header"
  else
    FAILS+=("find: matched but output missing domain/entry/notes: $out")
  fi
else
  FAILS+=("find: expected exit 0 for a matching keyword, got non-zero")
fi

# --- find: another domain resolves correctly ---
if out="$(bash "$QUERY" find "db connection" --file "$FIXTURE" 2>/dev/null)"; then
  if printf '%s' "$out" | grep -q '\[Persistence\]'; then
    echo "  PASS  second-domain row carries its own header"
  else
    FAILS+=("find: Persistence row missing its header: $out")
  fi
else
  FAILS+=("find: expected exit 0 for 'db connection', got non-zero")
fi

# --- find: non-matching keyword returns nothing and non-zero ---
echo ""; echo "--- find: non-matching keyword ---"
if out="$(bash "$QUERY" find "nonexistent-capability-xyz" --file "$FIXTURE" 2>/dev/null)"; then
  FAILS+=("find: expected non-zero exit for a non-matching keyword, got 0 (out: $out)")
else
  if [ -z "$out" ]; then
    echo "  PASS  non-matching keyword returned nothing and non-zero"
  else
    FAILS+=("find: non-matching keyword printed rows to stdout: $out")
  fi
fi

# --- find: header-skip anchors to the first cell only, not any row that ---
# --- happens to contain both "capability" and "entry" as substrings.    ---
# --- Regression guard for F-1 (see docs/specs/2026-07-01-v717-*.json).  ---
echo ""; echo "--- find: header-skip does not false-positive on data rows ---"
if out="$(bash "$QUERY" find "view entry log" --file "$FIXTURE" 2>/dev/null)"; then
  if printf '%s' "$out" | grep -q '\[Persistence\]' \
     && printf '%s' "$out" | grep -q 'shows capability grants at entry'; then
    echo "  PASS  data row containing 'capability' and 'entry' still matched"
  else
    FAILS+=("find: header-skip false-positive — row wrongly treated as header: $out")
  fi
else
  FAILS+=("find: expected exit 0 for 'view entry log' (header-skip false-positive?), got non-zero")
fi

# --- find: keyword is matched as a fixed string, not a regex.            ---
# --- Regression guard for F-2 (see docs/specs/2026-07-01-v717-*.json).   ---
echo ""; echo "--- find: fixed-string matching, not regex ---"
if out="$(bash "$QUERY" find "config[env]" --file "$FIXTURE" 2>/dev/null)"; then
  if printf '%s' "$out" | grep -q '\[Persistence\]' \
     && printf '%s' "$out" | grep -q 'parse config\[env\]'; then
    echo "  PASS  literal '[' in keyword matched as fixed string"
  else
    FAILS+=("find: fixed-string match for 'config[env]' malformed: $out")
  fi
else
  FAILS+=("find: keyword with regex metacharacters ('config[env]') was treated as a regex, got non-zero")
fi

# --- find: a data row made only of digits/punctuation is not mistaken for   ---
# --- a separator row. Regression guard for the '[!\|\ -:]' bracket bug: the ---
# --- mid-class '-' formed a range (space..colon) swallowing digits and most  ---
# --- punctuation, so rows like '| 1.0 -+ 2.0 | 3:4 | (.,/*) |' were dropped. ---
echo ""; echo "--- find: digits/punctuation-only data row is not skipped as separator ---"
if out="$(bash "$QUERY" find "3:4" --file "$FIXTURE" 2>/dev/null)"; then
  if printf '%s' "$out" | grep -qF '1.0 -+ 2.0'; then
    echo "  PASS  punctuation-only row matched (not misclassified as separator)"
  else
    FAILS+=("find: punctuation-only row matched but output malformed: $out")
  fi
else
  FAILS+=("find: punctuation-only data row was skipped as a separator row")
fi

# --- find: missing file errors non-zero ---
echo ""; echo "--- find: missing file ---"
if bash "$QUERY" find "anything" --file "$TMPDIR_FIXTURE/does-not-exist.md" >/dev/null 2>&1; then
  FAILS+=("find: expected non-zero exit when CODE_INDEX file is missing")
else
  echo "  PASS  missing CODE_INDEX file errors non-zero"
fi

# --- callers: textual reference search against this repo ---
# hash_file() is defined in scripts/generate-checksums.sh — a known symbol.
echo ""; echo "--- callers: textual reference search ---"
if out="$(cd "$REPO_ROOT" && bash "$QUERY" callers "hash_file" 2>/dev/null)"; then
  # <(printf …) not printf|grep -q: grep's early exit SIGPIPEs the printf under
  # pipefail and a different assertion fails per run (S3.1 flake class).
  if grep -qE '^[^:]+:[0-9]+:' <(printf '%s' "$out"); then
    echo "  PASS  callers printed at least one file:line result"
  else
    FAILS+=("callers: output not in file:line form: $out")
  fi
else
  FAILS+=("callers: expected at least one match for 'hash_file', got non-zero")
fi

echo ""
if [ ${#FAILS[@]} -gt 0 ]; then
  printf '  FAIL  %s\n' "${FAILS[@]}" >&2
  exit 1
fi
echo "========================================"
echo "TEST PASSED — all F6 query-code-index assertions green"
