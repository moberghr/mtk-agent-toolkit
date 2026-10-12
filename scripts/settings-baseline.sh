#!/usr/bin/env bash
set -euo pipefail

# settings-baseline.sh — the all-stacks permission baseline
# (.claude/references/settings-baseline.md) as data, for repos that need it
# checked or repaired after bootstrap. setup-bootstrap merges the baseline at
# install time; repos bootstrapped before a rule existed (every repo before
# 8.1.0 has no deny baseline at all) are caught here.
#
# Usage:
#   settings-baseline.sh --json
#       Print the baseline's deny/ask rules as a settings.json fragment:
#       {"permissions":{"deny":[...],"ask":[...]}}
#   settings-baseline.sh --missing <settings.json>
#       Print one "<list>\t<rule>" line (list = deny|ask) per baseline rule the
#       file does not carry verbatim. A missing file lacks every rule.
#   settings-baseline.sh --merge <settings.json> [--out <path>]
#       Union the baseline into the file with hooks/merge-settings.sh (arrays are
#       unioned, every existing key and rule is kept). Writes <path> when --out
#       is given (setup-refresh proposes from a temp copy), else rewrites the
#       file in place via a temp file + rename (mtk-doctor --fix). A missing
#       file is created holding the baseline alone.
#
# Exit codes: 0 ok / nothing missing; 1 (--missing) rules are missing;
#             2 usage error, unreadable baseline or settings, or merge failure.
#
# The baseline path defaults to this script's toolkit tree and can be pointed
# elsewhere with MTK_SETTINGS_BASELINE. Rules are the backticked text of each
# `- ` bullet under `### deny` and `### ask`; anything after it is a note.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASELINE="${MTK_SETTINGS_BASELINE:-$SCRIPT_DIR/../.claude/references/settings-baseline.md}"
MERGE="$SCRIPT_DIR/../hooks/merge-settings.sh"

usage() { awk 'NR>3 && /^# /{f=1} f{ if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0" >&2; exit 2; }

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 2; }
[ -f "$BASELINE" ] || { echo "ERROR: baseline not found: $BASELINE" >&2; exit 2; }

baseline_json() {
  python3 - "$BASELINE" <<'PY'
import sys; sys.stdout.reconfigure(newline="\n")  # LF even on Windows python3: bash parses this output
import json, re
lists, cur = {"deny": [], "ask": []}, None
for line in open(sys.argv[1], encoding="utf-8"):
    h = re.match(r"^###\s+(\w+)\s*$", line)
    if h:
        cur = h.group(1) if h.group(1) in lists else None
        continue
    if line.startswith("## "):
        cur = None
        continue
    m = re.match(r"^- `([^`]+)`", line)
    if cur and m:
        lists[cur].append(m.group(1))
print(json.dumps({"permissions": lists}, indent=2))
PY
}

MODE="${1:-}"
case "$MODE" in
  --json)
    baseline_json
    ;;
  --missing)
    TARGET="${2:-}"; [ -n "$TARGET" ] || usage
    MTK_BASELINE_JSON="$(baseline_json)" python3 - "$TARGET" <<'PY'
import sys; sys.stdout.reconfigure(newline="\n")  # LF even on Windows python3: bash parses this output
import json, os
base = json.loads(os.environ["MTK_BASELINE_JSON"])["permissions"]
have = {}
if os.path.exists(sys.argv[1]):
    try:
        doc = json.load(open(sys.argv[1]))
    except ValueError as exc:
        sys.stderr.write("ERROR: %s is not valid JSON (%s)\n" % (sys.argv[1], exc)); sys.exit(2)
    perms = doc.get("permissions", {}) if isinstance(doc, dict) else {}
    have = perms if isinstance(perms, dict) else {}
missing = 0
for key in ("deny", "ask"):
    cur = have.get(key, [])
    cur = set(cur) if isinstance(cur, list) else set()
    for rule in base[key]:
        if rule not in cur:
            print("%s\t%s" % (key, rule)); missing += 1
sys.exit(1 if missing else 0)
PY
    ;;
  --merge)
    TARGET="${2:-}"; [ -n "$TARGET" ] || usage
    OUT=""
    if [ "${3:-}" = "--out" ]; then OUT="${4:-}"; [ -n "$OUT" ] || usage; fi
    [ -f "$MERGE" ] || { echo "ERROR: merge-settings.sh not found: $MERGE" >&2; exit 2; }
    SRC="$(mktemp)"; TMP="$(mktemp)"
    trap 'rm -f "$SRC" "$TMP"' EXIT
    baseline_json > "$SRC"
    if [ -s "$TARGET" ]; then
      bash "$MERGE" "$SRC" "$TARGET" > "$TMP" || { echo "ERROR: merge-settings.sh failed on $TARGET; nothing written" >&2; exit 2; }
    else
      cp "$SRC" "$TMP"
    fi
    DEST="${OUT:-$TARGET}"
    mkdir -p "$(dirname "$DEST")"
    cat "$TMP" > "$DEST.tmp.$$" && mv "$DEST.tmp.$$" "$DEST"
    ;;
  *) usage ;;
esac
