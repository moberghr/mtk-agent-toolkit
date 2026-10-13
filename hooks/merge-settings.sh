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
- permissions.allow / permissions.deny / permissions.ask: union of both arrays
- permissions.allowedTools (not a Claude Code key, so it is ignored): folded
  into permissions.allow on either side and dropped from the output
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

# Narrow allowedTools entries that may be activated: the one shared list.
NARROW_LIST="$(cd "$(dirname "$0")" && pwd)/lib/narrow-permissions.txt"
[ -f "$NARROW_LIST" ] || { echo "ERROR: $NARROW_LIST not found; no merge performed." >&2; exit 2; }

python3 - "$SOURCE" "$TARGET" "$NARROW_LIST" <<'PY'
import json
import re
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


source_path, target_path, narrow_path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    source = load(source_path)
    target = load(target_path)
except (ValueError, OSError) as exc:
    sys.stderr.write(
        "WARNING: could not parse settings as JSON (%s). "
        "No merge performed.\n" % exc
    )
    sys.exit(2)

# The narrow list is shared with scripts/migrate-settings-permissions.sh.
def load_narrow(path):
    with open(path, encoding="utf-8") as fh:
        return [l.strip() for l in fh if l.strip() and not l.lstrip().startswith("#")]


def is_narrow(entry, prefixes):
    """Exactly Bash(<prefix>), Bash(<prefix>:*) or Bash(<prefix> <args>): fullmatch
    (a trailing newline fails), single spaces only, no shell metacharacters."""
    if not isinstance(entry, str):
        return False
    m = re.fullmatch(r"Bash\(([^()]*)\)", entry)
    if not m:
        return False
    cmd = m.group(1)
    if re.search(r"[^\S ]", cmd) or "  " in cmd or cmd != cmd.strip():
        return False
    if re.search(r"[;&|$<>`]", cmd):
        return False
    return any(cmd == p or cmd == p + ":*" or cmd.startswith(p + " ") for p in prefixes)

PREFIXES = load_narrow(narrow_path)


def fold_legacy_allowed_tools(doc, label):
    """Claude Code reads permissions.allow / deny / ask. permissions.allowedTools
    is not a settings key (it is the --allowedTools CLI flag), so a list written
    there has never been in effect. Moving all of it into allow would silently
    switch on rules nobody ran with (Bash(python:*), Bash(curl:*), Write,
    Bash(*)), so only narrow build/test/lint entries move; the rest stays in
    allowedTools, still inert, and is reported for a manual decision. A non-list
    allow is an error, never replaced."""
    perms = doc.get("permissions") if isinstance(doc, dict) else None
    if not isinstance(perms, dict) or "allowedTools" not in perms:
        return doc
    if "allow" in perms and not isinstance(perms["allow"], list):
        sys.stderr.write("ERROR: %s has a non-list permissions.allow; fix it by hand. No merge performed.\n" % label)
        sys.exit(2)
    legacy = perms.get("allowedTools")
    legacy = legacy if isinstance(legacy, list) else []
    allow = perms.get("allow", [])
    allowed = {signature(x) for x in allow}
    pending = [x for x in legacy if signature(x) not in allowed]
    narrow = [x for x in pending if is_narrow(x, PREFIXES)]
    broad = [x for x in pending if x not in narrow]
    for x in narrow:
        sys.stderr.write("activated: %s: %s\n" % (label, json.dumps(x)))
    for x in broad:
        sys.stderr.write("left inert: %s: %s needs a manual decision (permissions.allowedTools is ignored)\n"
                         % (label, json.dumps(x)))
    new_perms = {}
    for k, v in perms.items():
        if k == "allowedTools":
            if "allow" not in perms:
                new_perms["allow"] = union_lists(allow, narrow)
            if broad:
                new_perms["allowedTools"] = broad
            continue
        new_perms[k] = union_lists(allow, narrow) if k == "allow" else v
    doc["permissions"] = new_perms
    return doc


merged = deep_merge(fold_legacy_allowed_tools(target, target_path), fold_legacy_allowed_tools(source, source_path))
sys.stdout.write(json.dumps(merged, indent=2) + "\n")
PY
