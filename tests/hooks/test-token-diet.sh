#!/usr/bin/env bash
set -euo pipefail

# Read-path token diet (round 8, option C): opt-in re-read guard on unchanged
# files (deny/advise, session-keyed, partial reads exempt) and the
# repetition-dominance collapse in mtk-compress. Default-off: no env var, no
# behavior change.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$REPO_ROOT/hooks/read-guard.sh"
COMPRESS="$REPO_ROOT/scripts/mtk-compress.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
TMPDIR_OVERRIDE="$(mktemp -d)"
cleanup() { rm -rf "$WORK" "$TMPDIR_OVERRIDE"; }
trap cleanup EXIT
git -C "$WORK" init -q
printf 'stable content line 1\nstable content line 2\n' > "$WORK/stable.txt"

read_payload() { # $1 = file, $2 = extra json fields (or empty)
  python3 - "$1" "${2:-}" <<'PY'
import json, sys
d = {"hook_event_name": "PreToolUse", "tool_name": "Read",
     "session_id": "sess-diet-1", "tool_input": {"file_path": sys.argv[1]}}
if sys.argv[2]:
    d["tool_input"].update(json.loads(sys.argv[2]))
print(json.dumps(d))
PY
}

run_guard() { # $1 payload, $2 diet mode; echoes "rc<US>stdout<US>stderr"
  local rc=0 out err of ef
  of="$TMPDIR_OVERRIDE/out.$$"; ef="$TMPDIR_OVERRIDE/err.$$"
  printf '%s' "$1" | CLAUDE_PROJECT_DIR="$WORK" TMPDIR="$TMPDIR_OVERRIDE" MTK_READ_DIET="$2" \
    bash "$GUARD" > "$of" 2> "$ef" || rc=$?
  printf '%s\x1f%s\x1f%s' "$rc" "$(cat "$of")" "$(cat "$ef")"
}

# --- 1. default off: repeated reads pass -----------------------------------------

r="$(run_guard "$(read_payload "$WORK/stable.txt")" 0)"; rc="${r%%$'\x1f'*}"
[ "$rc" = "0" ] && r="$(run_guard "$(read_payload "$WORK/stable.txt")" 0)" && rc="${r%%$'\x1f'*}"
[ "$rc" = "0" ] || fail "default (off) must never block a re-read (rc=$rc)"
printf '  PASS  default off — re-reads untouched\n'

# --- 2. deny mode: first read allowed, unchanged re-read denied -------------------

r="$(run_guard "$(read_payload "$WORK/stable.txt")" deny)"; rc="${r%%$'\x1f'*}"
[ "$rc" = "0" ] || fail "first read must be allowed in deny mode (rc=$rc)"
r="$(run_guard "$(read_payload "$WORK/stable.txt")" deny)"; rc="${r%%$'\x1f'*}"; err="${r##*$'\x1f'}"
[ "$rc" = "2" ] || fail "unchanged re-read must be denied (rc=$rc). Stderr: $err"
case "$err" in *'READ-DIET'*'byte-identical'*) : ;; *) fail "deny must explain the re-read. Got: $err" ;; esac
case "$err" in *'MTK_READ_DIET=advise'*) : ;; *) fail "deny must teach the downgrade toggle. Got: $err" ;; esac
printf '  PASS  deny mode blocks unchanged re-read with recovery text\n'

# --- 3. changed file re-allows; partial reads always pass -------------------------

printf 'changed!\n' >> "$WORK/stable.txt"
r="$(run_guard "$(read_payload "$WORK/stable.txt")" deny)"; rc="${r%%$'\x1f'*}"
[ "$rc" = "0" ] || fail "changed file must re-allow the read (rc=$rc)"
r="$(run_guard "$(read_payload "$WORK/stable.txt" '{"offset": 5, "limit": 10}')" deny)"; rc="${r%%$'\x1f'*}"
[ "$rc" = "0" ] || fail "offset/limit reads must always pass (rc=$rc)"
printf '  PASS  edits re-allow; partial reads exempt\n'

# --- 4. advise mode: envelope, never a block --------------------------------------

r="$(run_guard "$(read_payload "$WORK/stable.txt")" advise)"; rc="${r%%$'\x1f'*}"
r="$(run_guard "$(read_payload "$WORK/stable.txt")" advise)"; rc="${r%%$'\x1f'*}"
mid="${r#*$'\x1f'}"; out="${mid%%$'\x1f'*}"
[ "$rc" = "0" ] || fail "advise mode must never block (rc=$rc)"
case "$out" in *'additionalContext'*'READ-DIET (advisory)'*) : ;; *) fail "advise must emit the PreToolUse envelope. Got: $out" ;; esac
printf '  PASS  advise mode emits envelope, never blocks\n'

# --- 5. deny records measured savings ---------------------------------------------

mkdir -p "$WORK/.claude"
rm -f "$TMPDIR_OVERRIDE"/mtk-read-diet-* 2>/dev/null || true
r="$(run_guard "$(read_payload "$WORK/stable.txt")" deny)"
r="$(run_guard "$(read_payload "$WORK/stable.txt")" deny)"
LEDGER="$WORK/.claude/observability/compression.jsonl"
[ -f "$LEDGER" ] || fail "denied re-read must record measured savings"
grep -q '"mode":"read-diet"' "$LEDGER" || fail "savings record must carry mode read-diet"
printf '  PASS  denied re-read lands in the savings ledger\n'

# --- 6. repetition-dominance collapse in mtk-compress -----------------------------

cd "$REPO_ROOT"
REPEAT_INPUT="$(python3 -c "print('header: starting run'); [print('  at Object.<anonymous> (/app/dist/worker.js:114:7)') for _ in range(200)]; print('tail: 1 failed')")"
out="$(printf '%s' "$REPEAT_INPUT" | MTK_COMPRESS_MIN_CHARS=100 bash "$COMPRESS" logs)"
case "$out" in *'repeated 200x — collapsed'*) : ;; *) fail "dominant repeated line must collapse with a count. Got: $(printf '%s' "$out" | head -5)" ;; esac
[ "$(printf '%s' "$out" | grep -c 'worker.js:114')" -eq 1 ] \
  || fail "collapsed line must appear exactly once"
case "$out" in *'tail: 1 failed'*) : ;; *) fail "non-dominant lines must survive the collapse" ;; esac
printf '  PASS  repetition-dominated output collapses to one instance + count\n'

VARIED_INPUT="$(python3 -c "[print(f'line {i} unique content padding padding padding') for i in range(60)]")"
out="$(printf '%s' "$VARIED_INPUT" | MTK_COMPRESS_MIN_CHARS=100 bash "$COMPRESS" logs)"
case "$out" in *'collapsed'*) fail "varied output must not trip the collapse" ;; *) : ;; esac
printf '  PASS  varied output untouched by the collapse\n'

printf '\nAll token-diet checks passed.\n'
