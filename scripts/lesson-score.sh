#!/usr/bin/env bash
set -euo pipefail

# lesson-score.sh — a staleness/confidence score per lesson in
# .mtk/learnings.jsonl, computed from signals already stored: recurrence,
# reconfirmation, recall history and stale anchors (scripts/lesson-anchors.sh).
#
# SUGGEST-ONLY, like lesson-anchors.sh: this script ranks. It never writes to
# any lesson store and never decides a verdict — `lesson-refresh` triages,
# using the score only to order which lessons get the deepest checks first.
#
# Score (base by recurrence.count, then adjustments, clamped to [0.05, 0.95]):
#   base:      1 -> 0.30, 2 -> 0.50, 3-5 -> 0.70, 6+ -> 0.85
#   +0.05 per recall in the last 90 days, capped at +0.15
#   +0.10 if validity.reconfirmed_at is within the last 180 days
#   -0.02 per week since the last signal (max of captured_at,
#         recurrence.last_seen_at, reconfirmed_at, last recall), after a
#         4-week grace period
#   -0.20 if validity.expired is true, or expires_at has passed
#   -0.20 if the lesson has a stale anchor (lesson-anchors.sh STALE-* finding
#         whose reported heading substring-matches the lesson title)
# `due` is set when the score is below 0.40 AND the last signal is older than
# the 4-week grace period (a fresh lesson is never due). Output lists due
# lessons first, then everything by ascending score.
#
# Usage:
#   bash scripts/lesson-score.sh [--learnings FILE] [--recall-log FILE]
#                                 [--anchors-output FILE|-] [--now ISO] [--json]
#
# Defaults:
#   --learnings   <project root>/.mtk/learnings.jsonl
#   --recall-log  <project root>/.mtk/recall-log.jsonl (missing file tolerated)
#   anchors       runs `bash <script dir>/lesson-anchors.sh` and maps its
#                 STALE-PATH/STALE-SYMBOL findings to lessons by heading; pass
#                 --anchors-output to supply that text directly (a file, or
#                 "-" for stdin) instead of running the checker — used by
#                 tests to avoid scanning the real lesson stores.
#   --now         current UTC time (ISO 8601, e.g. 2026-09-23T07:18:54Z)
#
# A missing learnings file is not an error: prints "no lessons" and exits 0.
# python3 is required (accepted S3.3 baseline) for the scoring/JSON parsing;
# its absence is a hard exit-2 with a clear message, not a silent fallback.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

LEARNINGS="$ROOT_DIR/.mtk/learnings.jsonl"
RECALL_LOG="$ROOT_DIR/.mtk/recall-log.jsonl"
ANCHORS_OUTPUT=""
ANCHORS_MODE="auto" # auto | file | stdin
NOW=""
JSON_OUT=0

usage() {
  # The leading comment block, by shape (a hard-coded line range goes stale as
  # the header grows): from the first '#' line after the shebang/set lines to
  # the first non-'#' line.
  awk 'NR < 3 { next } /^#/ { started = 1; sub(/^# ?/, ""); print; next } started { exit }' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --learnings) LEARNINGS="${2:?--learnings needs a value}"; shift 2 ;;
    --recall-log) RECALL_LOG="${2:?--recall-log needs a value}"; shift 2 ;;
    --anchors-output)
      ANCHORS_OUTPUT="${2:?--anchors-output needs a value}"
      if [ "$ANCHORS_OUTPUT" = "-" ]; then
        ANCHORS_MODE="stdin"
      else
        ANCHORS_MODE="file"
      fi
      shift 2
      ;;
    --now) NOW="${2:?--now needs a value}"; shift 2 ;;
    --json) JSON_OUT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'lesson-score: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || {
  printf 'lesson-score: python3 is required but was not found on PATH\n' >&2
  exit 2
}

if [ ! -f "$LEARNINGS" ]; then
  echo "no lessons"
  exit 0
fi

[ -n "$NOW" ] || NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Anchors text always lands in a temp file so the python step has one uniform
# input regardless of source (auto-run, --anchors-output FILE, or stdin).
ANCHORS_TMP="$(mktemp)"
cleanup() { rm -f "$ANCHORS_TMP"; }
trap cleanup EXIT

case "$ANCHORS_MODE" in
  stdin)
    cat > "$ANCHORS_TMP"
    ;;
  file)
    cat "$ANCHORS_OUTPUT" > "$ANCHORS_TMP" 2>/dev/null || true
    ;;
  auto)
    if [ -f "$SCRIPT_DIR/lesson-anchors.sh" ]; then
      CLAUDE_PROJECT_DIR="$ROOT_DIR" bash "$SCRIPT_DIR/lesson-anchors.sh" > "$ANCHORS_TMP" 2>/dev/null || true
    fi
    ;;
esac

# A missing recall log is tolerated: pass an empty path so python treats it
# as "no recall history" rather than an error.
RECALL_ARG=""
[ -f "$RECALL_LOG" ] && RECALL_ARG="$RECALL_LOG"

python3 - "$LEARNINGS" "$RECALL_ARG" "$ANCHORS_TMP" "$NOW" "$JSON_OUT" <<'PYEOF'
import sys, json, re
from datetime import datetime, timezone, timedelta

learnings_path, recall_path, anchors_path, now_str, json_out_flag = sys.argv[1:6]
json_out = json_out_flag == "1"


def parse_iso(s):
    if not s:
        return None
    s = s.strip()
    if not s:
        return None
    try:
        s2 = s[:-1] + "+00:00" if s.endswith("Z") else s
        dt = datetime.fromisoformat(s2)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except Exception:
        return None


def base_for_count(count):
    try:
        count = int(count)
    except Exception:
        count = 1
    if count <= 1:
        return 0.30
    if count == 2:
        return 0.50
    if 3 <= count <= 5:
        return 0.70
    return 0.85


now = parse_iso(now_str) or datetime.now(timezone.utc)

entries = []
try:
    with open(learnings_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except Exception:
                continue
except FileNotFoundError:
    entries = []

# recall log: lesson id -> list of recall datetimes (any age; the 90-day
# window is applied per-lesson below, not here)
recalls = {}
if recall_path:
    try:
        with open(recall_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except Exception:
                    continue
                ts = parse_iso(row.get("ts"))
                if ts is None:
                    continue
                for lid in row.get("surfaced") or []:
                    recalls.setdefault(lid, []).append(ts)
    except FileNotFoundError:
        pass

# anchors: pull the "(lesson: <heading>)" text out of every STALE-* line
anchor_headings = []
try:
    with open(anchors_path, "r", encoding="utf-8") as f:
        text = f.read()
    for line in text.splitlines():
        if "STALE-" not in line:
            continue
        for m in re.findall(r"\(lesson:\s*([^)]*)\)", line):
            h = m.strip().lower()
            if h:
                anchor_headings.append(h)
except FileNotFoundError:
    pass

rows = []
for e in entries:
    lid = e.get("id", "")
    title = e.get("title", "") or ""
    recurrence = e.get("recurrence") or {}
    count = recurrence.get("count", 1)
    base = base_for_count(count)

    lesson_recalls = recalls.get(lid, [])
    recalls_90 = [t for t in lesson_recalls if (now - t) <= timedelta(days=90)]
    recall_bonus = min(0.05 * len(recalls_90), 0.15)

    validity = e.get("validity") or {}
    reconfirmed_at = parse_iso(validity.get("reconfirmed_at"))
    reconfirmed_recent = bool(
        reconfirmed_at and (now - reconfirmed_at) <= timedelta(days=180)
    )
    reconfirm_bonus = 0.10 if reconfirmed_recent else 0.0

    candidates = []
    captured_at = parse_iso(e.get("captured_at"))
    if captured_at:
        candidates.append(captured_at)
    last_seen_at = parse_iso(recurrence.get("last_seen_at"))
    if last_seen_at:
        candidates.append(last_seen_at)
    if reconfirmed_at:
        candidates.append(reconfirmed_at)
    if lesson_recalls:
        candidates.append(max(lesson_recalls))
    last_signal = max(candidates) if candidates else None
    if last_signal is not None:
        weeks_since_signal = max((now - last_signal).total_seconds(), 0.0) / (7 * 86400)
    else:
        weeks_since_signal = 0.0
    grace_weeks = 4.0
    decay = max(weeks_since_signal - grace_weeks, 0.0) * 0.02

    expires_at = parse_iso(validity.get("expires_at"))
    expired = bool(validity.get("expired")) or (expires_at is not None and expires_at < now)
    expired_penalty = 0.20 if expired else 0.0

    title_l = title.strip().lower()
    stale_anchor = False
    if len(title_l) >= 3:
        for h in anchor_headings:
            if title_l in h or h in title_l:
                stale_anchor = True
                break
    anchor_penalty = 0.20 if stale_anchor else 0.0

    raw_score = base + recall_bonus + reconfirm_bonus - decay - expired_penalty - anchor_penalty
    raw_score = max(0.05, min(0.95, raw_score))
    score = round(raw_score, 2)
    # Due only once the lesson has gone quiet past the grace period: a fresh
    # one-off lesson starts at 0.30 and would otherwise be "due" on day 0,
    # which inverts refresh's check-the-oldest-first intent.
    due = score < 0.40 and weeks_since_signal > grace_weeks

    rows.append(
        {
            "id": lid,
            "title": title,
            "score": score,
            "due": due,
            "signals": {
                "recurrence": count,
                "recalls_90d": len(recalls_90),
                "reconfirmed_recent": reconfirmed_recent,
                "weeks_since_signal": round(weeks_since_signal, 1),
                "expired": expired,
                "stale_anchor": stale_anchor,
            },
        }
    )

rows.sort(key=lambda r: (not r["due"], r["score"]))

if json_out:
    print(json.dumps(rows))
else:
    for r in rows:
        due_s = "due" if r["due"] else "-"
        sig = r["signals"]
        sig_s = (
            "recurrence=%s,recalls_90d=%s,reconfirmed=%s,weeks=%s,expired=%s,stale_anchor=%s"
            % (
                sig["recurrence"],
                sig["recalls_90d"],
                str(sig["reconfirmed_recent"]).lower(),
                sig["weeks_since_signal"],
                str(sig["expired"]).lower(),
                str(sig["stale_anchor"]).lower(),
            )
        )
        print("%.2f\t%s\t%s\t%s\t%s" % (r["score"], due_s, r["id"], r["title"], sig_s))
PYEOF
