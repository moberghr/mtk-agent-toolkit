#!/usr/bin/env bash
set -euo pipefail

# rule-trigger.sh — Just-in-time delivery of .claude/rules/ content.
#
# WHY THIS EXISTS
#   .claude/rules/INDEX.md already tells the model "read the index, then pull the
#   full rule file when its axes match." That is an instruction, and an instruction
#   under context pressure is a suggestion. This hook binds the same metadata to
#   the moment it matters: when a tool call actually matches a rule's trigger, the
#   rule's *source document* is read from disk and delivered right then.
#
#   Two properties are deliberate:
#     1. The rule is read from `source` at delivery time — never a stale paste.
#     2. A blocking strength ALWAYS ships the rule text with the denial. A block
#        that withholds its reason measurably destroys task completion; a block
#        that explains itself does not. Same principle as hooks/scope-guard.sh.
#
# MODES
#   (default)  PreToolUse — read a hook payload on stdin, match, deliver.
#   --rearm    SessionStart(compact) — clear delivery state so rules summarised
#              away by compaction are delivered again next time they match.
#
# STRENGTHS (per-rule, from frontmatter)
#   inject        advisory context, never blocks                 (exit 0)
#   require-read  block once with the rule text, then allow      (exit 2, then 0)
#   block         block every time                               (exit 2)
#
# FAIL-OPEN CONTRACT
#   This runs on every matching tool call. Any malformed frontmatter, missing
#   index, unreadable source, or unexpected error must exit 0. A broken rule file
#   degrades delivery; it must never wedge the session.

_MTK_RT_RC=0
_mtk_rt_diag() {
  local c=$?
  # exit 2 is an intentional block; anything else non-zero is a bug — report and
  # do not let it propagate as a failed tool call.
  [[ $c -ne 0 && $c -ne 2 ]] && echo "[mtk-hook:$(basename "$0")] exit $c (failing open)" >&2 2>/dev/null
  return 0
}
trap _mtk_rt_diag EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

mtk_is_redundant_plugin_invocation "$0" && exit 0

REPO_ROOT="$(mtk_repo_root 2>/dev/null || pwd)"
INDEX_FILE="$REPO_ROOT/.claude/rules/triggers.index"
STATE_FILE="${TMPDIR:-/tmp}/mtk-rule-delivered-$(printf '%s' "$REPO_ROOT" | cksum | cut -d' ' -f1)"

# ─── --rearm: compaction resets delivery state ─────────────────────────────────
# A rule delivered before a compaction was summarised away with everything else.
# Clearing the ledger re-arms every require-read rule so it fires again on its
# next match, instead of being permanently "already delivered" for a context that
# no longer contains it.
if [ "${1:-}" = "--rearm" ]; then
  rm -f "$STATE_FILE" 2>/dev/null || true
  exit 0
fi

# ─── Fast path ─────────────────────────────────────────────────────────────────
# No index → nothing to match. Exit before reading stdin or parsing anything.
[ -f "$INDEX_FILE" ] || exit 0

INPUT="$(mtk_read_payload)"
[ -n "$INPUT" ] || exit 0

TOOL_NAME="$(mtk_extract_tool_name "$INPUT" 2>/dev/null || echo "")"
FILE_PATH="$(mtk_extract_file_path "$INPUT" 2>/dev/null || echo "")"
COMMAND="$(mtk_extract_command "$INPUT" 2>/dev/null || echo "")"

# The haystack a rule's `pattern` is matched against depends on the tool shape:
# a command string for Bash, the target path for file-editing tools.
case "$TOOL_NAME" in
  Bash) HAYSTACK="$COMMAND" ;;
  *)    HAYSTACK="$FILE_PATH" ;;
esac
[ -n "$HAYSTACK" ] || exit 0

# Spelling-robust repo-relative path. The exact string strip fails whenever the
# payload spells the root differently than `git rev-parse` does — a
# case-insensitive filesystem serves the same checkout as both /Users/x/Dev/repo
# and /Users/x/dev/repo. Without this, every path-scoped rule silently never
# matches: a fail-open so quiet it reads as "no rule applies" rather than "path
# matching is broken". The shared helper compares by device+inode, so it also
# covers symlinked roots that a lowercase retry would miss.
REL_PATH="$(mtk_repo_relative_path "$FILE_PATH" "$REPO_ROOT" 2>/dev/null || printf '%s' "$FILE_PATH")"

DELIVER_BODY=""
BLOCK=0

# index columns (tab-separated): name  tool  pattern  path  strength  source
while IFS=$'\t' read -r r_name r_tool r_pattern r_path r_strength r_source; do
  case "$r_name" in ''|'#'*) continue ;; esac
  [ -n "$r_source" ] || continue

  # tool gate — "*" matches any tool; otherwise ERE alternation (e.g. "Edit|Write")
  if [ "$r_tool" != "*" ]; then
    printf '%s' "$TOOL_NAME" | grep -qE "^(${r_tool})$" 2>/dev/null || continue
  fi

  # pattern gate
  if [ "$r_pattern" != "-" ] && [ -n "$r_pattern" ]; then
    printf '%s' "$HAYSTACK" | grep -qE "$r_pattern" 2>/dev/null || continue
  fi

  # optional path gate — ANDed with pattern, scopes content rules to a subtree
  if [ "$r_path" != "-" ] && [ -n "$r_path" ]; then
    printf '%s' "$REL_PATH" | grep -qE "$r_path" 2>/dev/null || continue
  fi

  # already delivered this session? (inject always re-delivers; it is cheap and
  # non-blocking. require-read is once-per-session until a compaction re-arm.)
  if [ "$r_strength" = "require-read" ] && [ -f "$STATE_FILE" ] &&
     grep -qxF "$r_name" "$STATE_FILE" 2>/dev/null; then
    continue
  fi

  SRC="$REPO_ROOT/$r_source"
  [ -f "$SRC" ] || continue
  BODY="$(cat "$SRC" 2>/dev/null || true)"
  [ -n "$BODY" ] || continue

  DELIVER_BODY="${DELIVER_BODY}
─── rule: ${r_name} (${r_source}) ───
${BODY}
"
  case "$r_strength" in
    block)        BLOCK=1 ;;
    require-read) BLOCK=1; printf '%s\n' "$r_name" >> "$STATE_FILE" 2>/dev/null || true ;;
  esac
done < "$INDEX_FILE"

[ -n "$DELIVER_BODY" ] || exit 0

if [ "$BLOCK" -eq 1 ]; then
  # Ship the rule WITH the denial. A reason-less block is the failure mode.
  printf 'MTK RULE GATE — this action matches a rule that must be honoured. The rule is below; re-issue the action in compliance with it.\n%s\n' "$DELIVER_BODY" >&2
  exit 2
fi

# Advisory injection: visible to the model, never blocks.
printf 'MTK rule (just-in-time, matched this action):\n%s\n' "$DELIVER_BODY" >&2
exit 0
