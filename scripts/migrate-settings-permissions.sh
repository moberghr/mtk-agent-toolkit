#!/usr/bin/env bash
set -euo pipefail

# migrate-settings-permissions.sh — move the narrow build/test/lint entries of
# the invalid `permissions.allowedTools` key into `permissions.allow`.
#
# Claude Code's permission keys are `permissions.allow`, `permissions.deny` and
# `permissions.ask`. There is no `permissions.allowedTools` (that name is a CLI
# flag, `--allowedTools`), so an allow list written under it has never been in
# effect. Moving it wholesale would silently switch on rules nobody ever ran
# with — `Bash(python:*)`, `Bash(npx:*)`, `Bash(curl:*)`, `Write`, `Bash(*)`. So
# only entries on the narrow allow-list in hooks/lib/narrow-permissions.txt
# (shared with hooks/merge-settings.sh) move automatically: dotnet
# build/test/format, npm/pnpm/yarn test/build/lint, pytest, ruff check/format,
# mypy, tsc, git status/diff/log. Every other entry stays in allowedTools (still
# inert) and is printed as needing a manual decision.
#
# Usage:
#   bash scripts/migrate-settings-permissions.sh [--check] [settings.json ...]
#
# Default file: .claude/settings.json in the current directory.
#   --check   report only; exit 1 if a file still has convertible narrow
#             entries, 0 otherwise (left-over broad entries are listed, exit 0).
#
# Behaviour:
#   - each activated entry is printed ("activated: …"), each left-over entry too
#     ("left inert: … needs a manual decision")
#   - activated entries are unioned into allow (existing order first,
#     de-duplicated); allowedTools is deleted only once it is empty
#   - every other key keeps its value and order; a file with nothing convertible
#     is never rewritten (idempotent)
#   - a non-list `allow` is an error (exit 2), never replaced
#   - a missing file is a no-op (settings.local.json is optional)
#   - unparseable JSON: exit 2, file untouched
#   - the write is atomic (temp file + rename) and goes through a symlink to its
#     target, so a symlinked settings file stays a symlink

CHECK=0
FILES=()
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    -h|--help)
      sed -n '4,36p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) printf 'Unknown flag: %s\n' "$arg" >&2; exit 2 ;;
    *) FILES+=("$arg") ;;
  esac
done
[ "${#FILES[@]}" -gt 0 ] || FILES=(".claude/settings.json")

command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 is required to migrate settings JSON." >&2
  exit 2
}

# The narrow allow-list lives once, beside the hook library. No list, no
# migration: guessing would mean activating rules without a decision.
NARROW_LIST="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/hooks/lib/narrow-permissions.txt"
[ -f "$NARROW_LIST" ] || NARROW_LIST="${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/narrow-permissions.txt"
[ -f "$NARROW_LIST" ] || {
  echo "ERROR: hooks/lib/narrow-permissions.txt not found; nothing migrated." >&2
  exit 2
}

status=0
for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then
    printf 'skip: %s (absent)\n' "$f"
    continue
  fi
  set +e
  python3 - "$f" "$CHECK" "$NARROW_LIST" <<'PY'
import json, os, re, sys, tempfile

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

path, check = sys.argv[1], sys.argv[2] == "1"
PREFIXES = load_narrow(sys.argv[3])
try:
    with open(path, "r", encoding="utf-8") as fh:
        doc = json.load(fh)
except (ValueError, OSError) as exc:
    sys.stderr.write("ERROR: %s is not parseable JSON (%s); left untouched.\n" % (path, exc))
    sys.exit(2)

perms = doc.get("permissions") if isinstance(doc, dict) else None
if not isinstance(perms, dict) or "allowedTools" not in perms:
    print("ok: %s (no permissions.allowedTools)" % path)
    sys.exit(0)

legacy = perms.get("allowedTools")
if not isinstance(legacy, list):
    legacy = [legacy] if legacy not in (None, "") else []
if "allow" in perms and not isinstance(perms["allow"], list):
    sys.stderr.write("ERROR: %s has a non-list permissions.allow; fix it by hand, nothing was changed.\n" % path)
    sys.exit(2)
allowed = {json.dumps(e, sort_keys=True) for e in perms.get("allow", [])}
# An entry already in allow is in effect anyway; it is neither activated nor left.
pending = [e for e in legacy if json.dumps(e, sort_keys=True) not in allowed]
narrow = [e for e in pending if is_narrow(e, PREFIXES)]
broad = [e for e in pending if e not in narrow]

for e in broad:
    print("left inert: %s: %s needs a manual decision (permissions.allowedTools is ignored; "
          "move it to permissions.allow yourself only if you want it in effect)" % (path, json.dumps(e)))

if check:
    if narrow:
        for e in narrow:
            print("convertible: %s: %s" % (path, json.dumps(e)))
        print("FAIL: %s has %d narrow permissions.allowedTools entr%s Claude Code ignores; "
              "run scripts/migrate-settings-permissions.sh to move them into permissions.allow"
              % (path, len(narrow), "y" if len(narrow) == 1 else "ies"))
        sys.exit(1)
    print("ok: %s (nothing convertible; %d inert entr%s need a manual decision)"
          % (path, len(broad), "y" if len(broad) == 1 else "ies"))
    sys.exit(0)

if not narrow and len(broad) == len(legacy):
    print("ok: %s (nothing to migrate automatically; %d inert entr%s left)"
          % (path, len(broad), "y" if len(broad) == 1 else "ies"))
    sys.exit(0)

allow = perms.get("allow", [])
merged, seen = [], set()
for entry in list(allow) + narrow:
    key = json.dumps(entry, sort_keys=True)
    if key in seen:
        continue
    seen.add(key)
    merged.append(entry)

# Rebuild permissions: allow takes allowedTools' position when it did not exist
# yet; allowedTools keeps the left-over broad entries, or goes when none remain.
new_perms = {}
for k, v in perms.items():
    if k == "allowedTools":
        if "allow" not in perms:
            new_perms["allow"] = merged
        if broad:
            new_perms["allowedTools"] = broad
        continue
    new_perms[k] = merged if k == "allow" else v
doc["permissions"] = new_perms

real = os.path.realpath(path)
d = os.path.dirname(real)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".mtk-settings-", suffix=".json")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        out.write(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
    os.chmod(tmp, os.stat(real).st_mode & 0o777)
    os.replace(tmp, real)
except BaseException:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
for e in narrow:
    print("activated: %s: %s" % (path, json.dumps(e)))
print("migrated: %s (%d entr%s activated in permissions.allow, %d left inert)"
      % (path, len(narrow), "y" if len(narrow) == 1 else "ies", len(broad)))
PY
  rc=$?
  set -e
  case "$rc" in
    0) ;;
    1) status=1 ;;
    *) exit "$rc" ;;
  esac
done
exit "$status"
