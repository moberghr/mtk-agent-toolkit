#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# PreToolUse guard for Bash commands that can block on an interactive prompt (S4.12).
# Exit 0 = allow, exit 2 = block.
#
# The failure this exists to prevent: `gh pr merge 272 --squash 2>&1 | tail -5` ran to
# the full Bash-tool timeout and returned "(No output)". The merge had already SUCCEEDED
# — gh then blocked on its post-merge "Delete the branch?" prompt waiting on stdin, and
# `tail` buffers until EOF so the prompt text never surfaced. The stall reads as a tool
# denial, so debugging goes to hooks and permissions instead of the command.
#
# Two independent blocks, because either alone is enough to cause it:
#   A. a prompt-capable command missing the flag that suppresses the prompt
#   B. a prompt-capable command piped into tail/head, which hides the prompt
#
# Scope is deliberately narrow. This is a hard deny, and a guard that over-blocks trains
# people to disable every hook — so it fires only on commands that genuinely prompt, and
# never on read-only ones (`gh pr view … | tail` stays fine).
#
# Kill-switch: MTK_INTERACTIVE_GUARD=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

mtk_is_redundant_plugin_invocation "$0" && exit 0

[ "${MTK_INTERACTIVE_GUARD:-1}" = "0" ] && exit 0

# Bounded read: an unbounded `cat` here would let a stalled stdin wedge the tool call —
# the very failure mode this hook exists to prevent. On timeout the payload is empty,
# which this hook treats as fail-open (see below).
INPUT=$(mtk_read_payload)

TOOL_NAME=$(mtk_extract_tool_name "$INPUT" 2>/dev/null || echo "")
COMMAND=$(mtk_extract_command "$INPUT" 2>/dev/null || echo "")

# Not a Bash payload — ignore.
if [ -n "$TOOL_NAME" ] && [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

# Unparseable payload: fail OPEN, deliberately. security-gate.sh already fails closed on
# the same payload, so a second hard block here would only double the error the engineer
# sees for one malformed input. This guard prevents a hang, not a breach.
[ -n "$COMMAND" ] || exit 0

# Commands that can stop and ask a question. Anchored to command position — after a
# separator, not merely after a space — so `echo "run gh pr merge"` and
# `grep -r "git push" .` are not treated as invocations. Separator class [;&|(] covers
# `&&` and `||` too, since each contains one of those characters.
MTK_PROMPT_CAPABLE='(^|[;&|(])[[:space:]]*(gh[[:space:]]+(pr[[:space:]]+(merge|create)|release[[:space:]]+create)|git[[:space:]]+(push|rebase))([[:space:]]|$)'

printf '%s' "$COMMAND" | grep -qE "$MTK_PROMPT_CAPABLE" || exit 0

# Judge each LINE on its own, and only lines where the command actually appears at command
# position. A shell pipe binds within one line, so a `| tail` three lines down in a heredoc
# body is documentation, not a pipe on this command. Whole-payload matching got this wrong
# immediately: the PR that introduced this hook was itself blocked, because its `gh pr
# create --body "$(cat <<EOF ... )"` carried the literal text "| tail -5" in the prose.
# Over-blocking is the failure mode that gets a hard-deny hook switched off, so the fix
# belongs here rather than in a carve-out.
MTK_HIT_LINE=""
MTK_MERGE_LINE=""
while IFS= read -r _line; do
  printf '%s' "$_line" | grep -qE "$MTK_PROMPT_CAPABLE" || continue
  # `--help` never prompts, so a help invocation on this line disqualifies it.
  printf '%s' "$_line" | grep -qE '(^|[[:space:]])(--help|-h)([[:space:]]|$)' && continue
  [ -n "$MTK_HIT_LINE" ] || MTK_HIT_LINE="$_line"
  if [ -z "$MTK_MERGE_LINE" ] \
    && printf '%s' "$_line" | grep -qE '(^|[;&|(])[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
    MTK_MERGE_LINE="$_line"
  fi
done <<MTK_LINES
$COMMAND
MTK_LINES

# Every prompt-capable mention was prose, a help invocation, or otherwise not at command
# position on its own line.
[ -n "$MTK_HIT_LINE" ] || exit 0

# --- Block A: `gh pr merge` with no delete-branch decision --------------------
# --squash/--merge/--rebase pick the merge method but leave the branch question open, so
# gh prompts after the merge API call has already landed. Passing either flag settles it.
if [ -n "$MTK_MERGE_LINE" ]; then
  if ! printf '%s' "$MTK_MERGE_LINE" | grep -qE '(^|[[:space:]])--(no-)?delete-branch([[:space:]]|$)'; then
    cat >&2 <<'MTK_BLOCK_A'
BLOCKED (S4.12): `gh pr merge` without a delete-branch decision prompts after the merge
has already landed, then hangs until the Bash timeout with no visible output.

Add --delete-branch (or --no-delete-branch) and redirect stdin:

  gh pr merge <n> --squash --delete-branch < /dev/null

Note the merge itself may still succeed while the command appears to hang — check
`gh pr view <n> --json state` before retrying, so you do not act on a merge that landed.
MTK_BLOCK_A
    exit 2
  fi
fi

# --- Block B: prompt-capable command piped into tail/head ---------------------
# tail/head buffer until EOF, so the prompt that is blocking never reaches the transcript.
# The command looks like it produced nothing when it is actually waiting for an answer.
# Scoped to the offending line for the reason given above.
if printf '%s' "$MTK_HIT_LINE" | grep -qE '\|[[:space:]]*(tail|head)([[:space:]]|$)'; then
  cat >&2 <<'MTK_BLOCK_B'
BLOCKED (S4.12): piping a prompt-capable command through tail/head hides the prompt that
blocks it — tail buffers until EOF, so a waiting command reads as "(No output)".

Drop the pipe and let the command stream:

  gh pr merge <n> --squash --delete-branch < /dev/null

Pipe-to-tail is fine for read-only commands (`git log`, `gh pr view`), just not for ones
that can stop and ask a question.
MTK_BLOCK_B
  exit 2
fi

# Prompt-capable but correctly formed.
exit 0
