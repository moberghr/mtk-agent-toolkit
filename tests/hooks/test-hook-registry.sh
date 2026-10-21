#!/usr/bin/env bash
set -euo pipefail

# test-hook-registry.sh — hooks/lib/hook_registry.py, the one hooks.json handler
# parser behind validate-toolkit, mtk-doctor and test-hooks-wiring. Fixture
# hooks.json files cover each parsing rule; the real hooks/hooks.json must parse
# to the registered script set.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REG="$REPO_ROOT/hooks/lib/hook_registry.py"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available" >&2; exit 0; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

fails=0
expect() { # $1 label  $2 want  $3 got
  if [ "$3" != "$2" ]; then
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3" >&2
    fails=$((fails + 1))
  else
    printf '  PASS  %s\n' "$1"
  fi
}

T=$'\t'
cat > "$TMPD/fixture.json" <<'JSON'
{ "hooks": {
  "PreToolUse": [
    { "matcher": "Bash", "hooks": [
      { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/quoted.sh\"", "timeout": 5 },
      { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/prefixed.sh\" --flush --x 1", "timeout": 30 },
      { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/filtered.sh\"", "if": "Bash(git push*)", "timeout": 5 }
    ] }
  ],
  "Stop": [
    { "hooks": [
      { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/no-timeout.sh" },
      { "type": "command", "command": "sh ${CLAUDE_PLUGIN_ROOT}/hooks/recorder.sh", "timeout": 30, "async": true }
    ] }
  ],
  "SubagentStart": [
    { "hooks": [ { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/sub.sh\"", "timeout": 5 } ] }
  ],
  "PostCompact": [
    { "hooks": [ { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/pc.sh\"", "timeout": 5, "async": true } ] }
  ]
} }
JSON

out="$(python3 "$REG" "$TMPD/fixture.json")"
row() { awk -v s="$1" -F'\t' '$5 == s' <<<"$out"; }
expect "quoted \${CLAUDE_PLUGIN_ROOT} path → basename, per-call" \
  "per-call${T}PreToolUse${T}Bash${T}${T}quoted.sh${T}${T}5${T}false" "$(row quoted.sh)"
expect "bash prefix dropped, args joined" \
  "per-call${T}PreToolUse${T}Bash${T}${T}prefixed.sh${T}--flush --x 1${T}30${T}false" "$(row prefixed.sh)"
expect "if handler → rare, if field kept" \
  "rare${T}PreToolUse${T}Bash${T}Bash(git push*)${T}filtered.sh${T}${T}5${T}false" "$(row filtered.sh)"
expect "missing timeout and matcher → empty fields" \
  "per-call${T}Stop${T}${T}${T}no-timeout.sh${T}${T}${T}false" "$(row no-timeout.sh)"
expect "sh prefix dropped, async true" \
  "per-call${T}Stop${T}${T}${T}recorder.sh${T}${T}30${T}true" "$(row recorder.sh)"
expect "SubagentStart → rare" \
  "rare${T}SubagentStart${T}${T}${T}sub.sh${T}${T}5${T}false" "$(row sub.sh)"
expect "PostCompact → rare" \
  "rare${T}PostCompact${T}${T}${T}pc.sh${T}${T}5${T}true" "$(row pc.sh)"
expect "one line per handler" 7 "$(awk 'END { print NR }' <<<"$out")"

# Importable API: the same records as dicts.
py_scripts="$(python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from hook_registry import handlers
print(" ".join(h["script"] for h in handlers(sys.argv[2])))' "$REPO_ROOT/hooks/lib" "$TMPD/fixture.json")"
expect "handlers() yields the same scripts in order" \
  "quoted.sh prefixed.sh filtered.sh no-timeout.sh recorder.sh sub.sh pc.sh" "$py_scripts"
# exe keeps the registered directory (the validator resolves it), shell prefix dropped.
py_exe="$(python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); from hook_registry import handlers
print(" ".join(h["exe"] for h in handlers(sys.argv[2]))[:200])' "$REPO_ROOT/hooks/lib" "$TMPD/fixture.json")"
expect "handlers() exe is the registered path, unexpanded" \
  '${CLAUDE_PLUGIN_ROOT}/hooks/quoted.sh ${CLAUDE_PLUGIN_ROOT}/hooks/prefixed.sh' "${py_exe%% \$\{CLAUDE_PLUGIN_ROOT\}/hooks/filtered.sh*}"

# Unshell-splittable command: skipped with a stderr warning, the rest still listed.
cat > "$TMPD/badquote.json" <<'JSON'
{ "hooks": { "Stop": [ { "hooks": [
  { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/broken.sh", "timeout": 5 },
  { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/fine.sh", "timeout": 5 }
] } ] } }
JSON
rc=0; out="$(python3 "$REG" "$TMPD/badquote.json" 2>"$TMPD/err")" || rc=$?
expect "unsplittable command → exit 0, handler skipped" "0 fine.sh" "$rc $(awk -F'\t' '{ print $5 }' <<<"$out")"
case "$(cat "$TMPD/err")" in
  *"skipping Stop command"*) expect "unsplittable command → stderr warning" ok ok ;;
  *) expect "unsplittable command → stderr warning" ok "$(cat "$TMPD/err")" ;;
esac

# Malformed JSON, missing "hooks", missing file: exit 1, exactly one stderr line, no traceback.
printf '{ not json' > "$TMPD/malformed.json"
printf '{"other": {}}' > "$TMPD/nohooks.json"
for f in malformed.json nohooks.json missing.json; do
  rc=0; python3 "$REG" "$TMPD/$f" >"$TMPD/stdout" 2>"$TMPD/err" || rc=$?
  expect "$f → exit 1" 1 "$rc"
  expect "$f → one stderr line" 1 "$(awk 'END { print NR }' "$TMPD/err")"
  expect "$f → no traceback, no stdout" "0 0" "$(awk '/Traceback/ { n++ } END { print n + 0 }' "$TMPD/err") $(wc -c < "$TMPD/stdout" | tr -d ' ')"
done

# The real hooks.json.
real="$(python3 "$REG" "$REPO_ROOT/hooks/hooks.json" | awk -F'\t' '{ print $5 }' | sort -u | tr '\n' ' ')"
for s in session-start security-gate.sh scope-guard.sh config-guard.sh evidence-ledger.sh \
         spec-approval-trigger.sh format-on-edit.sh verify-completion workflow-continuation.sh \
         cost-tracker.sh subagent-context.sh compact-archive.sh context-guard.sh; do
  case " $real" in
    *" $s "*) ;;
    *) printf 'FAIL: real hooks.json: %s not in parsed set: %s\n' "$s" "$real" >&2; fails=$((fails + 1)) ;;
  esac
done
[ "$fails" -eq 0 ] && printf '  PASS  real hooks.json parses with the expected script set\n'
expect "real hooks.json: compact-archive.sh is rare, async PostCompact" \
  "rare${T}PostCompact${T}${T}${T}compact-archive.sh${T}${T}5${T}true" \
  "$(python3 "$REG" "$REPO_ROOT/hooks/hooks.json" | awk -F'\t' '$5 == "compact-archive.sh"')"
expect "real hooks.json: every handler has a timeout" 0 \
  "$(python3 "$REG" "$REPO_ROOT/hooks/hooks.json" | awk -F'\t' '$7 == "" { n++ } END { print n + 0 }')"

if [ "$fails" -gt 0 ]; then
  printf '%d failure(s)\n' "$fails" >&2
  exit 1
fi
printf 'test-hook-registry: all checks passed\n'
