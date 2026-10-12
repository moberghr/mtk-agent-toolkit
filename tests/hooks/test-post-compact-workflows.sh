#!/usr/bin/env bash
set -euo pipefail

# post-compact.sh re-injects at most one workflow: the newest one that is still
# live (status not complete/completed/abandoned) and was updated within the last
# 7 days. Only status `active` counts (a failed run is not live). Re-injecting a finished or week-old workflow after compaction revives
# work nobody is doing. Every pointer resolves against the project root (specs
# and plans against the artifact root), never the hook's cwd.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/post-compact.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git -C "$WORK" init -q
mkdir -p "$WORK/.mtk/workflows" "$WORK/sub/deeper" "$WORK/docs/plans" "$WORK/tasks"

iso_ago() { python3 -c 'import sys,datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=float(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
wf() { # $1 uuid  $2 status  $3 hours-ago  $4 phase
  cat > "$WORK/.mtk/workflows/$1.json" <<EOF
{
  "workflow_uuid": "$1",
  "workflow_type": "BUILD",
  "updated_at": "$(iso_ago "$3")",
  "status": "$2",
  "phase_cursor": "$4"
}
EOF
}
wf wf-done      completed 1   phase-9
wf wf-abandoned abandoned 1   phase-2
wf wf-stale     active    240 phase-1
wf wf-older     active    48  phase-2
wf wf-newest    active    3   phase-3
wf wf-failed    failed    1   phase-4

printf '# plan\n' > "$WORK/docs/plans/2099-plan.md"
printf -- '- [ ] open item\n' > "$WORK/tasks/todo.md"

out="$(cd "$WORK/sub/deeper" && CLAUDE_PROJECT_DIR="$WORK" bash "$HOOK" </dev/null 2>/dev/null || true)"

case "$out" in *'wf-newest'*) : ;; *) fail "the newest live workflow must be re-injected. Got: $out" ;; esac
for gone in wf-done wf-abandoned wf-failed wf-stale wf-older; do
  case "$out" in *"$gone"*) fail "$gone must not be re-injected. Got: $out" ;; esac
done
case "$out" in *'phase=phase-3'*) : ;; *) fail "the re-injected workflow must carry its phase. Got: $out" ;; esac
printf '  PASS  only the newest live, recent workflow is re-injected\n'

case "$out" in *'2099-plan.md'*) : ;; *) fail "a plan at the project root must be found from a subdirectory. Got: $out" ;; esac
case "$out" in *'Incomplete tasks'*) : ;; *) fail "tasks/todo.md at the project root must be found from a subdirectory. Got: $out" ;; esac
printf '  PASS  pointers resolve against the project root, not the cwd\n'

# Nothing live and recent: no workflow line at all.
wf wf-newest completed 3 phase-3
wf wf-older  abandoned 48 phase-2
out="$(cd "$WORK" && CLAUDE_PROJECT_DIR="$WORK" bash "$HOOK" </dev/null 2>/dev/null || true)"
case "$out" in *'Active workflow'*) fail "no live recent workflow, yet one was re-injected. Got: $out" ;; esac
printf '  PASS  finished and stale workflows stay buried\n'

printf '\nAll post-compact workflow checks passed.\n'
