#!/usr/bin/env bash
set -euo pipefail

# validate-toolkit.sh rejects skill/agent frontmatter whose value is an unquoted
# flow sequence followed by more text (spec 2026-10-01-plugin-release-branch, SC5).
#
# WHY. `argument-hint: [--json] [--fix]` is invalid YAML — a value starting with
# `[` parses as a list, and the text after its `]` breaks the parse. Anthropic's
# directory validator blocked on exactly this in mtk-doctor and mtk-setup. The
# check must catch every such line (including in CRLF files) without flagging
# valid lists, nested lists, brackets inside quoted strings, fully quoted values
# or trailing comments/whitespace.
#
# HOW. One scratch copy of the repo's files (tracked + untracked-not-ignored, read
# from disk so the working-tree versions are used). Each must-flag case rewrites
# line 6 of mtk-doctor's SKILL.md (its argument-hint line) and runs the real
# validator, which exits on the frontmatter check (~2s). The must-pass values are
# written into the same frontmatter together and checked by ONE full validator run
# (~11s) — a per-case full run would cost over a minute, and the check scans every
# frontmatter line, so a false positive on any of them still fails that run and
# names the line.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; }

D="$(mktemp -d -t mtk-frontmatter-yaml-XXXXXX)"
trap 'rm -rf "$D"' EXIT

( cd "$REPO_ROOT" && git ls-files -z --cached --others --exclude-standard | xargs -0 tar cf - ) | tar xf - -C "$D"

SKILL=".claude/skills/mtk-doctor/SKILL.md"
ORIG="$D/skill.orig"
cp "$D/$SKILL" "$ORIG"
case "$(sed -n 6p "$ORIG")" in
  argument-hint:*) ;;
  *) fail "line 6 of $SKILL is no longer its argument-hint line — update this test" ;;
esac
MSG="invalid YAML frontmatter in $SKILL line 6"

# Replace line 6 of the pristine skill with $1 (verbatim, no sed escaping).
set_line6() {
  awk -v repl="$1" 'NR==6 {print repl; next} {print}' "$ORIG" > "$D/$SKILL"
}

run_validator() { ( cd "$D" && bash scripts/validate-toolkit.sh ) 2>&1; }

expect_flag() {
  local label="$1" msg="${2:-$MSG}" out
  if out="$(run_validator)"; then
    fail "$label: validator passed, expected it to flag line 6. Output tail: $(printf '%s\n' "$out" | awk '{l=$0} END{print l}')"
  fi
  case "$out" in
    *"$msg"*) ok "flags: $label" ;;
    *) fail "$label: validator failed for another reason. Output: $out" ;;
  esac
}

# --- must flag ---------------------------------------------------------------
for value in \
  'argument-hint: [--json] [--fix]' \
  'k: [a]x' \
  'k: [a][b]' \
  'a.b: [a] [b]' \
  "k: ['a]b'] tail"; do
  set_line6 "$value"
  expect_flag "$value"
done

# Agent frontmatter is scanned too (SC5: "skill or agent").
cp "$ORIG" "$D/$SKILL"
AGENT=".claude/agents/test-reviewer.md"
cp "$D/$AGENT" "$D/agent.orig"
awk 'NR==3 {print "argument-hint: [--a] [--b]"} {print}' "$D/agent.orig" > "$D/$AGENT"
expect_flag "agent file: argument-hint: [--a] [--b]" "invalid YAML frontmatter in $AGENT line 3"
cp "$D/agent.orig" "$D/$AGENT"

# CRLF: the whole file in CRLF, delimiters included, still checked.
set_line6 'argument-hint: [--json] [--fix]'
awk '{printf "%s\r\n", $0}' "$D/$SKILL" > "$D/skill.crlf"
cp "$D/skill.crlf" "$D/$SKILL"
grep -q $'\r$' "$D/$SKILL" || fail "CRLF fixture has no CR line endings"
expect_flag "CRLF file with an unquoted argument-hint"

# --- must pass (one full run) ------------------------------------------------
# Line 6 keeps the argument-hint key; the rest go in as extra frontmatter keys
# right after it. The last one carries trailing spaces on purpose.
awk -v sq="'" 'NR==6 {
    print "argument-hint: [Read, Grep]"
    print "x-nested: [[a, b], [c]]"
    print "x-dq-bracket: [\"a]b\"]"
    print "x-dq-escaped: [\"a\\\"]\"]"
    print "x-sq-whole: " sq "[a] [b]" sq
    print "x-dq-whole: \"[--a] [--b]\""
    print "x-sq-escaped: [" sq "it" sq sq "s]" sq ", b]"
    print "x-comment: [a] # comment"
    print "x.dotted: [a]   "
    next
  } {print}' "$ORIG" > "$D/$SKILL"
grep -q '^x\.dotted: \[a\]   $' "$D/$SKILL" || fail "pass fixture lost its trailing whitespace"
out="$(run_validator)" || fail "validator failed on valid frontmatter values. Output: $out"
case "$out" in
  *"invalid YAML frontmatter"*) fail "validator flagged a valid value. Output: $out" ;;
esac
case "$out" in
  *"Toolkit validation passed."*) ;;
  *) fail "validator did not report a pass. Output: $out" ;;
esac
ok "passes: flat list, nested list, quoted ] in a list, escaped \\\" in a quoted item, fully quoted values, '' escape, # comment, dotted key with trailing whitespace"

echo "All validate-frontmatter-yaml tests passed."
