#!/usr/bin/env bash
set -euo pipefail

# PostCompact hook: archives the compaction summary under
# <project root>/.mtk/sessions/<session_id>/compact-<UTC stamp>.md so a later
# session can OFFER it (hooks/session-start, COMPACTION OFFER). PostCompact
# output never reaches the model, so this hook only writes a file: it prints
# nothing on stdout and always exits 0.
#
# Writes nothing when: MTK_COMPACT_ARCHIVE=0; the payload has no summary or is
# not JSON; or the project is a git repo where .mtk/ is NOT git-ignored (the
# summary is conversation text and must never become committable).
# Prunes .mtk/sessions/* directories older than 14 days (only under that dir).

# Never fail the compaction: report unexpected exits on stderr, exit 0.
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null; exit 0; }
trap _mtk_hook_diag EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"
mtk_hook_seen compact-archive.sh

[ "${MTK_COMPACT_ARCHIVE:-1}" = "0" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=""
if [ ! -t 0 ]; then
  INPUT="$(mtk_read_payload_nopy 4 2>/dev/null || true)"
fi
[ -n "$INPUT" ] || exit 0

ROOT="$(mtk_repo_root 2>/dev/null || pwd)"

# Archive guard: a git repo must ignore .mtk/; a non-repo is fine. The skip is
# a configuration gap, not a crash, so it leaves one diagnostic line (exit 0).
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if ! git -C "$ROOT" check-ignore -q .mtk/sessions/x >/dev/null 2>&1; then
    echo "[mtk-hook:compact-archive.sh] .mtk/ is not git-ignored; compaction archive skipped (add .mtk/ to .gitignore, or run mtk-doctor --fix)" >&2
    exit 0
  fi
fi

BRANCH="$(git -C "$ROOT" symbolic-ref --short -q HEAD 2>/dev/null || true)"
[ -n "$BRANCH" ] || BRANCH="-"

WORKFLOW="-"
WF_PATH="$(python3 "$SCRIPT_DIR/lib/active_workflow.py" "$ROOT/.mtk/workflows" 7 path 2>/dev/null || true)"
[ -n "$WF_PATH" ] && WORKFLOW="$(basename "$WF_PATH" .json)"

umask 077
printf '%s' "$INPUT" | python3 -c '
import datetime, json, os, re, sys
root, branch, workflow = sys.argv[1:4]
try:
    p = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
if not isinstance(p, dict):
    sys.exit(0)
if "compact_summary" not in p:
    sys.stderr.write("[mtk-hook:compact-archive.sh] PostCompact payload has no compact_summary; archive skipped\n")
    sys.exit(0)
summary = p.get("compact_summary")
if not isinstance(summary, str) or not summary.strip():
    sys.exit(0)
sid = re.sub(r"[^A-Za-z0-9._-]", "_", str(p.get("session_id") or ""))
if not sid or sid.startswith("."):
    sys.exit(0)
one = lambda v: re.sub(r"[\r\n]+", " ", str(v)).strip() or "-"
trigger = one(p.get("trigger") or "-")
now = datetime.datetime.now(datetime.timezone.utc)
d = os.path.join(root, ".mtk", "sessions", sid)
try:
    os.makedirs(d, mode=0o700, exist_ok=True)
    path = os.path.join(d, "compact-%s.md" % now.strftime("%Y%m%dT%H%M%SZ"))
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("---\nsession: %s\nbranch: %s\ntrigger: %s\ncreated: %s\nworkflow: %s\n---\n%s\n" % (
            sid, one(branch), trigger, now.strftime("%Y-%m-%dT%H:%M:%SZ"), one(workflow), summary))
except OSError as e:
    sys.stderr.write("[mtk-hook:compact-archive.sh] archive write failed: %s\n" % e)
' "$ROOT" "$BRANCH" "$WORKFLOW" >/dev/null || true

# Prune old session directories (never outside .mtk/sessions).
if [ -d "$ROOT/.mtk/sessions" ] && [ ! -L "$ROOT/.mtk/sessions" ]; then
  find "$ROOT/.mtk/sessions" -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} + >/dev/null 2>&1 || true
fi
exit 0
