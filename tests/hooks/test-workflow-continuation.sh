#!/usr/bin/env bash
set -euo pipefail

# workflow-continuation.sh (Stop hook): nudges once when the newest workflow is
# active with unfinished batches; silent on completed/absent workflows; honors
# the MTK_HOOKS_TIER2=0 opt-out; debounces repeats at the same progress count.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/workflow-continuation.sh"

# Isolate everything: fake repo root (so we don't read the real .mtk/workflows)
# and a fresh TMPDIR (so the debounce marker is clean).
FAKE_ROOT="$(mktemp -d)"
FAKE_TMP="$(mktemp -d)"
cleanup() { rm -rf "$FAKE_ROOT" "$FAKE_TMP"; }
trap cleanup EXIT
git -C "$FAKE_ROOT" init -q   # mtk_repo_root resolves via git; make it a repo
mkdir -p "$FAKE_ROOT/.mtk/workflows"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

write_wf() {
  # $1 filename  $2 status  $3 total  $4 completed  [$5 owner_session, default none]
  cat > "$FAKE_ROOT/.mtk/workflows/$1" <<EOF
{
  "workflow_uuid": "${1%.json}",
  "owner_session": "${5:-}",
  "status": "$2",
  "results": { "batches_total": $3, "batches_completed": $4 }
}
EOF
}

run() { set +e; echo '' | ( cd "$FAKE_ROOT" && TMPDIR="$FAKE_TMP" MTK_HOOKS_TIER2="${1:-1}" bash "$HOOK" ) 2>&1; set -e; }
# run_as <session_id> — a Stop payload from that session.
run_as() { set +e; printf '{"hook_event_name":"Stop","session_id":"%s"}' "$1" | ( cd "$FAKE_ROOT" && TMPDIR="$FAKE_TMP" bash "$HOOK" ) 2>&1; set -e; }

# --- Case 1: active + unfinished → nudge -----------------------------------
write_wf "wf-active.json" active 8 2
out="$(run)"
echo "$out" | grep -qi 'WORKFLOW IN PROGRESS' || fail "active+unfinished should nudge. Got: $out"
echo "$out" | grep -q 'wf-active' || fail "nudge should name the workflow uuid"
echo "$out" | grep -q 'abandon' || fail "nudge should mention the abandon affordance"
printf '  PASS  active workflow with unfinished batches nudges\n'

# --- Case 2: debounce — same progress, no repeat ---------------------------
out2="$(run)"
[ -z "$out2" ] || fail "second Stop at same progress should be silent (debounce). Got: $out2"
printf '  PASS  debounced — no repeat at same progress\n'

# --- Case 3: progress advanced → re-notify ---------------------------------
write_wf "wf-active.json" active 8 3
out3="$(run)"
echo "$out3" | grep -qi 'WORKFLOW IN PROGRESS' || fail "progress change should re-notify. Got: $out3"
printf '  PASS  re-notifies after a batch completes\n'

# --- Case 4: completed workflow → silent -----------------------------------
rm -f "$FAKE_ROOT/.mtk/workflows/"*.json
write_wf "wf-done.json" completed 8 8
out="$(run)"
[ -z "$out" ] || fail "completed workflow should be silent. Got: $out"
printf '  PASS  completed workflow is silent\n'

# --- Case 5: all batches done but still active → silent --------------------
rm -f "$FAKE_ROOT/.mtk/workflows/"*.json
write_wf "wf-full.json" active 8 8
out="$(run)"
[ -z "$out" ] || fail "active with all batches done should be silent. Got: $out"
printf '  PASS  active-but-fully-done is silent\n'

# --- Case 6: no workflows dir → silent -------------------------------------
rm -rf "$FAKE_ROOT/.mtk"
out="$(run)"
[ -z "$out" ] || fail "absent workflows should be silent. Got: $out"
printf '  PASS  absent workflows silent\n'

# --- Case 7: tier-2 opt-out → silent ---------------------------------------
mkdir -p "$FAKE_ROOT/.mtk/workflows"
write_wf "wf-active.json" active 8 1
out="$(run 0)"
[ -z "$out" ] || fail "MTK_HOOKS_TIER2=0 should silence the hook. Got: $out"
printf '  PASS  MTK_HOOKS_TIER2=0 opt-out honored\n'

# --- Case 8: another session's unfinished workflow → silent for this session ---
rm -f "$FAKE_ROOT/.mtk/workflows/"*.json
write_wf "wf-theirs.json" active 8 2 s-other
out="$(run_as s-mine)"
[ -z "$out" ] || fail "another session's workflow must not nudge this session. Got: $out"
printf '  PASS  another session\047s unfinished workflow stays silent\n'

# --- Case 9: this session's own workflow is found past a newer foreign one -----
write_wf "wf-mine.json" active 6 1 s-mine
touch -t 202001010000 "$FAKE_ROOT/.mtk/workflows/wf-mine.json"
out="$(run_as s-mine)"
case "$out" in *wf-mine*) : ;; *) fail "this session's own unfinished workflow must nudge. Got: $out" ;; esac
case "$out" in *wf-theirs*) fail "the nudge must not name another session's workflow. Got: $out" ;; esac
printf '  PASS  this session\047s own workflow nudges, a newer foreign one is skipped\n'

printf '\nAll workflow-continuation checks passed.\n'
