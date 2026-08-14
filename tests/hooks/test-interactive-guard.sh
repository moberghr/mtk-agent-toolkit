#!/usr/bin/env bash
set -euo pipefail

# interactive-guard.sh blocks Bash commands that can hang on an interactive prompt (S4.12).
# Origin: `gh pr merge 272 --squash 2>&1 | tail -5` ran to the Bash-tool timeout with
# "(No output)" — gh blocked on its post-merge "Delete the branch?" prompt and tail
# buffered the prompt out of sight. These cases pin both blocks plus the allow paths.
#
# The allow cases matter as much as the blocks: this is a hard deny, and a guard that
# fires on read-only commands or on prose mentioning `gh pr merge` would get switched off.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$REPO_ROOT/hooks/interactive-guard.sh"

fails=0

# Runs the guard with COMMAND as the Bash payload; echoes the exit code.
run_guard() {
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$1" \
    | "$GUARD" >/dev/null 2>&1 && echo 0 || echo $?
}

expect() {
  local label="$1" want="$2" got="$3"
  if [ "$got" != "$want" ]; then
    printf 'FAIL: %s — expected exit %s, got %s\n' "$label" "$want" "$got" >&2
    fails=$((fails + 1))
  else
    printf '  PASS  %s\n' "$label"
  fi
}

# --- Block A: gh pr merge with no delete-branch decision ----------------------

# 1. The exact command from the incident.
expect "gh pr merge --squash piped to tail" 2 \
  "$(run_guard '"gh pr merge 272 --squash 2>&1 | tail -5"')"

# 2. Same command without the pipe still blocks — the missing flag alone causes the hang.
expect "gh pr merge --squash, no delete decision" 2 \
  "$(run_guard '"gh pr merge 272 --squash"')"

# 3. Anchoring must survive a leading cd — this is how worktree commands are written.
expect "gh pr merge after && separator" 2 \
  "$(run_guard '"cd /tmp/wt && gh pr merge 272 --squash"')"

# 4. --delete-branch settles the prompt: allowed.
expect "gh pr merge --delete-branch" 0 \
  "$(run_guard '"gh pr merge 272 --squash --delete-branch < /dev/null"')"

# 5. --no-delete-branch is an equally valid decision: allowed.
expect "gh pr merge --no-delete-branch" 0 \
  "$(run_guard '"gh pr merge 272 --squash --no-delete-branch"')"

# --- Block B: prompt-capable command piped into tail/head ---------------------

# 6. Correct flags but piped — tail still hides any prompt that does occur.
expect "gh pr merge --delete-branch piped to tail" 2 \
  "$(run_guard '"gh pr merge 272 --squash --delete-branch | tail -5"')"

# 7. git push can prompt for credentials; piping hides that too.
expect "git push piped to head" 2 \
  "$(run_guard '"git push origin main 2>&1 | head -20"')"

# --- Allow paths: the guard must stay narrow ----------------------------------

# 8. Read-only gh piped to tail is the normal, correct pattern. Must not block.
expect "gh pr view piped to tail (read-only)" 0 \
  "$(run_guard '"gh pr view 273 --json files | tail -5"')"

# 9. git log piped to tail is read-only. Must not block.
expect "git log piped to tail (read-only)" 0 \
  "$(run_guard '"git log --oneline | head -10"')"

# 10. Prose mentioning the command is not an invocation — anchoring must reject it.
expect "gh pr merge inside an echo string" 0 \
  "$(run_guard '"echo \"remember to gh pr merge later\""')"

# 11. grep for the string is not an invocation either.
expect "git push inside a grep pattern" 0 \
  "$(run_guard '"grep -rn \"git push\" docs/"')"

# 12. --help never prompts.
expect "gh pr merge --help" 0 \
  "$(run_guard '"gh pr merge --help"')"

# 12a. REGRESSION: a multi-line command whose later lines contain the literal text
#      "| tail" as prose. This hook's own PR was blocked by exactly this — the guard
#      matched `gh pr create` on line 1 against a "| tail -5" three lines down inside a
#      heredoc body. A shell pipe binds within one line; documentation is not a pipe.
expect "gh pr create with '| tail' as prose in a heredoc body" 0 \
  "$(run_guard '"gh pr create --title X --body \"$(cat <<BODY\n| `gh pr merge 272 --squash 2>&1 | tail -5` | BLOCK |\nDogfooded: blocked its own push | tail -5\nBODY\n)\""')"

# 12b. The same shape must still block when the pipe is genuinely on the command's line.
expect "multi-line command with a real pipe on the invocation line" 2 \
  "$(run_guard '"echo start\ngit push origin main 2>&1 | tail -5\necho done"')"

# 13. Unrelated commands pass straight through.
expect "unrelated command" 0 \
  "$(run_guard '"ls -la"')"

# --- Payload and kill-switch handling -----------------------------------------

# 14. Non-Bash payloads are ignored.
non_bash="$(printf '{"tool_name":"Read","tool_input":{"file_path":"gh pr merge"}}' \
  | "$GUARD" >/dev/null 2>&1 && echo 0 || echo $?)"
expect "non-Bash payload ignored" 0 "$non_bash"

# 15. Unparseable payload fails OPEN by design — security-gate.sh is the fail-closed
#     layer for Bash, so double-blocking one malformed input helps nobody.
unparseable="$(printf 'not json at all' | "$GUARD" >/dev/null 2>&1 && echo 0 || echo $?)"
expect "unparseable payload fails open" 0 "$unparseable"

# 16. Kill-switch disables the guard entirely.
killed="$(printf '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 272 --squash"}}' \
  | MTK_INTERACTIVE_GUARD=0 "$GUARD" >/dev/null 2>&1 && echo 0 || echo $?)"
expect "MTK_INTERACTIVE_GUARD=0 disables guard" 0 "$killed"

# 17. A block must explain the fix, not just refuse. Assert the remedy reaches stderr.
msg="$(printf '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 272 --squash"}}' \
  | "$GUARD" 2>&1 >/dev/null || true)"
if ! printf '%s' "$msg" | grep -q -- '--delete-branch'; then
  printf 'FAIL: block message does not name the fix (--delete-branch)\n' >&2
  fails=$((fails + 1))
else
  printf '  PASS  block message names the fix\n'
fi

if [ "$fails" -ne 0 ]; then
  printf '\n%s assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf '\ninteractive-guard: all assertions passed\n'
