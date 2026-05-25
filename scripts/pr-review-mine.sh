#!/usr/bin/env bash
# pr-review-mine.sh — Mine repeated reviewer-feedback phrases from recent merged PRs.
# Borrowed pattern: github.com/johnpapa/ai-ready (PR review mining).
#
# Output is advisory: tagged `[MINED:feedback]` and never auto-applied.
# Fail-soft: if `gh` is missing or unauthenticated, exits 0 with a single warning line.
#
# Usage:
#   bash scripts/pr-review-mine.sh [--prs N] [--json]
#
# --prs N   number of merged PRs to scan (default 10, range 1-50)
# --json    machine-readable JSON instead of markdown

set -euo pipefail

PR_COUNT=10
OUTPUT_FORMAT="markdown"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prs)
      PR_COUNT="${2:-10}"
      shift 2
      ;;
    --json)
      OUTPUT_FORMAT="json"
      shift
      ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      echo "WARN: unknown arg: $1" >&2
      shift
      ;;
  esac
done

if ! [[ "$PR_COUNT" =~ ^[0-9]+$ ]] || [[ "$PR_COUNT" -lt 1 ]] || [[ "$PR_COUNT" -gt 50 ]]; then
  echo "ERR: --prs must be an integer in 1..50 (got: $PR_COUNT)" >&2
  exit 2
fi

emit_empty() {
  local reason="$1"
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    printf '{"status":"skipped","reason":%s,"phrases":[]}\n' "$(printf '%s' "$reason" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  else
    printf '## PR review mining\n\n_Skipped: %s_\n' "$reason"
  fi
  exit 0
}

# Precondition: gh + jq available
command -v gh >/dev/null 2>&1 || emit_empty "gh CLI not installed"
command -v jq >/dev/null 2>&1 || emit_empty "jq not installed"
gh auth status >/dev/null 2>&1 || emit_empty "gh not authenticated (run: gh auth login)"

# Locate denylist (worktree-aware)
DENYLIST_FILE=""
for candidate in \
  ".claude/references/pr-mining-patterns.md" \
  "$(git rev-parse --show-toplevel 2>/dev/null)/.claude/references/pr-mining-patterns.md"; do
  if [[ -n "$candidate" ]] && [[ -f "$candidate" ]]; then
    DENYLIST_FILE="$candidate"
    break
  fi
done

# Build denylist regex from the reference (lines under "## Denylist" until next "## ").
DENYLIST_REGEX='^(lgtm|ship it|thanks|nit|nice|👍|done|fixed|approved|approve|looks good|good catch|sgtm|wfm|same here|\+1)$'
if [[ -n "$DENYLIST_FILE" ]]; then
  EXTRACTED=$(awk '/^## Denylist/{flag=1;next} /^## /{flag=0} flag && /^- /{sub(/^- `?/,""); sub(/`?$/,""); print tolower($0)}' "$DENYLIST_FILE" | sed 's/[][\.*+?(){}|^$\\]/\\&/g' | paste -sd'|' -)
  if [[ -n "$EXTRACTED" ]]; then
    DENYLIST_REGEX="^(${EXTRACTED})$"
  fi
fi

# Detect default branch
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "main")

# Fetch merged PR numbers (last N).
PR_NUMS=$(gh pr list --state merged --base "$DEFAULT_BRANCH" --limit "$PR_COUNT" --json number --jq '.[].number' 2>/dev/null || true)
if [[ -z "$PR_NUMS" ]]; then
  emit_empty "no merged PRs found on $DEFAULT_BRANCH"
fi

# Collect all review-thread comment bodies. Both top-level PR review summaries
# and per-line review comments count. Issue comments on the PR are NOT included
# (those are usually status chatter, not actionable feedback).
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

SCANNED_PRS=()
while read -r pr; do
  [[ -z "$pr" ]] && continue
  SCANNED_PRS+=("$pr")
  # Per-line review comments
  gh api "repos/{owner}/{repo}/pulls/${pr}/comments" --paginate \
    --jq '.[] | {pr: '"$pr"', body: .body}' 2>/dev/null >> "$TMPFILE" || true
  # PR review summaries (body)
  gh api "repos/{owner}/{repo}/pulls/${pr}/reviews" --paginate \
    --jq '.[] | select(.body != null and .body != "") | {pr: '"$pr"', body: .body}' 2>/dev/null >> "$TMPFILE" || true
done <<< "$PR_NUMS"

# Normalize + cluster. Python keeps clustering deterministic and readable.
RESULT=$(python3 - "$TMPFILE" "$DENYLIST_REGEX" <<'PY'
import json, re, sys
from collections import defaultdict

path, denylist_regex = sys.argv[1], sys.argv[2]
denylist = re.compile(denylist_regex, re.IGNORECASE)

records = []
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

# Sentence-level extraction.
def normalize(text):
    BT = chr(96)
    text = re.sub(BT*3 + r".*?" + BT*3, " ", text, flags=re.DOTALL)  # strip code fences
    text = re.sub(BT + r"[^" + BT + r"]+" + BT, " ", text)            # strip inline code
    text = re.sub(r"@[\w-]+", " ", text)                        # strip mentions
    text = re.sub(r"https?://\S+", " ", text)                   # strip URLs
    text = re.sub(r"[#*_>\-]", " ", text)                        # strip markdown
    text = re.sub(r"\s+", " ", text).strip().lower()
    return text

# 4-gram phrase clustering: keep imperative-ish phrases (start with a verb).
IMPERATIVE_HINTS = {
    "add", "remove", "use", "rename", "extract", "wrap", "guard", "test",
    "check", "verify", "consider", "prefer", "avoid", "split", "move",
    "rename", "document", "update", "log", "throw", "raise", "validate",
    "inject", "mock", "stub", "refactor", "rename", "fix", "handle",
}

phrase_counts = defaultdict(lambda: {"count": 0, "prs": set()})

for rec in records:
    pr = rec.get("pr")
    body = rec.get("body") or ""
    norm = normalize(body)
    if not norm:
        continue
    # Split into sentences (very loose).
    for sent in re.split(r"[.!?\n]+", norm):
        sent = sent.strip()
        if not sent or len(sent) < 8:
            continue
        # Tokenize.
        words = re.findall(r"[a-z][a-z0-9]+", sent)
        if len(words) < 3:
            continue
        first = words[0]
        if first not in IMPERATIVE_HINTS:
            continue
        # Use the first 4 words as the cluster key.
        key = " ".join(words[:4])
        if denylist.match(key):
            continue
        phrase_counts[key]["count"] += 1
        phrase_counts[key]["prs"].add(pr)

# Keep phrases with >=2 occurrences AND seen across >=2 distinct PRs
# (one ranty PR with the same comment 5 times doesn't make a rule).
keep = []
for key, val in phrase_counts.items():
    if val["count"] >= 2 and len(val["prs"]) >= 2:
        keep.append({
            "phrase": key,
            "count": val["count"],
            "prs": sorted(val["prs"]),
        })
keep.sort(key=lambda x: (-x["count"], x["phrase"]))
print(json.dumps(keep))
PY
)

# Render output
if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  printf '{"status":"ok","scanned_prs":%d,"phrases":%s}\n' "${#SCANNED_PRS[@]}" "$RESULT"
  exit 0
fi

echo "## PR review mining"
echo ""
echo "Scanned ${#SCANNED_PRS[@]} merged PRs on '${DEFAULT_BRANCH}'."
echo ""

PHRASE_COUNT=$(echo "$RESULT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')

if [[ "$PHRASE_COUNT" -eq 0 ]]; then
  echo "_No repeated reviewer-feedback patterns found (≥2 occurrences across ≥2 PRs)._"
  exit 0
fi

echo "Found $PHRASE_COUNT candidate \`[MINED:feedback]\` phrase(s). Suggest-only — review and edit before promoting into \`architecture-principles.md\`."
echo ""
echo "| Phrase | Occurrences | PRs |"
echo "|---|---:|---|"
RENDER_SCRIPT=$(mktemp)
cat > "$RENDER_SCRIPT" <<'PYEND'
import json, sys
data = json.loads(sys.stdin.read())
BT = chr(96)
for p in data:
    prs = ", ".join("#" + str(n) for n in p["prs"])
    print("| " + BT + p["phrase"] + BT + " | " + str(p["count"]) + " | " + prs + " |")
PYEND
echo "$RESULT" | python3 "$RENDER_SCRIPT"
rm -f "$RENDER_SCRIPT"
