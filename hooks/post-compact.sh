#!/usr/bin/env bash
# Post-compaction context re-injection. Wired in hooks/hooks.json as a
# SessionStart hook with matcher "compact": it fires as the session resumes
# after compaction, and SessionStart's additionalContext reaches the model.
# It re-injects awareness of
# tech stack, in-progress work, and active artifacts that were in the
# pre-compaction conversation.
set -euo pipefail

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

# Clear the read-diet seen-store for this session: compaction destroyed the
# earlier reads' content, so "already read this session" is no longer true —
# a stale store would deny re-reads the model genuinely needs.
INPUT="$(mtk_read_payload 2 2>/dev/null || true)"
DIET_SESSION="$(mtk_extract_json_string "$INPUT" "session_id" 2>/dev/null || printf '')"
if [ -n "$DIET_SESSION" ]; then
  rm -f "${TMPDIR:-/tmp}/mtk-read-diet-$(printf '%s%s' "$(mtk_repo_root 2>/dev/null || pwd)" "$DIET_SESSION" | cksum | cut -d' ' -f1)" 2>/dev/null || true
fi

CONTEXT=""

# Every pointer is anchored, never cwd-relative: the hook's cwd can be any
# subdirectory. Specs and plans live under the artifact root (S1.16);
# tech-stack, tasks, handoffs and workflow state under the project root.
ROOT="$(mtk_repo_root 2>/dev/null || pwd)"
MTK_ARTIFACT_DIR="$(mtk_artifact_root "$PWD" 2>/dev/null || printf '%s' "$ROOT")"
# Print a path relative to the project root when it is under it.
show() { mtk_repo_relative_path "$1" "$ROOT" 2>/dev/null || printf '%s' "$1"; }

# Tech stack context
if [ -f "$ROOT/.claude/tech-stack" ]; then
  STACK=$(cat "$ROOT/.claude/tech-stack")
  CONTEXT="Active tech stack: ${STACK}."
  if [ -f "$ROOT/.claude/tech-stack-pm" ]; then
    PM=$(cat "$ROOT/.claude/tech-stack-pm")
    CONTEXT="${CONTEXT} Package manager: ${PM}."
  fi
fi

# In-progress spec (JSON sidecar — critical for drift detection). Anchored to
# the resolved artifact root so a subtree that owns its specs is re-injected
# after compaction instead of the repo root's unrelated ones.
if [ -d "$MTK_ARTIFACT_DIR/docs/specs" ]; then
  RECENT_SPEC=$(find "$MTK_ARTIFACT_DIR/docs/specs" -name '*.json' -mtime -1 2>/dev/null | awk 'NR==1' || true)
  if [ -n "${RECENT_SPEC:-}" ]; then
    CONTEXT="${CONTEXT} Active spec: $(show "$RECENT_SPEC") — read before resuming implementation or review."
  fi
fi

# In-progress plan
if [ -d "$MTK_ARTIFACT_DIR/docs/plans" ]; then
  RECENT_PLAN=$(find "$MTK_ARTIFACT_DIR/docs/plans" -name '*.md' -mtime -1 2>/dev/null | awk 'NR==1' || true)
  if [ -n "${RECENT_PLAN:-}" ]; then
    CONTEXT="${CONTEXT} Active plan: $(show "$RECENT_PLAN") — check tasks/todo.md for batch progress."
  fi
fi

# Incomplete tasks
if [ -f "$ROOT/tasks/todo.md" ] && grep -q '\[ \]' "$ROOT/tasks/todo.md" 2>/dev/null; then
  CONTEXT="${CONTEXT} Incomplete tasks in tasks/todo.md — check before starting new work."
fi

# Handoff artifact (session recovery)
if [ -d "$ROOT/docs/handoffs" ]; then
  RECENT_HANDOFF=$(find "$ROOT/docs/handoffs" -name '*.md' -mtime -1 2>/dev/null | awk 'NR==1' || true)
  if [ -n "${RECENT_HANDOFF:-}" ]; then
    CONTEXT="${CONTEXT} Recent handoff: $(show "$RECENT_HANDOFF") — read to resume previous session state."
  fi
fi

# Active workflow artifact (durable orchestration state — survives compaction).
# Surfaces workflow type, phase, and last event so the orchestrator resumes
# mid-flow without re-deriving state from chat history. At most ONE workflow:
# the newest whose status is `active` (never failed/complete/abandoned) and whose
# updated_at is within MTK_WORKFLOW_REINJECT_DAYS (default 7). A finished or
# week-old workflow re-injected here reads as live work and restarts itself.
# python3 parses the JSON and the ISO timestamps (S3.3 baseline); without it
# no workflow is re-injected rather than a possibly stale one.
WF_DIR="$ROOT/.mtk/workflows"
if [ -d "$WF_DIR" ] && command -v python3 >/dev/null 2>&1; then
  WF_LINE="$(python3 - "$WF_DIR" "${MTK_WORKFLOW_REINJECT_DAYS:-7}" <<'PY' 2>/dev/null || true
import datetime, glob, json, os, sys
wf_dir, days = sys.argv[1], float(sys.argv[2])
now = datetime.datetime.now(datetime.timezone.utc)
best = None
for path in glob.glob(os.path.join(wf_dir, "*.json")):
    try:
        with open(path) as fh:
            doc = json.load(fh)
    except Exception:
        continue
    if not isinstance(doc, dict):
        continue
    if str(doc.get("status", "")).lower() != "active":
        continue
    try:
        ts = datetime.datetime.strptime(str(doc.get("updated_at", "")), "%Y-%m-%dT%H:%M:%SZ")
        ts = ts.replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        continue
    if (now - ts).total_seconds() > days * 86400:
        continue
    if best is None or ts > best[0]:
        best = (ts, path, doc)
if best:
    _, path, doc = best
    print("\t".join([path, str(doc.get("workflow_type") or "?"), str(doc.get("phase_cursor") or "?")]))
PY
)"
  if [ -n "$WF_LINE" ]; then
    ACTIVE_WF="${WF_LINE%%	*}"
    WF_REST="${WF_LINE#*	}"
    WF_TYPE="${WF_REST%%	*}"
    WF_PHASE="${WF_REST#*	}"
    WF_BASENAME=$(basename "$ACTIVE_WF" .json)
    WF_EVENTS="$WF_DIR/${WF_BASENAME}.events.jsonl"
    LAST_EVENT=""
    if [ -f "$WF_EVENTS" ]; then
      LAST_EVENT=$(tail -n 1 "$WF_EVENTS" 2>/dev/null | grep -o '"event_type"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' || true)
    fi
    WF_MSG="Active workflow: ${WF_BASENAME} (type=${WF_TYPE}, phase=${WF_PHASE}"
    [ -n "${LAST_EVENT:-}" ] && WF_MSG="${WF_MSG}, last_event=${LAST_EVENT}"
    WF_MSG="${WF_MSG}) — read $(show "$ACTIVE_WF") before advancing; do not re-init."
    CONTEXT="${CONTEXT} ${WF_MSG}"
  fi
fi

# Anti-resurrection framing (Hermes context_compressor contract): recovered
# state is REFERENCE, not instruction. Without this, a task the user cancelled
# or superseded before compaction reads as live work and restarts itself —
# the summary outlives the decision that killed it.
if [ -n "$CONTEXT" ]; then
  FRAMING="These pointers are a HISTORICAL SNAPSHOT of pre-compaction state, for reference — not instructions to act on. The latest user message always wins over anything recovered here. If the user cancelled, paused, or superseded any of this work (stop / undo / roll back / never mind / a new direction), treat that item as closed — do not resume it. Before acting on any pointer, confirm it is still what the user wants now."
  mtk_emit_additional_context "SessionStart" "POST-COMPACTION RECOVERY (reference only): ${CONTEXT} ${FRAMING}"
fi
