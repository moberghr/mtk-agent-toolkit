#!/usr/bin/env bash
set -euo pipefail

# workflow-artifact.sh `prune --older-than <days>` — workflow expiry.
#
# WHY. Nothing ever removed a workflow artifact, so .mtk/workflows/ grew one
# JSON + one event log per run forever. prune removes runs of ANY status that
# were not updated within N days. A finished run updated recently survives:
# implement runs prune before every init, and deleting a run that finished an
# hour ago destroyed the receipt the engineer was about to review. N >= 1;
# 0 needs --force. Pruned uuids go to stderr as well.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WFA="$REPO_ROOT/scripts/workflow-artifact.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; }

PROJ="$(mktemp -d -t mtk-prune-XXXXXX)"
trap 'rm -rf "$PROJ"' EXIT
( cd "$PROJ" && git init -q . )
export CLAUDE_PROJECT_DIR="$PROJ"
WF="$PROJ/.mtk/workflows"

new_wf() { ( cd "$PROJ" && bash "$WFA" init BUILD --goal "$1" ); }

ACTIVE_NEW="$(new_wf "active, recent")"
ACTIVE_OLD="$(new_wf "active, stale")"
DONE_NEW="$(new_wf "completed, recent")"
DONE_OLD="$(new_wf "completed, stale")"
ABANDONED_NEW="$(new_wf "abandoned, recent")"
ABANDONED_OLD="$(new_wf "abandoned, stale")"
[ -n "$ACTIVE_NEW" ] && [ -n "$DONE_OLD" ] && [ -n "$ABANDONED_OLD" ] || fail "init did not print uuids"

( cd "$PROJ" && bash "$WFA" set "$DONE_NEW" status=completed >/dev/null )
( cd "$PROJ" && bash "$WFA" set "$DONE_OLD" status=completed >/dev/null )
( cd "$PROJ" && bash "$WFA" abandon "$ABANDONED_NEW" --reason "test" >/dev/null )
( cd "$PROJ" && bash "$WFA" abandon "$ABANDONED_OLD" --reason "test" >/dev/null )
# Back-date the three stale runs by 40 days (after the status writes, which bump updated_at).
for u in "$ACTIVE_OLD" "$DONE_OLD" "$ABANDONED_OLD"; do
  python3 - "$WF/$u.json" <<'PY2'
import json, sys, datetime
p = sys.argv[1]
d = json.load(open(p))
d["updated_at"] = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=40)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(d, open(p, "w"), indent=2)
PY2
done
mkdir -p "$WF/$DONE_OLD" && : > "$WF/$DONE_OLD/context-pack.md"
: > "$WF/$DONE_OLD.artifact.md"

# A non-workflow file in the directory must survive.
mkdir -p "$WF/dashboard" && : > "$WF/dashboard/index.html"

STALE=("$ACTIVE_OLD" "$DONE_OLD" "$ABANDONED_OLD")
RECENT=("$ACTIVE_NEW" "$DONE_NEW" "$ABANDONED_NEW")

# 1. Argument validation: a whole number, at least 1 unless --force.
( cd "$PROJ" && bash "$WFA" prune >/dev/null 2>&1 ) && fail "prune without --older-than accepted"
( cd "$PROJ" && bash "$WFA" prune --older-than abc >/dev/null 2>&1 ) && fail "non-integer --older-than accepted"
( cd "$PROJ" && bash "$WFA" prune --older-than 0 >/dev/null 2>&1 ) && fail "--older-than 0 accepted without --force"
( cd "$PROJ" && bash "$WFA" prune --older-than 0 --force --dry-run >/dev/null 2>&1 ) || fail "--older-than 0 --force rejected"
ok "prune validates --older-than (>= 1, 0 only with --force)"

# 2. --dry-run names exactly the stale runs and deletes nothing.
out="$(cd "$PROJ" && bash "$WFA" prune --older-than 30 --dry-run 2>/dev/null)"
for u in "${STALE[@]}"; do grep -q "$u" <<<"$out" || fail "dry-run did not list $u: $out"; done
for u in "${RECENT[@]}"; do grep -q "$u" <<<"$out" && fail "dry-run listed recent $u: $out"; done
for u in "${STALE[@]}" "${RECENT[@]}"; do [ -f "$WF/$u.json" ] || fail "dry-run deleted $u"; done
ok "prune --dry-run lists only stale runs, deletes nothing"

# 3. Real run with stdout discarded: stale runs of every status go, recent ones
#    of every status stay, and each pruned uuid is on stderr.
err="$(cd "$PROJ" && bash "$WFA" prune --older-than 30 2>&1 >/dev/null)"
for u in "${STALE[@]}"; do
  [ -e "$WF/$u.json" ] && fail "$u.json not pruned"
  [ -e "$WF/$u.events.jsonl" ] && fail "$u.events.jsonl not pruned"
  grep -q "$u" <<<"$err" || fail "pruned uuid $u not reported on stderr: $err"
done
[ -e "$WF/$DONE_OLD.artifact.md" ] && fail "artifact.md not pruned"
[ -e "$WF/$DONE_OLD" ] && fail "per-uuid directory not pruned"
for u in "${RECENT[@]}"; do [ -f "$WF/$u.json" ] || fail "recent workflow $u was pruned"; done
[ -f "$WF/dashboard/index.html" ] || fail "non-workflow file was pruned"
ok "prune removes stale runs of any status, keeps recent finished runs"

# 4. Idempotent: a second run has nothing to do and still exits 0.
out="$(cd "$PROJ" && bash "$WFA" prune --older-than 30 2>/dev/null)"
grep -q "pruned 0" <<<"$out" || fail "second prune should report 0, got: $out"
ok "prune is idempotent"

# 5. No workflows directory at all is not an error.
EMPTY="$(mktemp -d -t mtk-prune-empty-XXXXXX)"
( cd "$EMPTY" && CLAUDE_PROJECT_DIR="$EMPTY" bash "$WFA" prune --older-than 30 >/dev/null ) \
  || { rm -rf "$EMPTY"; fail "prune on a repo with no workflows exited non-zero"; }
rm -rf "$EMPTY"
ok "prune with no workflows is a no-op"

echo "test-workflow-artifact-prune: all checks passed"
