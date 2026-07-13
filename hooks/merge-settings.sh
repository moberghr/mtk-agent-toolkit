#!/usr/bin/env bash
#
# Merge two settings.json files by unioning arrays.
# Source (new MTK) + Target (existing repo) → merged output on stdout.
# Falls back to showing a diff if the structure is unexpected.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: hooks/merge-settings.sh <source> <target>

Merges source settings.json into target settings.json:
- permissions.allowedTools: union of both arrays
- permissions.deny: union of both arrays
- hooks.*: append new hook entries, skip duplicates (matched by command)
- Keys in target not in source: preserved
- Keys in source not in target: added
- Scalar conflicts (same key in both): target wins (existing repo config is
  never silently overwritten)

Output: merged JSON on stdout
EOF
  exit 1
}

[ $# -ge 2 ] || usage
SOURCE="$1"
TARGET="$2"

[ -f "$SOURCE" ] || { echo "ERROR: Source not found: $SOURCE" >&2; exit 1; }
[ -f "$TARGET" ] || { echo "ERROR: Target not found: $TARGET" >&2; exit 1; }

# For simple cases: if target doesn't exist or is empty, just use source.
if [ ! -s "$TARGET" ]; then
  cat "$SOURCE"
  exit 0
fi

# The merge is a proper deep merge over parsed JSON — bash text munging can't
# do this without corrupting values (spaces inside "Bash(git diff:*)",
# trailing commas, dropped event types). python3 is the S3.3 baseline.
command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 is required to merge settings JSON." >&2
  exit 2
}

python3 - "$SOURCE" "$TARGET" <<'PY'
import json
import sys


def collect_commands(item):
    """All hook `command` strings anywhere inside an entry, in order."""
    out = []
    if isinstance(item, dict):
        for k, v in item.items():
            if k == "command" and isinstance(v, str):
                out.append(v)
            else:
                out.extend(collect_commands(v))
    elif isinstance(item, list):
        for v in item:
            out.extend(collect_commands(v))
    return out


def signature(item):
    """Dedup key for a list element. Hook groups dedup by their commands
    (the documented contract); everything else by normalized value."""
    cmds = collect_commands(item)
    if cmds:
        return ("cmds", tuple(cmds))
    if isinstance(item, (dict, list)):
        return ("json", json.dumps(item, sort_keys=True))
    return ("scalar", type(item).__name__, item)


def union_lists(target, source):
    """Union preserving target order first, then source-only entries."""
    result = list(target)
    seen = set()
    for x in target:
        seen.add(signature(x))
    for x in source:
        sig = signature(x)
        if sig not in seen:
            result.append(x)
            seen.add(sig)
    return result


def deep_merge(target, source):
    if isinstance(target, dict) and isinstance(source, dict):
        result = dict(target)
        for k, v in source.items():
            if k in result:
                result[k] = deep_merge(result[k], v)
            else:
                result[k] = v
        return result
    if isinstance(target, list) and isinstance(source, list):
        return union_lists(target, source)
    # Scalar or type mismatch: target wins.
    return target


def load(path):
    with open(path, "r") as fh:
        return json.load(fh)


source_path, target_path = sys.argv[1], sys.argv[2]
try:
    source = load(source_path)
    target = load(target_path)
except (ValueError, OSError) as exc:
    sys.stderr.write(
        "WARNING: could not parse settings as JSON (%s). "
        "No merge performed.\n" % exc
    )
    sys.exit(2)

merged = deep_merge(target, source)
sys.stdout.write(json.dumps(merged, indent=2) + "\n")
PY
