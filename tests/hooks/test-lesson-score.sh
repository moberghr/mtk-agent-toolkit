#!/usr/bin/env bash
set -euo pipefail

# lesson-score.sh: staleness/confidence score per lesson, suggest-only (it
# ranks, never decides and never writes to any lesson store). Covers SC9.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCORER="$REPO_ROOT/scripts/lesson-score.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$WORK/.mtk"
LEARNINGS="$WORK/.mtk/learnings.jsonl"
RECALL_LOG="$WORK/.mtk/recall-log.jsonl"
ANCHORS="$WORK/anchors.txt"
NOW="2026-09-23T00:00:00Z"

# Fixture: 7 lessons.
#   L-FRESH   recurrence 1, captured 7 days ago (inside the 4-week grace)
#             -> score 0.30, below 0.40 but NOT due: a fresh lesson is never
#             due, and it sorts after every due lesson.
#   L-STRONG  recurrence 3, reconfirmed 22d ago, 2 recalls within 90d
#             (base 0.70 + 0.10 recall + 0.10 reconfirm, no decay — weeks
#             since last signal is under the 4-week grace) -> 0.70+0.10+0.10
#             = 0.90 exactly. Hand-computed expected value, asserted below.
#   L-MEDIUM  recurrence 2, no recalls, no reconfirmation, last signal 53
#             days ago (base 0.50, some decay past the 4-week grace)
#   L-WEAK    recurrence 1, no recent recalls, last signal 34 days ago
#             (base 0.30, modest decay) — also has ONE recall in the log,
#             but it is 265 days old (outside the 90-day window), so it must
#             NOT contribute the +0.05/recall bonus. If it were wrongly
#             counted the score would be higher than asserted below.
#   L-ROTTEN  recurrence 1, expired, and cited by a stale anchor supplied
#             via --anchors-output (matched to its title) -> clamped to the
#             0.05 floor.
#   L-EXPDATE recurrence 3, captured 3 days ago (no decay), no recalls, no
#             reconfirmation, expired:false BUT expires_at in the past ->
#             penalised by the expires_at branch alone: 0.70 - 0.20 = 0.50
#             (0.70 if that branch were dropped). Not due (inside the grace).
#   L-EXPFLAG recurrence 6, captured 3 days ago (no decay), no recalls, no
#             reconfirmation, expired:true with a FUTURE expires_at ->
#             penalised by the flag alone: 0.85 - 0.20 = 0.65 (0.85 if that
#             branch were dropped). Not due.
# Hand-computed order (due first, then ascending score):
#   L-ROTTEN 0.05 due, L-WEAK 0.28 due, L-FRESH 0.30, L-MEDIUM 0.43,
#   L-EXPDATE 0.50, L-EXPFLAG 0.65, L-STRONG 0.90.
cat > "$LEARNINGS" <<'EOF'
{"id":"L-STRONG","title":"Strong lesson healthy","recurrence":{"count":3,"last_seen_at":"2026-09-10T00:00:00Z"},"captured_at":"2026-01-01T00:00:00Z","validity":{"expires_at":"2027-01-01T00:00:00Z","reconfirmed_at":"2026-09-01T00:00:00Z","expired":false}}
{"id":"L-MEDIUM","title":"Medium lesson decaying","recurrence":{"count":2,"last_seen_at":"2026-08-01T00:00:00Z"},"captured_at":"2026-06-01T00:00:00Z","validity":{"expires_at":"2027-06-01T00:00:00Z","reconfirmed_at":null,"expired":false}}
{"id":"L-WEAK","title":"Weak lesson old no recalls","recurrence":{"count":1,"last_seen_at":"2026-08-20T00:00:00Z"},"captured_at":"2026-08-20T00:00:00Z","validity":{"expires_at":"2027-08-20T00:00:00Z","reconfirmed_at":null,"expired":false}}
{"id":"L-FRESH","title":"Fresh lesson one week old","recurrence":{"count":1,"last_seen_at":"2026-09-16T00:00:00Z"},"captured_at":"2026-09-16T00:00:00Z","validity":{"expires_at":"2027-09-16T00:00:00Z","reconfirmed_at":null,"expired":false}}
{"id":"L-ROTTEN","title":"Rotten lesson stale anchor case","recurrence":{"count":1,"last_seen_at":"2024-01-01T00:00:00Z"},"captured_at":"2024-01-01T00:00:00Z","validity":{"expires_at":"2024-06-01T00:00:00Z","reconfirmed_at":null,"expired":true}}
{"id":"L-EXPDATE","title":"Date expired flag unset","recurrence":{"count":3,"last_seen_at":"2026-09-20T00:00:00Z"},"captured_at":"2026-09-20T00:00:00Z","validity":{"expires_at":"2026-09-01T00:00:00Z","reconfirmed_at":null,"expired":false}}
{"id":"L-EXPFLAG","title":"Flag expired date future","recurrence":{"count":6,"last_seen_at":"2026-09-20T00:00:00Z"},"captured_at":"2026-09-20T00:00:00Z","validity":{"expires_at":"2027-09-01T00:00:00Z","reconfirmed_at":null,"expired":true}}
EOF

cat > "$RECALL_LOG" <<'EOF'
{"ts":"2026-09-15T00:00:00Z","surfaced":["L-STRONG"]}
{"ts":"2026-09-20T00:00:00Z","surfaced":["L-STRONG"]}
{"ts":"2025-01-01T00:00:00Z","surfaced":["L-WEAK"]}
EOF

cat > "$ANCHORS" <<'EOF'
tasks/lessons.md:10: STALE-PATH `some/deleted/path.sh` (lesson: Rotten lesson stale anchor case)
EOF

run() {
  bash "$SCORER" --learnings "$LEARNINGS" --recall-log "$RECALL_LOG" \
    --anchors-output "$ANCHORS" --now "$NOW" "$@"
}

# --- text output, default (ascending) order --------------------------------
text_out="$(run)"

[ "$(printf '%s\n' "$text_out" | wc -l | tr -d ' ')" -eq 7 ] \
  || fail "expected 7 rows in text output, got: $text_out"

first_id="$(awk -F'\t' 'NR==1{print $3; exit}' <<<"$text_out")"
[ "$first_id" = "L-ROTTEN" ] \
  || fail "default output must list the lowest score (rotten) first, got: $first_id"
printf '  PASS  default text output lists rotten first\n'

ids_in_order="$(printf '%s\n' "$text_out" | awk -F'\t' '{print $3}' | tr '\n' ' ')"
[ "$ids_in_order" = "L-ROTTEN L-WEAK L-FRESH L-MEDIUM L-EXPDATE L-EXPFLAG L-STRONG " ] \
  || fail "expected due-first then ascending: rotten,weak,fresh,medium,expdate,expflag,strong; got: $ids_in_order"
printf '  PASS  due first (rotten, weak), then ascending fresh < medium < expdate < expflag < strong\n'

# --- expiry branches, isolated (T3) ------------------------------------------
# One lesson per branch: each is penalised by exactly one of the two conditions.
for spec in "L-EXPDATE 0.50" "L-EXPFLAG 0.65"; do
  lid="${spec%% *}"; want="${spec#* }"
  line="$(grep -F "$lid" <<<"$text_out")"
  got="$(awk -F'\t' '{print $1}' <<<"$line")"
  [ "$got" = "$want" ] || fail "$lid must score $want (expiry penalty applied), got: $got"
  case "$(awk -F'\t' '{print $5}' <<<"$line")" in
    *'expired=true'*) : ;;
    *) fail "$lid must report expired=true, got: $line" ;;
  esac
  [ "$(awk -F'\t' '{print $2}' <<<"$line")" != "due" ] || fail "$lid is inside the grace period and must not be due"
done
printf '  PASS  expired:false + past expires_at, and expired:true + future expires_at, are each penalised\n'

fresh_line="$(grep -F 'L-FRESH' <<<"$text_out")"
fresh_score="$(awk -F'\t' '{print $1}' <<<"$fresh_line")"
fresh_due="$(awk -F'\t' '{print $2}' <<<"$fresh_line")"
[ "$fresh_score" = "0.30" ] || fail "L-FRESH must score 0.30, got: $fresh_score"
[ "$fresh_due" != "due" ] || fail "L-FRESH is inside the grace period and must NOT be due"
printf '  PASS  fresh lesson below 0.40 is not due inside the grace period\n'

# --- hand-computed exact score ----------------------------------------------
# L-STRONG: base(recurrence=3)=0.70, +0.10 (2 recalls within 90d, capped),
# +0.10 (reconfirmed within 180d), 0 decay (last signal 3 days ago, under the
# 4-week grace), not expired, no stale anchor -> 0.70+0.10+0.10 = 0.90.
strong_line="$(printf '%s\n' "$text_out" | grep -F 'L-STRONG')"
strong_score="$(printf '%s\n' "$strong_line" | awk -F'\t' '{print $1}')"
[ "$strong_score" = "0.90" ] \
  || fail "hand-computed score for L-STRONG must be exactly 0.90, got: $strong_score"
printf '  PASS  L-STRONG scores exactly 0.90 (hand-computed)\n'

# --- range check -------------------------------------------------------------
while IFS=$'\t' read -r score _due _id _title _signals; do
  awk -v s="$score" 'BEGIN { exit !(s >= 0.05 && s <= 0.95) }' \
    || fail "score $score out of [0.05, 0.95] range"
done <<< "$text_out"
printf '  PASS  all scores within [0.05, 0.95]\n'

# --- due flag -----------------------------------------------------------------
rotten_due="$(printf '%s\n' "$text_out" | grep -F 'L-ROTTEN' | awk -F'\t' '{print $2}')"
weak_due="$(printf '%s\n' "$text_out" | grep -F 'L-WEAK' | awk -F'\t' '{print $2}')"
strong_due="$(printf '%s\n' "$text_out" | grep -F 'L-STRONG' | awk -F'\t' '{print $2}')"
[ "$rotten_due" = "due" ] || fail "L-ROTTEN must be flagged due, got: $rotten_due"
[ "$weak_due" = "due" ] || fail "L-WEAK must be flagged due, got: $weak_due"
[ "$strong_due" != "due" ] || fail "L-STRONG must NOT be flagged due, got: $strong_due"
printf '  PASS  due flag present for rotten/weak, absent for strong\n'

# --- recalls older than 90 days are not counted -----------------------------
weak_signals="$(printf '%s\n' "$text_out" | grep -F 'L-WEAK' | awk -F'\t' '{print $5}')"
case "$weak_signals" in
  *'recalls_90d=0'*) : ;;
  *) fail "L-WEAK's 265-day-old recall must not count toward recalls_90d. Got: $weak_signals" ;;
esac
printf '  PASS  recalls older than 90 days are excluded\n'

# --- missing recall log tolerated --------------------------------------------
rc=0
bash "$SCORER" --learnings "$LEARNINGS" --recall-log "$WORK/does-not-exist.jsonl" \
  --anchors-output "$ANCHORS" --now "$NOW" > /dev/null 2>"$WORK/stderr.log" || rc=$?
[ "$rc" -eq 0 ] || fail "missing recall log must be tolerated (exit 0), got rc=$rc, stderr: $(cat "$WORK/stderr.log")"
printf '  PASS  missing recall log tolerated\n'

# --- missing learnings file --------------------------------------------------
rc=0
missing_out="$(bash "$SCORER" --learnings "$WORK/no-such-learnings.jsonl" 2>"$WORK/stderr2.log")" || rc=$?
[ "$rc" -eq 0 ] || fail "missing learnings file must exit 0, got rc=$rc"
[ "$missing_out" = "no lessons" ] || fail "missing learnings file must print 'no lessons', got: $missing_out"
printf '  PASS  missing learnings file prints "no lessons" and exits 0\n'

# --- --json parses and matches the text-mode ordering/scores ----------------
json_out="$(run --json)"
python3 -c "
import json, sys
rows = json.loads(sys.argv[1])
assert isinstance(rows, list) and len(rows) == 7, rows
ids = [r['id'] for r in rows]
assert ids == ['L-ROTTEN', 'L-WEAK', 'L-FRESH', 'L-MEDIUM', 'L-EXPDATE', 'L-EXPFLAG', 'L-STRONG'], ids
for lid, want in (('L-EXPDATE', 0.50), ('L-EXPFLAG', 0.65)):
    r = next(x for x in rows if x['id'] == lid)
    assert r['score'] == want and r['signals']['expired'] is True and r['due'] is False, r
strong = next(r for r in rows if r['id'] == 'L-STRONG')
assert strong['score'] == 0.90, strong
assert strong['due'] is False, strong
rotten = next(r for r in rows if r['id'] == 'L-ROTTEN')
fresh = next(r for r in rows if r['id'] == 'L-FRESH')
assert fresh['score'] == 0.30 and fresh['due'] is False, fresh
assert rotten['due'] is True, rotten
weak = next(r for r in rows if r['id'] == 'L-WEAK')
assert weak['signals']['recalls_90d'] == 0, weak
for r in rows:
    for key in ('recurrence', 'recalls_90d', 'reconfirmed_recent', 'weeks_since_signal', 'expired', 'stale_anchor'):
        assert key in r['signals'], (r['id'], key)
    assert 0.05 <= r['score'] <= 0.95, r
" "$json_out" || fail "--json output failed to parse or validate. Got: $json_out"
printf '  PASS  --json parses and matches expected shape/ordering/scores\n'

# --- --help prints the whole header (F008) ------------------------------------
help_out="$(bash "$SCORER" --help)"
case "$help_out" in
  *python3*) : ;;
  *) fail "--help must mention python3, got: $help_out" ;;
esac
case "$help_out" in
  *"its absence is a hard exit-2 with a clear message, not a silent fallback."*) : ;;
  *) fail "--help must print the header's last sentence, got: $help_out" ;;
esac
case "$help_out" in
  *'#!/usr/bin/env'*|*'set -euo'*|*'SCRIPT_DIR='*) fail "--help leaked non-header lines: $help_out" ;;
esac
printf '  PASS  --help prints the full header comment and nothing else\n'

# --- suggest-only: never writes to the learnings store -----------------------
before_hash="$(cksum "$LEARNINGS" | awk '{print $1" "$2}')"
run --json > /dev/null
after_hash="$(cksum "$LEARNINGS" | awk '{print $1" "$2}')"
[ "$before_hash" = "$after_hash" ] || fail "lesson-score.sh must never modify the learnings store"
printf '  PASS  learnings store is untouched (suggest-only)\n'

printf '\nAll lesson-score checks passed.\n'
