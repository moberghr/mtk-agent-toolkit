#!/usr/bin/env bash
set -euo pipefail

# read-guard.sh: blocks secret-file reads (exit 2), allows allowlisted sample
# files, downgrades under MTK_READ_GUARD=advisory, honors the approval list,
# advises (exit 0) on noise-dir reads, and passes clean source reads silently.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/read-guard.sh"

cd "$REPO_ROOT"

payload() { printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Helper: run hook, capture exit code (never let set -e kill the test).
run() { local rc; set +e; printf '%s' "$1" | env "${2:-EMPTY=1}" bash "$HOOK" >/dev/null 2>&1; rc=$?; set -e; echo "$rc"; }
run_out() { set +e; printf '%s' "$1" | env "${2:-EMPTY=1}" bash "$HOOK" 2>&1; set -e; }

# --- Case 1: secret file blocks (exit 2) -----------------------------------
[ "$(run "$(payload Read /tmp/app/.env)")" = "2" ] || fail "Read /tmp/app/.env should block (exit 2)"
[ "$(run "$(payload Read /tmp/app/private.pem)")" = "2" ] || fail "Read *.pem should block"
[ "$(run "$(payload Read /tmp/app/id_rsa)")" = "2" ] || fail "Read id_rsa should block"
[ "$(run "$(payload Grep /tmp/app/.npmrc)")" = "2" ] || fail "Grep .npmrc should block"
printf '  PASS  secret-bearing files blocked (exit 2)\n'

# --- Case 2: allowlisted sample files pass ---------------------------------
[ "$(run "$(payload Read /tmp/app/.env.example)")" = "0" ] || fail ".env.example should pass"
[ "$(run "$(payload Read /tmp/app/config.template)")" = "0" ] || fail "*.template should pass"
printf '  PASS  sample/scaffold files allowed\n'

# --- Case 3: advisory mode downgrades block to warning ---------------------
rc="$(run "$(payload Read /tmp/app/.env)" 'MTK_READ_GUARD=advisory')"
[ "$rc" = "0" ] || fail "advisory mode should not block (.env), got exit $rc"
run_out "$(payload Read /tmp/app/.env)" 'MTK_READ_GUARD=advisory' | grep -qi 'advisory' \
  || fail "advisory mode should warn"
printf '  PASS  MTK_READ_GUARD=advisory downgrades block to warning\n'

# --- Case 4: approval list allows the exact path ---------------------------
APPROVAL="${TMPDIR:-/tmp}/mtk-readguard-approved-$(cd "$REPO_ROOT" && git rev-parse --show-toplevel | cksum | cut -d' ' -f1)-$(date +%Y%m%d)"
echo "/tmp/app/.env" > "$APPROVAL"
rc="$(run "$(payload Read /tmp/app/.env)")"
rm -f "$APPROVAL"
[ "$rc" = "0" ] || fail "approved path should pass, got exit $rc"
printf '  PASS  approval list allows the exact path\n'

# --- Case 5: noise dir advises but allows ----------------------------------
rc="$(run "$(payload Read "$REPO_ROOT/node_modules/foo/index.js")")"
[ "$rc" = "0" ] || fail "noise-dir read should pass (exit 0), got $rc"
run_out "$(payload Read "$REPO_ROOT/node_modules/foo/index.js")" | grep -qi 'advisory' \
  || fail "noise-dir read should emit advisory"
printf '  PASS  noise-dir read advised but allowed\n'

# --- Case 6: clean source read passes silently -----------------------------
rc="$(run "$(payload Read "$REPO_ROOT/README.md")")"
[ "$rc" = "0" ] || fail "clean source read should pass, got $rc"
out="$(run_out "$(payload Read "$REPO_ROOT/README.md")")"
[ -z "$out" ] || fail "clean source read should be silent, got: $out"
printf '  PASS  clean source read passes silently\n'

# --- Case 7: non-read tool ignored -----------------------------------------
[ "$(run "$(payload Bash /tmp/app/.env)")" = "0" ] || fail "non-read tool should be ignored"
printf '  PASS  non-read tools ignored\n'

printf '\nAll read-guard checks passed.\n'
