#!/usr/bin/env bash
set -euo pipefail

# validate-toolkit.sh guards, one injected fault each, in a sandbox copy whose
# manifest is first made complete (so the clean run passes):
#   - internal codenames (whole words, any case) in a shipped file fail
#   - outside a git work tree the disk -> manifest check fails loudly instead of
#     being skipped
#   - a manifest with no readable "source" lines fails with a message instead
#     of a silent pipefail abort
#   - an unbraced $CLAUDE_PLUGIN_ROOT/ inside a fenced bash block in a skill
#     fails; the same text as inline prose does not

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATOR="${MTK_TEST_VALIDATOR:-$REPO_ROOT/scripts/validate-toolkit.sh}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; }

D="$(mktemp -d -t mtk-validate-guards-XXXXXX)"
B="$(mktemp -d -t mtk-validate-guards-bak-XXXXXX)"   # backups live outside the sandbox tree
trap 'rm -rf "$D" "$B"' EXIT
( cd "$REPO_ROOT" && git ls-files -z --cached --others --exclude-standard | xargs -0 tar cf - ) | tar xf - -C "$D"
cp "$VALIDATOR" "$D/scripts/validate-toolkit.sh"
git -C "$D" init -q

# Register every file the manifest does not list yet (in-flight work), so the
# sandbox starts clean and each case fails for its own reason only.
( cd "$D" && git ls-files -z --others --exclude-standard ) | ( cd "$D" && python3 -c '
import json, sys
paths = [p for p in sys.stdin.read().split("\0") if p]
m = json.load(open(".claude/manifest.json"))
files = m["files"]
sources = {v.get("source") for v in files.values() if isinstance(v, dict)}
for p in paths:
    if p not in sources and p not in files and not p.startswith(("docs/specs/", "docs/plans/")):
        files[p] = {"source": p, "target": p, "action": "sync", "description": "Sandbox registration for the validator guard test."}
json.dump(m, open(".claude/manifest.json", "w"), indent=2)
' )

run() { ( cd "$D" && bash scripts/validate-toolkit.sh ) 2>&1; }
expect_fail() { # $1 label  $2 expected message fragment
  local out
  if out="$(run)"; then fail "$1: validator passed. Tail: $(awk '{l=$0} END{print l}' <<<"$out")"; fi
  case "$out" in *"$2"*) ok "$1" ;; *) fail "$1: failed for another reason: $(grep ERROR <<<"$out" | awk 'NR==1')" ;; esac
}

out="$(run)" || fail "clean sandbox must validate. Errors: $(grep ERROR <<<"$out" | awk 'NR<=3')"
ok "clean sandbox validates"

# --- internal codename, whole word, any case -----------------------------------
HOOK="$D/hooks/ci-status.sh"
cp "$HOOK" "$B/hook.orig"
NAME="$(printf 'Bea%s' con)"
printf '# example from the %s project\n' "$NAME" >> "$HOOK"
expect_fail "codename in a shipped file is flagged" "internal name"
cp "$B/hook.orig" "$HOOK"
printf '# %ss and %sing are ordinary words\n' "$(printf 'bea%s' con)" "$(printf 'bea%s' con)" >> "$HOOK"
out="$(run)" || fail "a longer word containing a codename must not be flagged: $(grep ERROR <<<"$out" | awk 'NR==1')"
ok "codename matched as a whole word only"
cp "$B/hook.orig" "$HOOK"

# --- unbraced $CLAUDE_PLUGIN_ROOT/ in a fenced bash block -----------------------
SKILL="$D/.claude/skills/fix/SKILL.md"
cp "$SKILL" "$B/skill.orig"
printf '\nRun it via `$CLAUDE_PLUGIN_ROOT/scripts/x.sh` when needed.\n' >> "$SKILL"
out="$(run)" || fail "inline prose mention must not be flagged: $(grep ERROR <<<"$out" | awk 'NR==1')"
ok "prose mention in backticks is allowed"
printf '\n```bash\nbash "$CLAUDE_PLUGIN_ROOT/scripts/x.sh"\n```\n' >> "$SKILL"
expect_fail "unbraced plugin root in a fenced bash block is flagged" "unbraced"
cp "$B/skill.orig" "$SKILL"

# --- manifest without readable source lines ------------------------------------
cp "$D/.claude/manifest.json" "$B/manifest.orig"
# One line of JSON: every "source" key is still there, but no line starts with it.
( cd "$D" && python3 -c 'import json; m=json.load(open(".claude/manifest.json")); json.dump(m, open(".claude/manifest.json","w"))' )
expect_fail "manifest with no source lines fails with a message" "lists no"
cp "$B/manifest.orig" "$D/.claude/manifest.json"

# --- outside a git work tree ----------------------------------------------------
rm -rf "$D/.git"
expect_fail "outside a git work tree the C0.2 check fails loudly" "not inside a git work tree"

printf '\nAll validate-toolkit guard checks passed.\n'
