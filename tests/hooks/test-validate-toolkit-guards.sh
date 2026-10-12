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
#   - runtime diet: hooks.json registering UserPromptSubmit, or a tool matcher
#     covering Read/Grep/Glob/mcp__ (exact list, regex, server-scoped mcp__ or "*"), fails
#   - a hooks.json command that resolves to no file fails

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

# Register every file the manifest does not list yet, and drop entries whose
# file is gone (in-flight work either way), so the sandbox starts clean and each
# case fails for its own reason only.
( cd "$D" && git ls-files -z --others --exclude-standard ) | ( cd "$D" && python3 -c '
import json, os, sys
paths = [p for p in sys.stdin.read().split("\0") if p]
m = json.load(open(".claude/manifest.json"))
files = m["files"]
sources = {v.get("source") for v in files.values() if isinstance(v, dict)}
for p in paths:
    if p not in sources and p not in files and not p.startswith(("docs/specs/", "docs/plans/")):
        files[p] = {"source": p, "target": p, "action": "sync", "description": "Sandbox registration for the validator guard test."}
for k in list(files):
    v = files[k]
    src = v.get("source", "") if isinstance(v, dict) else ""
    if src and "://" not in src and not os.path.exists(src):
        del files[k]
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
HOOK="$D/scripts/refresh-derived.sh"
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

# --- runtime diet: no hook on prompts or on Read/Grep/Glob/MCP calls -----------
HJ="$D/hooks/hooks.json"
cp "$HJ" "$B/hooks.orig"
inject_hook() { # $1 event  $2 matcher ("" = none)  $3 command
  python3 - "$HJ" "$1" "$2" "$3" <<'PY'
import json, sys
path, ev, matcher, cmd = sys.argv[1:]
d = json.load(open(path))
block = {"hooks": [{"type": "command", "command": cmd, "timeout": 5}]}
if matcher:
    block["matcher"] = matcher
d.setdefault("hooks", {}).setdefault(ev, []).append(block)
json.dump(d, open(path, "w"), indent=2)
PY
}
KEPT='"${CLAUDE_PLUGIN_ROOT}/hooks/session-start"'
inject_hook UserPromptSubmit "" "$KEPT"
expect_fail "a UserPromptSubmit hook is rejected" "runtime diet"
cp "$B/hooks.orig" "$HJ"
inject_hook PreToolUse "Read" "$KEPT"
expect_fail "an exact Read matcher is rejected" "runtime diet"
cp "$B/hooks.orig" "$HJ"
inject_hook PostToolUse "Edit|Glob" "$KEPT"
expect_fail "a list matcher that includes Glob is rejected" "runtime diet"
cp "$B/hooks.orig" "$HJ"
inject_hook PostToolUseFailure "mcp__.*" "$KEPT"
expect_fail "an mcp__ regex matcher is rejected" "runtime diet"
cp "$B/hooks.orig" "$HJ"
inject_hook PreToolUse "mcp__github__.*" "$KEPT"
expect_fail "a server-scoped mcp__ matcher is rejected" "runtime diet"
cp "$B/hooks.orig" "$HJ"
inject_hook PostToolUse "Bash|mcp__memory__.*" "$KEPT"
expect_fail "an mcp__ alternative inside a Bash matcher is rejected" "runtime diet"
cp "$B/hooks.orig" "$HJ"
inject_hook PreToolUse "*" "$KEPT"
expect_fail "a wildcard tool matcher is rejected" "runtime diet"
cp "$B/hooks.orig" "$HJ"
inject_hook PreToolUse "Bash" "$KEPT"
out="$(run)" || fail "a Bash-only matcher must be allowed: $(grep ERROR <<<"$out" | awk 'NR==1')"
ok "a Bash-only matcher is allowed"
cp "$B/hooks.orig" "$HJ"

# --- dangling hook command -----------------------------------------------------
inject_hook Stop "" '"${CLAUDE_PLUGIN_ROOT}/hooks/no-such-hook.sh"'
expect_fail "a hooks.json command with no file behind it is rejected" "does not resolve to an executable"
cp "$B/hooks.orig" "$HJ"

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
