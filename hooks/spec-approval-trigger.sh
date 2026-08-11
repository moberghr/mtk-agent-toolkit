#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# PostToolUse hook for Edit|Write tools.
# When a markdown spec under docs/specs/ transitions to "status: approved",
# queue a tier-2 suggestion for planning-and-task-breakdown to run on the
# next user prompt.
#
# "Transition" = approved in the new content but NOT in the prior (HEAD)
# version of the same file. This avoids re-firing on every subsequent edit
# of an already-approved spec.
#
# Advisory only (exit 0). No-op if the spec path doesn't match, the marker
# is absent, the file was already approved, or the tier-2 kill-switch is off.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/skill-queue.sh"

mtk_is_redundant_plugin_invocation "$0" && exit 0

mtk_queue_enabled || exit 0

INPUT="$(cat)"
FILE_PATH="$(mtk_extract_file_path "$INPUT" 2>/dev/null || echo "")"
[ -z "$FILE_PATH" ] && exit 0

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# Relative to the ARTIFACT root, not the repo root: a subtree that owns its own
# docs/specs yields e.g. `web/docs/specs/x.md` against the repo root, which the
# `docs/specs/*` match below would miss entirely. Resolving from the edited
# file's own path makes the match correct in both layouts (they are identical
# when no subtree owns artifacts).
#
# Spelling-robust too: a plain string strip no-ops when the payload spells the
# root differently than git does (case-insensitive FS, symlinked root), leaving
# REL_PATH absolute so the match misses and this trigger silently never fires.
ARTIFACT_ROOT="$(mtk_artifact_root "$FILE_PATH" 2>/dev/null || printf '%s' "$REPO_ROOT")"
REL_PATH="$(mtk_repo_relative_path "$FILE_PATH" "$ARTIFACT_ROOT" 2>/dev/null \
  || mtk_repo_relative_path "$FILE_PATH" "$REPO_ROOT" 2>/dev/null \
  || printf '%s' "$FILE_PATH")"

# Fire for approved SCOPE artifacts: specs and plans. tasks/todo.md is
# deliberately excluded — it is mutable progress state, not sealed scope, so a
# routine checkbox tick as a batch completes must not re-queue approval
# (see scripts/workflow-artifact.sh cmd_seal: the seal binds spec+plan only).
case "$REL_PATH" in
  docs/specs/*.md|docs/plans/*.md) ;;
  *) exit 0 ;;
esac

[ -f "$FILE_PATH" ] || exit 0

# --- Stale approval-seal detection (any sealed spec/plan) ---
# If an ACTIVE workflow sealed this file at approval and the bytes no longer
# match, the earlier approval is stale — re-queue the approval step. Advisory
# (exit 0). See scripts/workflow-artifact.sh seal/verify-seal.
WF_DIR="${REPO_ROOT}/.mtk/workflows"
if [ -d "$WF_DIR" ] && command -v python3 >/dev/null 2>&1; then
  sealed_uuids="$(python3 - "$WF_DIR" "$REL_PATH" <<'PY'
import json, sys, glob, os
wf_dir, rel = sys.argv[1], sys.argv[2]
for jf in glob.glob(os.path.join(wf_dir, "*.json")):
    try:
        with open(jf) as f: doc = json.load(f)
    except Exception:
        continue
    if doc.get("status") != "active":
        continue
    seal = doc.get("results", {}).get("approval_seal")
    if not seal:
        continue
    if any(e.get("path") == rel for e in seal.get("files", [])):
        print(doc.get("workflow_uuid", os.path.basename(jf)[:-5]))
PY
)"
  if [ -n "$sealed_uuids" ]; then
    for u in $sealed_uuids; do
      rc=0
      ( cd "$REPO_ROOT" && bash "${SCRIPT_DIR}/../scripts/workflow-artifact.sh" verify-seal "$u" ) >/dev/null 2>&1 || rc=$?
      # rc 1=stale (re-queue). 0=match, 2=uncheckable, 3=no-seal are all ignored —
      # only a real mismatch fires the advisory, never a crash or a missing seal.
      if [ "$rc" -eq 1 ]; then
        queue_skill "planning-and-task-breakdown" \
          "approval seal STALE — ${REL_PATH} edited after approval (workflow ${u}); re-approve at Phase 2.5 before continuing" \
          "spec-approval-seal-stale-${u}" \
          "stale=${REL_PATH}"
        exit 0
      fi
    done
  fi
fi

# The approved-transition trigger below is spec-only (plans have no status
# marker and are handled by the seal check above).
case "$REL_PATH" in
  docs/specs/*.md) ;;
  *) exit 0 ;;
esac

# Regex for the approved marker: matches bold list ("- **Status:** approved")
# or YAML frontmatter ("status: approved"). Case-insensitive on the value.
approved_in_content() {
  local file="$1"
  grep -qiE '^[[:space:]]*-[[:space:]]*\*\*[Ss]tatus:\*\*[[:space:]]*approved[[:space:]]*$' "$file" && return 0
  grep -qiE '^[[:space:]]*status:[[:space:]]*approved[[:space:]]*$' "$file" && return 0
  return 1
}

approved_in_content "$FILE_PATH" || exit 0

# Compare against the HEAD version to detect actual transition.
# If the file is brand-new (no HEAD version), treat as a transition.
prior_content=""
if git -C "$REPO_ROOT" cat-file -e "HEAD:$REL_PATH" 2>/dev/null; then
  prior_content="$(git -C "$REPO_ROOT" show "HEAD:$REL_PATH" 2>/dev/null || printf '')"
fi

if [ -n "$prior_content" ]; then
  # If HEAD already said approved, this is a no-op edit on an approved spec.
  if printf '%s\n' "$prior_content" | grep -qiE '^[[:space:]]*-[[:space:]]*\*\*[Ss]tatus:\*\*[[:space:]]*approved[[:space:]]*$' \
     || printf '%s\n' "$prior_content" | grep -qiE '^[[:space:]]*status:[[:space:]]*approved[[:space:]]*$'; then
    exit 0
  fi
fi

SLUG="$(basename "$REL_PATH" .md)"
REASON="spec ${REL_PATH} transitioned to status: approved"
EXCERPT="spec=${SLUG}"

# Dedup key: skill + source_hook means repeat approvals of different specs
# collapse to one line. That's acceptable for Phase 1 — the drain line names
# the spec in `reason`. If we need per-spec dedup later, encode slug in source_hook.
queue_skill "planning-and-task-breakdown" "$REASON" "spec-approval-trigger-${SLUG}" "$EXCERPT"

exit 0
