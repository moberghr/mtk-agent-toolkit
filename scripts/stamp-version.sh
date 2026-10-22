#!/usr/bin/env bash
set -euo pipefail

# stamp-version.sh — the one writer of a target repo's .claude/mtk-version.json,
# the record of which MTK version's setup files the repo has. setup-bootstrap
# runs it at install; setup-refresh runs it when a refresh finishes, so the
# stamp moves with the generated files (session-start and mtk-doctor compare it
# with the plugin and point at /mtk-setup --refresh when it is older).
#
# Usage: stamp-version.sh [--manifest <plugin manifest.json>] [--compare]
#   Run from the target repo root. The manifest defaults to this script's
#   toolkit (<script dir>/../.claude/manifest.json).
#   --compare  read-only: print "<state> <stamp version> <plugin version>", state
#              one of older | equal | newer (stamp vs plugin, numeric per dot
#              field, so 9.10.0 > 9.4.2) or none (no stamp; stamp version "-").
#              session-start and mtk-doctor use this, so the stamp is parsed in
#              one place.
#
# Writes {"version", "installed", "source", ["refreshed"], ["coding-guidelines"]}:
#   version            the manifest's version
#   installed          kept from an existing stamp, else today
#   refreshed          today, when an existing stamp is updated
#   coding-guidelines  the repo's own pin when the stamp has one (written by
#                      /mtk-setup --update-guidelines), else the manifest's block
# Other keys in an existing stamp are kept. A stamp already at the version is
# left byte-for-byte alone, and a stamp NEWER than the manifest is never lowered
# (an older plugin running a refresh must not downgrade it). The stamp lives at
# the git top level (else the current directory), so running from a
# subdirectory never creates a stray .claude/. Versions compare numerically per
# dot field on their leading digits ("v9.4.2" and "9.4.2-rc1" read as 9.4.2).
#
# Prints one line: "stamped <v>", "stamp <old> -> <v>", "stamp already <v>" or
# "stamp <old> is newer than <v>; left alone".
# Exit: 0 ok · 2 usage error, unreadable manifest or corrupt stamp (nothing written).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$SCRIPT_DIR/../.claude/manifest.json"
MODE="write"
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --compare) MODE="compare"; shift ;;
    -h|--help) awk 'NR > 3 && /^#/ { sub(/^# ?/, ""); print; next } NR > 3 { exit }' "$0"; exit 0 ;;
    *) echo "stamp-version.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
command -v python3 >/dev/null 2>&1 || { echo "stamp-version.sh: python3 is required (S3.3 baseline)" >&2; exit 2; }
TOP="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

python3 - "$MANIFEST" "$TOP/.claude/mtk-version.json" "$MODE" <<'PY'
import datetime, json, os, re, sys
manifest, stamp, mode = sys.argv[1:4]


def key(v):
    parts = []
    for p in str(v).lstrip("vV").split("."):
        m = re.match(r"\d+", p)
        parts.append(int(m.group()) if m else 0)
    return tuple(parts)


def cmp(a, b):
    a, b = key(a), key(b)
    n = max(len(a), len(b))
    a, b = a + (0,) * (n - len(a)), b + (0,) * (n - len(b))
    return (a > b) - (a < b)

try:
    with open(manifest, encoding="utf-8") as fh:
        pm = json.load(fh)
    version = pm["version"]
except (OSError, ValueError, KeyError, TypeError) as exc:
    sys.stderr.write("stamp-version.sh: cannot read the version from %s: %s\n" % (manifest, exc))
    sys.exit(2)
old = {}
if os.path.exists(stamp):
    try:
        with open(stamp, encoding="utf-8") as fh:
            old = json.load(fh)
        if not isinstance(old, dict):
            raise ValueError("not a JSON object")
    except (OSError, ValueError) as exc:
        sys.stderr.write("stamp-version.sh: %s is unreadable (%s); fix or remove it, nothing written\n" % (stamp, exc))
        sys.exit(2)
have = old.get("version")
if mode == "compare":
    if not have:
        print("none - %s" % version)
    else:
        print("%s %s %s" % ({-1: "older", 0: "equal", 1: "newer"}[cmp(have, version)], have, version))
    sys.exit(0)
if have == version:
    print("stamp already %s" % version)
    sys.exit(0)
if have and cmp(have, version) > 0:
    print("stamp %s is newer than %s; left alone" % (have, version))
    sys.exit(0)
today = datetime.date.today().isoformat()
out = dict(old)
out["version"] = version
out["installed"] = old.get("installed") or today
out["source"] = "https://github.com/moberghr/mtk-agent-toolkit"
if old:
    out["refreshed"] = today
cg = old.get("coding-guidelines") or pm.get("coding-guidelines")
if cg:
    out["coding-guidelines"] = cg
os.makedirs(os.path.dirname(stamp), exist_ok=True)
tmp = stamp + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(out, fh, indent=2)
    fh.write("\n")
os.replace(tmp, stamp)
print("stamp %s -> %s" % (old["version"], version) if old.get("version") else "stamped %s" % version)
PY
