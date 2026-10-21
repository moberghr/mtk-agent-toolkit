#!/usr/bin/env bash
set -euo pipefail

# PostToolUse hook (Edit|Write|Bash): the context guard. Reads the main thread's
# context size from the transcript tail and
#   - writes .mtk/sessions/<session>/telemetry.json (mode 0600) on every parse,
#     only where .mtk/ is git-ignored or outside git (hooks/lib/session_store.py);
#   - with an active workflow, nudges once per workflow step at MTK_CTX_SOFT
#     (default 200000) and at MTK_CTX_HARD (default 250000) to checkpoint and
#     /clear; without one, nudges once per 150k band from MTK_CTX_GENERIC
#     (default 300000) toward /clear or /mtk handoff.
# The nudge names the checkpoint CLI by absolute path (next to this hook, else
# under CLAUDE_PLUGIN_ROOT). Nudges go out as additionalContext, one line each. It never blocks, prints
# nothing else on stdout and always exits 0. MTK_CONTEXT_GUARD=0 disables it.
#
# Cost: at most one transcript parse (one python3) per session every
# MTK_CTX_GUARD_INTERVAL seconds (default 20). A throttled call is bash only:
# it reads the last-parse epoch from $TMPDIR and exits before python starts.

# Never fail the tool call: report unexpected exits on stderr, exit 0.
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null; exit 0; }
trap _mtk_hook_diag EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"
mtk_hook_seen context-guard.sh

[ "${MTK_CONTEXT_GUARD:-1}" = "0" ] && exit 0

INPUT=""
if [ ! -t 0 ]; then
  INPUT="$(mtk_read_payload_nopy 3 2>/dev/null || true)"
fi
[ -n "$INPUT" ] || exit 0

SID_RAW="$(mtk_extract_json_string "$INPUT" "session_id" 2>/dev/null || true)"
TRANSCRIPT="$(mtk_extract_json_string "$INPUT" "transcript_path" 2>/dev/null || true)"
[ -n "$SID_RAW" ] && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0

# Throttle (python-free): <TMPDIR>/mtk-context-guard-<uid>-<session> holds the
# epoch of the last parse. A symlink or non-file there disables the guard for
# the session rather than writing through it.
SID_KEY="${SID_RAW//[^A-Za-z0-9._-]/_}"
SID_KEY="${SID_KEY:0:64}"
case "$SID_KEY" in ''|.*) exit 0 ;; esac
STATE="${TMPDIR:-/tmp}"
STATE="${STATE%/}/mtk-context-guard-${UID:-0}-${SID_KEY}"
if [ -L "$STATE" ] || { [ -e "$STATE" ] && [ ! -f "$STATE" ]; }; then exit 0; fi

INTERVAL="${MTK_CTX_GUARD_INTERVAL:-20}"
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=20 ;; esac
[ "${#INTERVAL}" -le 9 ] || INTERVAL=20
NOW="$(date +%s 2>/dev/null || true)"
case "$NOW" in ''|*[!0-9]*) exit 0 ;; esac
LAST=""
if [ -f "$STATE" ]; then
  { IFS= read -r LAST < "$STATE"; } 2>/dev/null || true
fi
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
[ "${#LAST}" -le 12 ] || LAST=0
SINCE=$(( NOW - 10#$LAST ))
if [ "$SINCE" -ge 0 ] && [ "$SINCE" -lt $(( 10#$INTERVAL )) ]; then
  exit 0
fi
# Claim the parse slot before python starts, so concurrent tool calls throttle.
{ printf '%s\n' "$NOW" > "$STATE"; } 2>/dev/null || true

command -v python3 >/dev/null 2>&1 || exit 0
# The checkpoint CLI the nudge names: next to this hook (plugin or repo layout),
# else under CLAUDE_PLUGIN_ROOT. Absolute, so the nudge works from any repo.
CKPT_SH="$SCRIPT_DIR/../scripts/workflow-artifact.sh"
if [ -f "$CKPT_SH" ]; then
  CKPT_SH="$(cd "$(dirname "$CKPT_SH")" && pwd)/workflow-artifact.sh"
else
  CKPT_SH="${CLAUDE_PLUGIN_ROOT:-}/scripts/workflow-artifact.sh"
fi
ROOT="$(mtk_repo_root 2>/dev/null || pwd)"

# One interpreter: parse, telemetry, nudge decision. Prints the nudge text (one
# line) or nothing; expected bad input (unreadable transcript, malformed lines,
# no usage yet) is silent. ASCII-only source, no single quotes (bash string).
GUARD_PY='
import json, os, sys, tempfile
lib, root, sid, transcript, keys_path, ckpt_sh = sys.argv[1:7]
sys.dont_write_bytecode = True
sys.path.insert(0, lib)
import active_workflow
import session_store

TAIL = 512 * 1024
BAND = 150000


def env_int(name, default):
    try:
        v = int(os.environ.get(name, "") or default)
    except ValueError:
        return default
    return v if v > 0 else default


def positive_int(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, float):
        v = int(v)
    try:
        n = int(str(v).strip())
    except (TypeError, ValueError):
        return None
    return n if n > 0 else None


def read_context():
    """(context_tokens, model) of the newest main-thread assistant line with usage."""
    try:
        with open(transcript, "rb") as fh:
            size = os.fstat(fh.fileno()).st_size
            start = max(0, size - TAIL)
            fh.seek(start)
            lines = fh.read().decode("utf-8", "ignore").splitlines()
    except OSError:
        return None, None
    if start > 0 and lines:
        lines = lines[1:]  # the first line of a mid-file tail is partial
    for line in reversed(lines):
        if "\"usage\"" not in line or "\"assistant\"" not in line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if not isinstance(d, dict) or d.get("type") != "assistant" or d.get("isSidechain"):
            continue
        msg = d.get("message")
        usage = msg.get("usage") if isinstance(msg, dict) else None
        if not isinstance(usage, dict):
            continue
        total = 0
        for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"):
            v = usage.get(k)
            if isinstance(v, (int, float)) and not isinstance(v, bool) and v > 0:
                total += int(v)
        if total:
            model = msg.get("model")
            return total, (model if isinstance(model, str) and model else None)
    return None, None


def compact_window():
    w = positive_int(os.environ.get("CLAUDE_CODE_AUTO_COMPACT_WINDOW", ""))
    if w:
        return w
    for p in (os.path.join(root, ".claude", "settings.local.json"),
              os.path.join(root, ".claude", "settings.json"),
              os.path.join(os.path.expanduser("~"), ".claude", "settings.json")):
        try:
            with open(p, encoding="utf-8") as fh:
                cfg = json.load(fh)
        except (OSError, ValueError):
            continue
        if isinstance(cfg, dict) and "autoCompactWindow" in cfg:
            w = positive_int(cfg.get("autoCompactWindow"))
            if w:
                return w
    return None


def safe_token(v, fallback):
    s = str(v if v is not None else "")
    ok = s and all(c.isalnum() or c in "._-" for c in s) and s.isascii()
    return s if ok else fallback


def main():
    ctx, model = read_context()
    if not ctx:
        return
    window = compact_window()

    uuid = phase = batches = None
    sel = active_workflow.select(os.path.join(root, ".mtk", "workflows"), 7)
    if sel:
        path, doc = sel
        uuid = safe_token(doc.get("workflow_uuid"), os.path.basename(path)[:-len(".json")])
        phase = str(doc.get("phase_cursor") or "?")
        res = doc.get("results")
        b = res.get("batches_completed") if isinstance(res, dict) else None
        batches = str(b if b is not None else 0)

    if session_store.mtk_ignored(root):
        try:
            session_store.write_telemetry(root, sid, session_store.telemetry_record(sid, ctx, window, model, uuid))
        except OSError as exc:
            sys.stderr.write("[mtk-hook:context-guard.sh] telemetry write failed: %s\n" % exc)

    try:
        with open(keys_path, encoding="utf-8") as fh:
            keys = [line.strip() for line in fh if line.strip()]
    except OSError:
        keys = []
    k = ctx // 1000
    of_window = " (%d%% of the %dk auto-compact window)" % (round(100 * ctx / window), window // 1000) if window else ""
    cmd = "`bash \"%s\" checkpoint %s --next \"<the next concrete step>\"`" % (ckpt_sh, uuid)
    resume = "then tell the engineer to /clear \u2014 the next session is offered the checkpoint and resumes from it."
    text = None
    if uuid:
        hard, soft = env_int("MTK_CTX_HARD", 250000), env_int("MTK_CTX_SOFT", 200000)
        level = "hard" if ctx >= hard else ("soft" if ctx >= soft else None)
        key = "step:%s|%s|%s|%s" % (uuid, phase, batches, level)
        if level and key not in keys:
            keys.append(key)
            if level == "hard":
                text = ("[mtk context-guard] Context is ~%dk tokens%s with workflow %s active. Do not start new work: "
                        "checkpoint now with %s, %s" % (k, of_window, uuid, cmd, resume))
            else:
                text = ("[mtk context-guard] Context is ~%dk tokens%s with workflow %s active (phase %s, %s batch(es) done). "
                        "Finish the current transition, run %s, %s" % (k, of_window, uuid, phase, batches, cmd, resume))
    else:
        generic = env_int("MTK_CTX_GENERIC", 300000)
        if ctx >= generic:
            band = (ctx - generic) // BAND
            last = max([int(x[5:]) for x in keys if x.startswith("band:") and x[5:].isdigit()] or [-1])
            if band > last:
                keys = [x for x in keys if not x.startswith("band:")] + ["band:%d" % band]
                text = ("[mtk context-guard] Session context is ~%dk tokens%s; every turn re-reads all of it. "
                        "If the latest request starts new or unrelated work, tell the engineer in one line to run /clear first; "
                        "if it continues long multi-step work, suggest wrapping up with /mtk handoff and resuming in a fresh session. "
                        "Mention it once, then continue." % (k, of_window))
    if not text:
        return
    # Persist the dedupe keys first: a guard that cannot remember would nag on every parse.
    try:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(keys_path) or ".", prefix=".mtk-context-guard.", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write("\n".join(keys[-64:]) + "\n")
        os.replace(tmp, keys_path)
    except OSError as exc:
        sys.stderr.write("[mtk-hook:context-guard.sh] nudge state write failed, nudge skipped: %s\n" % exc)
        return
    sys.stdout.buffer.write(text.encode("utf-8"))


try:
    main()
except Exception as exc:
    sys.stderr.write("[mtk-hook:context-guard.sh] guard failed: %s: %s\n" % (type(exc).__name__, exc))
'

GUARD_RC=0
NUDGE="$(PYTHONDONTWRITEBYTECODE=1 python3 -c "$GUARD_PY" "$SCRIPT_DIR/lib" "$ROOT" "$SID_RAW" "$TRANSCRIPT" "$STATE.keys" "$CKPT_SH")" || GUARD_RC=$?
if [ "$GUARD_RC" -ne 0 ]; then
  echo "[mtk-hook:context-guard.sh] guard exited $GUARD_RC; no nudge" >&2
  exit 0
fi
[ -n "$NUDGE" ] || exit 0
mtk_emit_additional_context PostToolUse "$NUDGE"
exit 0
