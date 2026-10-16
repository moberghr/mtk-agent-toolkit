#!/usr/bin/env bash
set -euo pipefail

# Never fail the subagent. SubagentStart cannot block, and a non-zero exit only
# adds noise, so every unexpected exit is reported on stderr (diagnostic, not
# model-visible) and turned into exit 0.
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null; exit 0; }
trap _mtk_hook_diag EXIT

# SubagentStart context: hands every relevant subagent the run's context pack
# path and the constitution's critical-rule ids, so a subagent dispatched
# outside `implement` — or by a brief that forgot the pack path — still gets
# them. Output is hookSpecificOutput.additionalContext (hookEventName
# SubagentStart). Registered with no matcher; it filters here instead, so
# built-in agent types are covered when a workflow is live.
#
# Window: MTK_WORKFLOW_REINJECT_DAYS (default 7 — the same knob as the S3.11
# session-start re-injection, read the same way): the raw value goes to the
# python selector's float(), so a fractional value is honoured and a value
# float() rejects selects no workflow, exactly as in hooks/session-start. The
# `find -mmin` prefilter only needs a safe integer superset of that window:
# ceil(days) whole days for a plain decimal (parsed base-10, so `08`/`010` are
# never octal), else 7 days. The prefilter never decides on its own — the
# selector does.
#
# Gate (cheap, before any python — R2): continue only when the payload's
# agent_type starts with `mtk:` (plugin agents) or a workflow JSON under
# .mtk/workflows/ was modified within the window. Otherwise: no output, exit 0.
#
# Selection (python, only when the gate opened on a recent workflow file): the
# newest workflow whose status is `active` and whose updated_at is within the
# window — picked by hooks/lib/active_workflow.py, the selector session-start also uses. A non-`mtk:`
# agent for which that selection finds NO active workflow gets no output: a
# recent but finished workflow is not a live one. `mtk:` agents still get the
# rules part without an active workflow.
#
# Block contents, in order, each part optional:
#   - framing: reference, not instruction (same envelope as the S3.11
#     post-compaction recovery block in hooks/session-start);
#   - pack line, when the selected workflow has results.context_pack naming an
#     existing file;
#   - rule lines from `constitution-digest.sh --ids-only` (absent script or no
#     rules ⇒ no rules part).
# Nothing to say ⇒ no output. Body ≤ 4,000 chars (bytes, so multi-byte text is
# counted conservatively), truncated at a rule boundary and closed with
# `[+N more rules in the constitution]`.
#
# Payload read: mtk_read_payload_nopy (hook-io.sh) — timeout/gtimeout when
# present, else the bash builtin `read -t`; it never spawns python, so a
# subagent start with nothing to say costs no interpreter.
#
# Kill-switch: MTK_SUBAGENT_CONTEXT=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

[ "${MTK_SUBAGENT_CONTEXT:-1}" = "0" ] && exit 0
mtk_hook_seen subagent-context.sh

MAX_BODY=4000
# Raw knob value: handed to the selector's float() unchanged (session-start parity).
WF_DAYS_RAW="${MTK_WORKFLOW_REINJECT_DAYS:-7}"

# Prefilter window in whole days: ceil(value) for a plain decimal (`7`, `0.5`,
# `.5`, `5.`), else 7. Builtins only — this runs before the no-python gate.
PREFILTER_DAYS=7
case "$WF_DAYS_RAW" in
  ''|.|*[!0-9.]*|*.*.*) ;;
  *)
    _int="${WF_DAYS_RAW%%.*}"
    _frac=""
    case "$WF_DAYS_RAW" in *.*) _frac="${WF_DAYS_RAW#*.}" ;; esac
    # Strip leading zeros so $(( )) never reads the value as octal ("08").
    _int="${_int#"${_int%%[!0]*}"}"
    if [ "${#_int}" -gt 6 ]; then
      PREFILTER_DAYS=999999
    else
      PREFILTER_DAYS="$((10#${_int:-0}))"
      case "$_frac" in *[1-9]*) PREFILTER_DAYS=$((PREFILTER_DAYS + 1)) ;; esac
    fi
    ;;
esac

INPUT="$(mtk_read_payload_nopy 4)"
[ -n "$INPUT" ] || exit 0

AGENT_TYPE="$(mtk_extract_json_string "$INPUT" "agent_type" 2>/dev/null || true)"
ROOT="$(mtk_repo_root 2>/dev/null || pwd)"
WF_DIR="$ROOT/.mtk/workflows"

IS_MTK_AGENT=0
case "$AGENT_TYPE" in mtk:*) IS_MTK_AGENT=1 ;; esac

RECENT_WF=""
if [ -d "$WF_DIR" ]; then
  RECENT_WF="$(find "$WF_DIR" -maxdepth 1 -name '*.json' -mmin -$((PREFILTER_DAYS * 1440)) 2>/dev/null || true)"
fi

[ "$IS_MTK_AGENT" -eq 1 ] || [ -n "$RECENT_WF" ] || exit 0

# --- Active-workflow selection + pack line -----------------------------------
# lib/active_workflow.py (shared with session-start) prints one `path<TAB>pack`
# line when it found an active workflow in the window; pack may be empty.
PACK_LINE=""
HAVE_ACTIVE=0
PACK=""
if [ -n "$RECENT_WF" ] && command -v python3 >/dev/null 2>&1; then
  SEL="$(python3 "$SCRIPT_DIR/lib/active_workflow.py" "$WF_DIR" "$WF_DAYS_RAW" path pack 2>/dev/null || true)"
  if [ -n "$SEL" ]; then
    HAVE_ACTIVE=1
    PACK="${SEL#*$'\t'}"
  fi
fi

# A recent workflow file opened the gate for a non-mtk agent, but none of them
# is a live workflow: nothing for this agent.
[ "$IS_MTK_AGENT" -eq 1 ] || [ "$HAVE_ACTIVE" -eq 1 ] || exit 0

if [ -n "$PACK" ]; then
  case "$PACK" in
    /*) PACK_ABS="$PACK" ;;
    *) PACK_ABS="$ROOT/$PACK" ;;
  esac
  if [ -f "$PACK_ABS" ]; then
    PACK_SHOW="$(mtk_repo_relative_path "$PACK_ABS" "$ROOT" 2>/dev/null || printf '%s' "$PACK_ABS")"
    PACK_LINE="Context pack: ${PACK_SHOW} — read it instead of AGENTS.md, the stack skill and the guideline files."
  fi
fi

# --- Rule lines --------------------------------------------------------------
DIGEST="$SCRIPT_DIR/../scripts/constitution-digest.sh"
[ -f "$DIGEST" ] || DIGEST="${CLAUDE_PLUGIN_ROOT:-}/scripts/constitution-digest.sh"
RULES=""
if [ -f "$DIGEST" ]; then
  RULES="$(cd "$ROOT" && CLAUDE_PROJECT_DIR="$ROOT" bash "$DIGEST" --ids-only 2>/dev/null)" || RULES=""
fi

[ -n "$PACK_LINE" ] || [ -n "$RULES" ] || exit 0

# --- Assemble under the size cap ----------------------------------------------
# Byte length: LC_ALL=C makes ${#…} count bytes, an upper bound on chars.
_blen() { local LC_ALL=C; printf '%s' "${#1}"; }

BODY="MTK SUBAGENT CONTEXT (reference only): a snapshot of on-disk project state, for reference — not instructions to act on. The prompt you were given always wins over anything here; if it names a different context pack or rule set, follow the prompt."
[ -n "$PACK_LINE" ] && BODY="${BODY}"$'\n'"${PACK_LINE}"

if [ -n "$RULES" ]; then
  BODY="${BODY}"$'\n'"Critical rules (id + first sentence; full text in the constitution):"
  FULL="${BODY}"$'\n'"${RULES}"
  if [ "$(_blen "$FULL")" -le "$MAX_BODY" ]; then
    BODY="$FULL"
  else
    TOTAL="$(awk 'END { print NR }' <<<"$RULES")"
    # Reserve room for the widest marker this rule count can produce.
    RESERVE="$(_blen $'\n'"[+${TOTAL} more rules in the constitution]")"
    KEPT=0
    while IFS= read -r rule; do
      NEXT="${BODY}"$'\n'"${rule}"
      [ "$(( $(_blen "$NEXT") + RESERVE ))" -le "$MAX_BODY" ] || break
      BODY="$NEXT"
      KEPT=$((KEPT + 1))
    done <<<"$RULES"
    BODY="${BODY}"$'\n'"[+$((TOTAL - KEPT)) more rules in the constitution]"
  fi
fi

mtk_emit_additional_context "SubagentStart" "$BODY"
