#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# PreToolUse hook for Edit and Write tools.
# Detects scope creep by checking if the file being modified is listed in the
# active spec's change_manifest or test_manifest.
#
# Advisory only (exit 0) — prints a warning, never blocks.
# No-op when there is no active spec JSON sidecar.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

mtk_is_redundant_plugin_invocation "$0" && exit 0

INPUT=$(cat)

# Extract file_path from the tool input JSON
FILE_PATH=$(mtk_extract_file_path "$INPUT" 2>/dev/null || echo "")
[ -z "$FILE_PATH" ] && exit 0

# Make the path relative to the repo root for comparison
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
REL_PATH="${FILE_PATH#"$REPO_ROOT"/}"

# Out-of-repo and workflow-state writes can never be scope violations, so they
# must not trip the guard. A still-absolute REL_PATH means the prefix strip was
# a no-op — FILE_PATH is not under REPO_ROOT (a session scratchpad / temp review
# artifact, /tmp, an absolute path elsewhere). `.mtk/` is durable workflow state
# (batch prompt bundles, artifacts) written outside the change_manifest by
# design. Neither is repo source, so exempt both before manifest matching.
case "$REL_PATH" in
  /*|.mtk/*) exit 0 ;;
esac

# Deterministic skip pointer — checked before any mtime-based spec selection.
# Manifest-less workflows (batch-fix) scope by a findings list, not a file
# manifest, so they drop .mtk/scope-guard-skip while running and this guard
# no-ops. This is immune to the mtime race that anchoring to the "freshest"
# sidecar suffers when a concurrent feature spec is newer than the batch stub.
# Freshness-windowed (4h) so a pointer left by a crashed run ages out instead
# of disabling the guard forever; the owning workflow removes it on completion.
# Anchor .mtk/ the same way workflow state does ($CLAUDE_PROJECT_DIR -> git
# top-level -> cwd) so the pointer is found even from a worktree/sub-dir cwd,
# where the writing workflow anchors it identically.
MTK_STATE_ROOT="${CLAUDE_PROJECT_DIR:-$REPO_ROOT}"
if [ -n "$(find "${MTK_STATE_ROOT}/.mtk" -maxdepth 1 -name scope-guard-skip -mmin -240 2>/dev/null || true)" ]; then
  exit 0
fi

# Find the active spec JSON sidecar (most recently modified, within 7 days)
SPEC_JSON=""
if [ -d docs/specs ]; then
  SPEC_JSON=$(find docs/specs -name '*.json' -type f -mtime -7 2>/dev/null | while read -r f; do
    echo "$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null || echo 0) $f"
  done | sort -rn | head -1 | cut -d' ' -f2-)
fi

# No active spec — nothing to guard
[ -z "${SPEC_JSON:-}" ] || [ ! -f "$SPEC_JSON" ] && exit 0

# Manifest-less workflows (batch-fix) declare a skip marker: they scope by a
# findings list, not a file manifest, so enforcing one is a false positive.
if grep -Eq '"scope_guard"[[:space:]]*:[[:space:]]*"skip"|"workflow"[[:space:]]*:[[:space:]]*"batch-fix"' "$SPEC_JSON" 2>/dev/null; then
  exit 0
fi

# Use a session cache to avoid re-parsing the spec on every tool call.
# Cache key: spec file path + mtime.
CACHE_DIR="${TMPDIR:-/tmp}"
SPEC_MTIME=$(stat -c '%Y' "$SPEC_JSON" 2>/dev/null || stat -f '%m' "$SPEC_JSON" 2>/dev/null || echo "0")
CACHE_KEY=$(printf '%s-%s' "$SPEC_JSON" "$SPEC_MTIME" | cksum | cut -d' ' -f1)
CACHE_FILE="$CACHE_DIR/mtk-scope-cache-$CACHE_KEY"

if [ -f "$CACHE_FILE" ]; then
  ALLOWED_FILES=$(cat "$CACHE_FILE")
else
  # Extract all file paths from change_manifest and test_manifest.
  # Looks for "path": "..." patterns within those sections.
  ALLOWED_FILES=$(awk '
    /"(change_manifest|test_manifest)"/ { in_section=1 }
    in_section && /\]/ { in_section=0 }
    in_section {
      if (match($0, /"path"[[:space:]]*:[[:space:]]*"([^"]+)"/, a)) {
        print a[1]
      }
    }
  ' "$SPEC_JSON" 2>/dev/null || true)

  # If awk match with groups fails (older awk), fall back to grep
  if [ -z "$ALLOWED_FILES" ]; then
    ALLOWED_FILES=$(awk '/"(change_manifest|test_manifest)"/,/\]/' "$SPEC_JSON" \
      | grep -o '"path"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | sed 's/.*: *"//;s/"$//' 2>/dev/null || true)
  fi

  # Always allow spec/plan/task files themselves
  ALLOWED_FILES="$ALLOWED_FILES
docs/specs/
docs/plans/
tasks/
.claude/"

  # Cache for the session
  printf '%s\n' "$ALLOWED_FILES" > "$CACHE_FILE"
fi

# No manifest entries found — spec might be empty or malformed, don't warn
[ -z "$ALLOWED_FILES" ] && exit 0

# Check if the relative path matches any allowed path (prefix or exact match)
MATCHED=0
while IFS= read -r allowed; do
  [ -z "$allowed" ] && continue
  case "$REL_PATH" in
    "$allowed"*) MATCHED=1; break ;;
    *"$allowed"*) MATCHED=1; break ;;
  esac
  case "$allowed" in
    *"$REL_PATH"*) MATCHED=1; break ;;
  esac
done <<< "$ALLOWED_FILES"

if [ "$MATCHED" -eq 0 ]; then
  SPEC_NAME=$(basename "$SPEC_JSON" .json)
  mtk_record_scope_guard_warning
  # Enforcing mode (opt-in, borrow — kyzo allowlist guard, P0#1). Default is
  # advisory (tier-1, exit 0): emit a warning, never block. When
  # MTK_SCOPE_GUARD_ENFORCE is truthy (1/true/yes), a write to a file outside the
  # approved change_manifest/test_manifest is a HARD DENY (exit 2) with a single
  # named reason — deterministic scope enforcement instead of a persuadable nudge.
  # Off by default so existing installs and manifest-less flows are unaffected.
  case "${MTK_SCOPE_GUARD_ENFORCE:-0}" in
    1|true|TRUE|yes|YES|on|ON)
      echo "MTK_SCOPE_GUARD: DENY ${REL_PATH} — not in approved manifest (${SPEC_NAME}). Add it to the spec's change_manifest, or unset MTK_SCOPE_GUARD_ENFORCE to fall back to advisory mode." >&2
      exit 2
      ;;
  esac
  mtk_emit_additional_context "PreToolUse" "SCOPE GUARD: ${REL_PATH} is not in the approved spec (${SPEC_NAME}). If this change is necessary, update the spec's change_manifest first. Undeclared file modifications are the #1 source of spec drift."
fi

exit 0
