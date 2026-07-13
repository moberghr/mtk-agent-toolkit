#!/usr/bin/env bash
set -euo pipefail

# PreToolUse gate for Read | Grep | Glob.
#
# Two behaviours:
#   1. SECRET-FILE BLOCK (exit 2): reading a secret-pattern file is denied so an
#      agent cannot pull credentials into context without a human in the loop.
#      The agent is told to STOP and ask; the engineer grants access out-of-band
#      (by setting MTK_READ_GUARD=advisory, or adding the path to the per-day
#      approval list themselves). The block message deliberately does NOT print a
#      self-approval command — handing the guarded agent its own bypass would
#      defeat the control.
#      Known limitation: classification is on the resolved path's basename, so a
#      Grep whose `glob`/`pattern` (not `path`) targets a secret is not caught
#      here — the deny-list in settings.json and the human reviewer remain the
#      backstop for that narrower vector.
#   2. NOISE-DIR ADVISORY (exit 0): reading generated/vendored directories
#      (bin, obj, node_modules, dist, .venv, ...) wastes context and grounds the
#      agent on machine output. Warn, but allow.
#
# Everything else passes silently. The hook never blocks a non-secret read.
#
# Env:
#   MTK_READ_GUARD=advisory  -> secret reads warn instead of block (rollout knob)
#   approval list            -> $TMPDIR/mtk-readguard-approved-<project>-<date>
#                               (one approved repo-relative-or-absolute path/line)

# Diagnostic + temp-file cleanup on exit (silent on success / intentional block).
_MTK_RG_TMP=""
_mtk_hook_diag() {
  local c=$?
  [ -n "$_MTK_RG_TMP" ] && rm -f "$_MTK_RG_TMP" 2>/dev/null || true
  [[ $c -ne 0 && $c -ne 2 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true
  return 0
}
trap _mtk_hook_diag EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/mtkignore.sh"

mtk_is_redundant_plugin_invocation "$0" && exit 0

INPUT=$(cat)

TOOL_NAME=$(mtk_extract_tool_name "$INPUT" 2>/dev/null || echo "")
# Only guard read-shaped tools. Anything else is none of our business.
case "$TOOL_NAME" in
  Read|Grep|Glob) ;;
  "") ;;  # tolerate missing tool_name (some harnesses omit it) and still inspect path
  *) exit 0 ;;
esac

FILE_PATH=$(mtk_extract_file_path "$INPUT" 2>/dev/null || echo "")
[ -z "$FILE_PATH" ] && exit 0

BASE="$(basename "$FILE_PATH")"

# --- Secret classification --------------------------------------------------
# Allowlisted suffixes are sample/scaffold files that never hold real secrets.
is_secret=0
case "$BASE" in
  *.example|*.template|*.sample|*.dist) is_secret=0 ;;
  .env|.env.*) is_secret=1 ;;
  *.pem|*.key|*.pfx|*.p12|*.kdbx|*.keystore|*.jks) is_secret=1 ;;
  id_rsa|id_rsa.*|id_dsa|id_dsa.*|id_ecdsa|id_ecdsa.*|id_ed25519|id_ed25519.*) is_secret=1 ;;
  secrets.*|*.secret|*.secrets) is_secret=1 ;;
  .npmrc|.netrc|.pgpass|credentials) is_secret=1 ;;
esac

if [ "$is_secret" = "1" ]; then
  # Global rollout downgrade.
  if [ "${MTK_READ_GUARD:-}" = "advisory" ]; then
    echo "READ-GUARD (advisory): '${FILE_PATH}' looks like a secret-bearing file. Reading it pulls credentials into context — confirm this is intended." >&2
    exit 0
  fi

  # Per-day approval list (engineer-granted, out-of-band). Keyed by repo + date,
  # so a human-granted approval persists for the current day, not forever.
  APPROVAL_FILE="${TMPDIR:-/tmp}/mtk-readguard-approved-$(mtk_repo_root | cksum | cut -d' ' -f1)-$(date +%Y%m%d)"
  if [ -f "$APPROVAL_FILE" ] && grep -qxF "$FILE_PATH" "$APPROVAL_FILE" 2>/dev/null; then
    exit 0
  fi

  # Do NOT print a copy-paste self-approval recipe here — the guarded agent
  # could run it itself and defeat the human-in-the-loop premise. The message
  # instructs the agent to STOP and ask; approval is granted by the HUMAN,
  # out-of-band, through a channel the agent does not drive.
  echo "READ-GUARD: blocked read of secret-bearing file '${FILE_PATH}'. Reading credentials into context requires explicit human approval — do NOT attempt to work around this. STOP and ask the engineer whether to proceed. The engineer (not you) grants access out-of-band: by setting MTK_READ_GUARD=advisory for the session, or by approving the path in the read-guard approval list themselves. Until the engineer responds, treat this file as unreadable and continue without its contents." >&2
  exit 2
fi

# --- Noise-directory advisory ----------------------------------------------
IGNORE_FILE="${TMPDIR:-/tmp}/mtk-readguard-ignore.$$"
_MTK_RG_TMP="$IGNORE_FILE"
mtk_load_ignore_patterns "$IGNORE_FILE" 2>/dev/null || { exit 0; }

# Normalise to a repo-relative path for matching.
REPO_ROOT="$(mtk_repo_root 2>/dev/null || pwd)"
REL_PATH="${FILE_PATH#"$REPO_ROOT"/}"

while IFS= read -r pat; do
  [ -z "$pat" ] && continue
  # Directory patterns end with '/'. Match anywhere in the path.
  case "$REL_PATH/" in
    "$pat"*|*/"$pat"*)
      echo "READ-GUARD (advisory): '${REL_PATH}' is under a generated/vendored path ('${pat}'). Reading it spends context on machine output — prefer source files." >&2
      exit 0
      ;;
  esac
done < "$IGNORE_FILE"

exit 0
