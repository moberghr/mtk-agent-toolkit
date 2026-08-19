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

INPUT="$(mtk_read_payload)"

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
  # Deliberately no toggle hint: access here is granted by the HUMAN,
  # out-of-band — teaching the agent the off-switch would defeat the gate.
  mtk_deny "READ-GUARD: blocked read of secret-bearing file '${FILE_PATH}'. Reading credentials into context requires explicit human approval — do NOT attempt to work around this. STOP and ask the engineer whether to proceed. The engineer (not you) grants access out-of-band: by setting MTK_READ_GUARD=advisory for the session, or by approving the path in the read-guard approval list themselves. Until the engineer responds, treat this file as unreadable and continue without its contents."
fi

# --- Re-read diet (opt-in) ---------------------------------------------------
# Field measurement (terse, 18k-call corpus): re-reads of unchanged files were
# 92% of tool-output token waste — the single largest sink found. Opt-in via
# MTK_READ_DIET=deny (block the re-read; content is already in context) or
# =advise (advisory only). Guards full Reads only — offset/limit/pages reads
# always pass. The seen-store is keyed by session id so a fresh session never
# inherits "already read" from a context it does not have, and post-compact.sh
# clears the store because compaction destroys the earlier read's content.
READ_DIET="${MTK_READ_DIET:-0}"
if [ "$TOOL_NAME" = "Read" ] && { [ "$READ_DIET" = "deny" ] || [ "$READ_DIET" = "advise" ]; } && [ -f "$FILE_PATH" ]; then
  case "$INPUT" in
    *'"offset"'*|*'"limit"'*|*'"pages"'*) : ;;
    *)
      DIET_SESSION="$(mtk_extract_json_string "$INPUT" "session_id" 2>/dev/null || printf '')"
      [ -n "$DIET_SESSION" ] || DIET_SESSION="$(date +%Y%m%d)"
      DIET_STORE="${TMPDIR:-/tmp}/mtk-read-diet-$(printf '%s%s' "$(mtk_repo_root 2>/dev/null || pwd)" "$DIET_SESSION" | cksum | cut -d' ' -f1)"
      PATH_KEY="$(printf '%s' "$FILE_PATH" | cksum | cut -d' ' -f1)"
      CONTENT_KEY="$(cksum < "$FILE_PATH" 2>/dev/null | tr ' \t' '--' || printf 'unreadable')"
      PREV=""
      if [ -f "$DIET_STORE" ]; then
        PREV="$(grep -m1 "^${PATH_KEY} " "$DIET_STORE" 2>/dev/null | cut -d' ' -f2 || true)"
      fi
      if [ -n "$PREV" ] && [ "$PREV" = "$CONTENT_KEY" ]; then
        if [ "$READ_DIET" = "deny" ]; then
          # Measured savings: the re-read is actually avoided, so the file's
          # size is real bytes kept out of context (round-5 attribution table).
          OBS_DIR="$(mtk_repo_root 2>/dev/null || pwd)/.claude/observability"
          if [ -d "$(mtk_repo_root 2>/dev/null || pwd)/.claude" ] && { [ -d "$OBS_DIR" ] || mkdir -p "$OBS_DIR" 2>/dev/null; }; then
            printf '{"ts":"%s","session":"%s","mode":"read-diet","in_chars":%d,"out_chars":300}\n' \
              "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${CLAUDE_CODE_SESSION_ID:-}" \
              "$(wc -c < "$FILE_PATH" | tr -d ' ')" >> "$OBS_DIR/compression.jsonl" 2>/dev/null || true
          fi
          mtk_deny "READ-DIET: '${FILE_PATH}' is byte-identical to what you already read this session — its content is in your context; cite that instead of re-reading. If you need only part of it, re-issue the Read with offset/limit (always allowed)." \
            "MTK_READ_DIET=advise (advisory) or =0 in .claude/settings.local.json env"
        else
          mtk_emit_additional_context "PreToolUse" "READ-DIET (advisory): '${FILE_PATH}' is unchanged since you last read it this session — the earlier content is still valid; prefer citing it over re-reading. (deny mode: MTK_READ_DIET=deny)"
          exit 0
        fi
      else
        {
          if [ -f "$DIET_STORE" ]; then
            grep -v "^${PATH_KEY} " "$DIET_STORE" 2>/dev/null || true
          fi
          printf '%s %s\n' "$PATH_KEY" "$CONTENT_KEY"
        } > "${DIET_STORE}.tmp.$$" 2>/dev/null && mv "${DIET_STORE}.tmp.$$" "$DIET_STORE" 2>/dev/null || true
      fi
      ;;
  esac
fi

# --- Noise-directory advisory ----------------------------------------------
IGNORE_FILE="${TMPDIR:-/tmp}/mtk-readguard-ignore.$$"
_MTK_RG_TMP="$IGNORE_FILE"
mtk_load_ignore_patterns "$IGNORE_FILE" 2>/dev/null || { exit 0; }

# Normalise to a repo-relative path for matching. Spelling-robust — a plain
# string strip no-ops when the payload spells the root differently than git
# does, leaving REL_PATH absolute so no ignore pattern ever matches.
REPO_ROOT="$(mtk_repo_root 2>/dev/null || pwd)"
REL_PATH="$(mtk_repo_relative_path "$FILE_PATH" "$REPO_ROOT" 2>/dev/null || printf '%s' "$FILE_PATH")"

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
