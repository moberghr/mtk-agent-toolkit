#!/usr/bin/env bash
set -euo pipefail
# review-coverage.sh — check that a reviewer lane accounted for every changed file
# (and, optionally, disposed of every deterministic candidate).
#
# Usage:
#   scripts/review-coverage.sh <lane-result.json> <changed-files.txt> [--candidates <candidates.json>]
#
#   lane-result.json   reviewer JSON per .claude/references/review-finding-schema.md
#   changed-files.txt  one repo-relative path per line (blank lines ignored)
#   --candidates       JSON array of {candidate_id, file, line, source, rule, message};
#                      every candidate_id must appear in candidates_disposed[] with
#                      outcome raised|dropped, a non-empty reason and a cited file:line
#
# Rule: set(coverage.no_issues) U set(coverage.skipped[].file) U set(findings[].file)
#       must equal the changed-file set. `coverage` is required on PASS and NEEDS_CHANGES.
#       An ABSTAINED lane result has nothing to check (exit 0).
#
# Exit codes: 0 complete (or ABSTAINED) · 1 incomplete (missing items printed) ·
#             2 unparseable input or usage error

if [ "$#" -lt 2 ]; then
  echo "usage: review-coverage.sh <lane-result.json> <changed-files.txt> [--candidates <file>]" >&2
  exit 2
fi

RESULT="$1"
CHANGED="$2"
shift 2
CANDIDATES=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --candidates)
      CANDIDATES="${2:-}"
      if [ -z "$CANDIDATES" ]; then
        echo "review-coverage: --candidates needs a file" >&2
        exit 2
      fi
      shift 2
      ;;
    *)
      echo "review-coverage: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

for f in "$RESULT" "$CHANGED"; do
  if [ ! -f "$f" ]; then
    echo "review-coverage: not a file: $f" >&2
    exit 2
  fi
done
if [ -n "$CANDIDATES" ] && [ ! -f "$CANDIDATES" ]; then
  echo "review-coverage: not a file: $CANDIDATES" >&2
  exit 2
fi

python3 -I - "$RESULT" "$CHANGED" "$CANDIDATES" <<'PY'
import json
import sys

result_path, changed_path, cand_path = sys.argv[1], sys.argv[2], sys.argv[3]


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as exc:
        print("review-coverage: cannot parse %s: %s" % (path, exc), file=sys.stderr)
        sys.exit(2)


res = load(result_path)
if not isinstance(res, dict):
    print("review-coverage: lane result is not a JSON object", file=sys.stderr)
    sys.exit(2)

verdict = res.get("verdict")
if verdict == "ABSTAINED":
    print("review-coverage: lane ABSTAINED - nothing to check")
    sys.exit(0)
if verdict not in ("PASS", "NEEDS_CHANGES"):
    print("review-coverage: unknown verdict %r" % (verdict,), file=sys.stderr)
    sys.exit(2)

try:
    with open(changed_path, encoding="utf-8") as fh:
        changed = set(line.strip() for line in fh if line.strip())
except OSError as exc:
    print("review-coverage: cannot read %s: %s" % (changed_path, exc), file=sys.stderr)
    sys.exit(2)

problems = []
cov = res.get("coverage")
claimed = set()
if not isinstance(cov, dict):
    problems.append("coverage block missing (required on %s)" % verdict)
else:
    for f in cov.get("no_issues") or []:
        claimed.add(f)
    for s in cov.get("skipped") or []:
        if isinstance(s, dict) and s.get("file"):
            if not str(s.get("reason") or "").strip():
                problems.append("skipped file has no reason: %s" % s["file"])
            claimed.add(s["file"])
        else:
            problems.append("skipped entry without file: %r" % (s,))
for f in res.get("findings") or []:
    if isinstance(f, dict) and f.get("file"):
        claimed.add(f["file"])

if isinstance(cov, dict):
    for f in sorted(changed - claimed):
        problems.append("file not accounted for: %s" % f)
    for f in sorted(claimed - changed):
        problems.append("file claimed but not in changed set: %s" % f)

if cand_path:
    cands = load(cand_path)
    if not isinstance(cands, list):
        print("review-coverage: candidates file is not a JSON array", file=sys.stderr)
        sys.exit(2)
    disposed = {}
    for d in res.get("candidates_disposed") or []:
        if isinstance(d, dict) and d.get("candidate_id"):
            disposed[d["candidate_id"]] = d
    for c in cands:
        cid = c.get("candidate_id") if isinstance(c, dict) else None
        if not cid:
            problems.append("candidate without candidate_id: %r" % (c,))
            continue
        d = disposed.get(cid)
        if d is None:
            problems.append("candidate has no disposition: %s" % cid)
            continue
        if d.get("outcome") not in ("raised", "dropped"):
            problems.append("disposition of %s lacks outcome raised|dropped" % cid)
        if not str(d.get("reason") or "").strip():
            problems.append("disposition of %s lacks reason" % cid)
        if not str(d.get("cited") or "").strip():
            problems.append("disposition of %s lacks cited file:line" % cid)

if problems:
    print("review-coverage: INCOMPLETE")
    for p in problems:
        print("  - " + p)
    sys.exit(1)
print("review-coverage: complete (%d files)" % len(changed))
PY
