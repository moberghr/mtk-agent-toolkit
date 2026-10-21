#!/usr/bin/env bash
set -euo pipefail

# workflow-artifact.sh `checkpoint` / `resume` / `init TASK` — the canonical
# checkpoint (R1 of docs/specs/2026-10-21-canonical-checkpoint.md, SC1–SC6).
#
# WHY. After /clear the next session must find ONE current checkpoint and resume
# from it: a note re-rendered from the workflow artifact, a snapshot ref that
# survives a deleted worktree, a validator that refuses a Resume step pointing at
# finished work, and a read-only resume block that reports drift.
#
# Every case runs in throwaway repos under one mktemp -d (lesson 2026-10-01: a
# ref-creating test never touches the real checkout), with an isolated git
# config and a stub `gh` on PATH whose answer each case picks via GH_STUB_MODE.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WFA="$REPO_ROOT/scripts/workflow-artifact.sh"
HANDOFF_STATE="$REPO_ROOT/scripts/handoff-state.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; }

TMP="$(mktemp -d -t mtk-checkpoint-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Isolated git: no user/system config leaks in (signing, hooks, default branch).
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
printf '[user]\n\tname = MTK Test\n\temail = test@example.invalid\n[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n' > "$GIT_CONFIG_GLOBAL"
: > "$TMP/gitconfig-empty"

# Stub gh: logs every call, answers per GH_STUB_MODE.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
case "${GH_STUB_MODE:-fail}" in
  open)   printf '%s\n' '{"number":7,"state":"OPEN","url":"https://example.invalid/pr/7","isDraft":false,"baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"StatusContext","context":"ci/x","state":"PENDING"}]}' ;;
  merged) printf '%s\n' '{"number":9,"state":"MERGED","url":"https://example.invalid/pr/9","isDraft":false,"baseRefName":"main","statusCheckRollup":[]}' ;;
  closed) printf '%s\n' '{"number":11,"state":"CLOSED","url":"https://example.invalid/pr/11","isDraft":false,"baseRefName":"main","statusCheckRollup":[]}' ;;
  badjson) printf '%s\n' 'this is not json' ;;
  hang)   exec sleep 30 ;;
  none)   echo 'no pull requests found for branch "x"' >&2; exit 1 ;;
  *)      echo 'gh stub: simulated failure' >&2; exit 4 ;;
esac
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_STUB_LOG="$TMP/gh-calls.log"
export GH_STUB_MODE=fail

new_repo() {
  local d
  d="$(mktemp -d "$TMP/repo-XXXXXX")"
  git -C "$d" init -q .
  printf '.mtk/\n*.log\n' > "$d/.gitignore"
  echo one > "$d/a.txt"
  git -C "$d" add -A
  git -C "$d" commit -q -m init
  printf '%s' "$d"
}
wfa()   { ( cd "$CLAUDE_PROJECT_DIR" && bash "$WFA" "$@" ); }
art()   { printf '%s/.mtk/workflows/%s.json' "$CLAUDE_PROJECT_DIR" "$1"; }
fhash() { git hash-object "$1"; }
# jget <uuid> <python expression over d> — prints the value.
jget()  { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$(art "$1")" "$2"; }
# mtkhash <repo> — one hash over every file under .mtk and docs/handoffs (read-only proof).
mtkhash() { ( cd "$1" && { find .mtk docs/handoffs -type f 2>/dev/null || true; } | LC_ALL=C sort | xargs shasum 2>/dev/null | shasum ); }
fm()    { awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{exit} f' "$1"; }

write_sidecar() {  # write_sidecar <spec.md path> <completed_batches JSON>
  mkdir -p "$(dirname "$1")"
  echo "# spec" > "$1"
  python3 - "${1%.md}.json" "$2" <<'PY'
import json, sys
json.dump({"plan": {"batches": [{"id": "B1", "title": "Core"}, {"id": "B2", "title": "Lifecycle"},
                                {"id": "B3", "title": "Skills"}]},
           "implement": {"completed_batches": json.loads(sys.argv[2])}}, open(sys.argv[1], "w"))
PY
}

# ---------------------------------------------------------------- SC1 -------
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"
U="$(wfa init BUILD --goal "ship the checkpoint")"
wfa trap add "$U" --title "Temp index only" --severity high >/dev/null
GH_STUB_MODE=open wfa checkpoint "$U" --next "start the core" --decision "d1" --decision "d1" \
  --needs-user "Merge now? | default: wait" --verify "bash t.sh => exit 0" \
  --wait-until 2026-10-22T08:00:00Z >/dev/null || fail "checkpoint exited non-zero"
NOTE="$R/docs/handoffs/$U.md"
[ -f "$NOTE" ] || fail "note not written at docs/handoffs/<uuid>.md"
FM="$(fm "$NOTE")"
for k in state branch worktree workflow sha pushed ahead behind next_command needs_user wait_until expires updated; do
  grep -q "^$k: " <<<"$FM" || fail "frontmatter key '$k' missing: $FM"
done
grep -qx 'state: open' <<<"$FM" || fail "state should be open"
grep -qx "workflow: $U" <<<"$FM" || fail "workflow key wrong"
grep -qx 'branch: main' <<<"$FM" || fail "branch key wrong"
grep -qx "sha: $(git -C "$R" rev-parse --short HEAD)" <<<"$FM" || fail "sha is not short HEAD"
grep -qx 'pushed: unknown' <<<"$FM" || fail "pushed should be unknown without an upstream"
grep -qx 'next_command: /mtk:implement' <<<"$FM" || fail "BUILD default next_command wrong"
grep -qxF 'needs_user: ["Merge now? | default: wait"]' <<<"$FM" || fail "needs_user flow list wrong"
grep -qx 'wait_until: 2026-10-22T08:00:00Z' <<<"$FM" || fail "wait_until wrong"
for s in "## Goal" "## Decisions" "## Next" "## Git" "## PRs and CI" "## Units" "## Last verify" "## Traps" "## Open questions"; do
  grep -qx "$s" "$NOTE" || fail "section '$s' missing"
done
grep -qF "Historical snapshot, not standing orders: the user's latest message wins" "$NOTE" || fail "standing-orders line missing"
grep -qF 'PR #7 OPEN' "$NOTE" || fail "PR line missing"
grep -qF '1 passed, 1 failed, 1 pending (failing: lint)' "$NOTE" || fail "check rollup missing"
grep -qF '[HIGH] Temp index only' "$NOTE" || fail "trap title missing"
grep -qF '`bash t.sh` => exit 0' "$NOTE" || fail "last verify missing"
grep -qF 'no plan sidecar' "$NOTE" || fail "units without spec should say no plan sidecar"
[ "$(jget "$U" 'd["results"]["decisions"]')" = "['d1']" ] || fail "decisions not de-duplicated"
[ "$(jget "$U" 'd["results"]["checkpoint_path"]')" = "docs/handoffs/$U.md" ] || fail "checkpoint_path not recorded"
[ "$(jget "$U" 'sorted(k for k in ["path","sha","branch","worktree","at","snapshot","pr"] if k in d["results"]["checkpoint"])')" \
  = "['at', 'branch', 'path', 'pr', 'sha', 'snapshot', 'worktree']" ] || fail "results.checkpoint incomplete"
python3 - "$R/.mtk/workflows/$U.events.jsonl" <<'PY' || fail "checkpoint_written event shape differs from cmd_event"
import json, sys
last = json.loads(open(sys.argv[1]).read().splitlines()[-1])
assert list(last) == ["ts", "workflow_uuid", "event", "data"], list(last)
assert last["event"] == "checkpoint_written" and isinstance(last["data"], dict), last
PY
listed="$(bash "$HANDOFF_STATE" list --dir "$R/docs/handoffs")"
grep -qF "	open	main	" <<<"$listed" || fail "handoff-state.sh cannot read the note: $listed"
ok "SC1 checkpoint renders frontmatter, script and model sections, records results.checkpoint and the event"

wfa checkpoint "$U" --next "second pass" --offline >/dev/null || fail "second checkpoint failed"
[ "$(find "$R/docs/handoffs" -name '*.md' | wc -l | tr -d ' ')" = "1" ] || fail "second checkpoint made another file"
grep -qx 'second pass' "$NOTE" || fail "second checkpoint did not rewrite ## Next"
grep -q 'start the core' "$NOTE" && fail "stale --next survived the rewrite"
grep -qF -- '- d1' "$NOTE" || fail "decisions lost on rewrite"
grep -qF 'not checked (--offline)' "$NOTE" || fail "--offline PR section wrong"
GH_STUB_MODE=fail wfa checkpoint "$U" >/dev/null || fail "checkpoint with failing gh exited non-zero"
grep -qF 'not checked (gh exited 4: gh stub: simulated failure)' "$NOTE" || fail "gh failure not reported"
wfa checkpoint "$U" --close --offline >/dev/null
grep -qx 'state: closed' <(fm "$NOTE") || fail "--close did not render closed"
wfa checkpoint "$U" --offline >/dev/null
grep -qx 'state: open' <(fm "$NOTE") || fail "active workflow without --close should render open"
rc=0; wfa checkpoint "$U" --bogus >/dev/null 2>&1 || rc=$?; [ "$rc" = 1 ] || fail "bad flag should exit 1 (got $rc)"
rc=0; wfa checkpoint "$U" --verify "no arrow" >/dev/null 2>&1 || rc=$?; [ "$rc" = 1 ] || fail "malformed --verify should exit 1 (got $rc)"
rc=0; wfa checkpoint wf-nope >/dev/null 2>&1 || rc=$?; [ "$rc" = 1 ] || fail "unknown uuid should exit 1 (got $rc)"
ok "SC1 a second checkpoint rewrites the same file; --close, gh failure, bad flags"

# ---------------------------------------------------------------- SC2 -------
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"
U="$(wfa init BUILD --goal "units")"
write_sidecar "$R/docs/specs/2026-02-02-units.md" '[]'
wfa set "$U" results.spec_path=docs/specs/2026-02-02-units.md results.batches_completed=1 >/dev/null
wfa checkpoint "$U" --next "start B2 (B12 is unrelated)" --offline --no-snapshot >/dev/null || fail "valid --next rejected"
NOTE="$R/docs/handoffs/2026-02-02-units.md"
[ -f "$NOTE" ] || fail "spec slug not used for the note path"
grep -qx '| B1 | Core | done |' "$NOTE" || fail "B1 should be done"
grep -qx '| B2 | Lifecycle | next |' "$NOTE" || fail "B2 should be next"
grep -qx '| B3 | Skills | pending |' "$NOTE" || fail "B3 should be pending"
n0="$(fhash "$NOTE")"; a0="$(fhash "$(art "$U")")"; e0="$(fhash "$R/.mtk/workflows/$U.events.jsonl")"
rc=0; err="$(wfa checkpoint "$U" --next "redo B1 then B2" --offline 2>&1 >/dev/null)" || rc=$?
[ "$rc" = 3 ] || fail "--next naming a done unit should exit 3 (got $rc)"
grep -q 'B1' <<<"$err" || fail "rejection does not name the unit: $err"
rc=0; wfa checkpoint "$U" --next-command "/mtk:implement B1" --offline >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] || fail "--next-command naming a done unit should exit 3 (got $rc)"
[ "$(fhash "$NOTE")" = "$n0" ] || fail "rejected checkpoint changed the note"
[ "$(fhash "$(art "$U")")" = "$a0" ] || fail "rejected checkpoint changed the artifact"
[ "$(fhash "$R/.mtk/workflows/$U.events.jsonl")" = "$e0" ] || fail "rejected checkpoint logged an event"
ok "SC2 validator exits 3 and writes nothing when --next/--next-command names a done unit"

# Out of plan order: completed_batches, when non-empty, alone decides (B2 done, B1 next).
write_sidecar "$R/docs/specs/2026-02-02-units.md" '[{"batch_id":"B2"}]'
rc=0; wfa checkpoint "$U" --next "B2 again" --offline --no-snapshot >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] || fail "out-of-order: --next naming done B2 should exit 3 (got $rc)"
wfa checkpoint "$U" --next "start B1" --offline --no-snapshot >/dev/null || fail "out-of-order: --next B1 should be accepted"
grep -qx '| B1 | Core | next |' "$NOTE" || fail "out-of-order: B1 should be next"
grep -qx '| B2 | Lifecycle | done |' "$NOTE" || fail "out-of-order: B2 should be done"
grep -qx '| B3 | Skills | pending |' "$NOTE" || fail "out-of-order: B3 should be pending"
# String ids are accepted too, and a carried (stale) next naming a now-done unit is caught.
write_sidecar "$R/docs/specs/2026-02-02-units.md" '["B1","B2"]'
rc=0; err="$(wfa checkpoint "$U" --offline --no-snapshot 2>&1 >/dev/null)" || rc=$?
[ "$rc" = 3 ] || fail "carried next naming done B1 should exit 3 (got $rc)"
grep -q 'carried' <<<"$err" || fail "carried rejection should say so: $err"
wfa checkpoint "$U" --next "start B3" --offline --no-snapshot >/dev/null || fail "string completed_batches: --next B3 rejected"
grep -qx '| B3 | Skills | next |' "$NOTE" || fail "string completed_batches: B3 should be next"
ok "SC2 completed_batches (objects or strings) decides done out of plan order; batches_completed only as fallback"

# ---------------------------------------------------------------- SC3 -------
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"
U="$(wfa init BUILD --goal "snap")"
REF="refs/mtk/checkpoints/$U"
echo edited >> "$R/a.txt"
echo fresh > "$R/new.txt"
echo noise > "$R/x.log"
dd if=/dev/zero of="$R/big.bin" bs=1024 count=2048 2>/dev/null
head0="$(git -C "$R" rev-parse HEAD)"; sym0="$(git -C "$R" symbolic-ref HEAD)"
st0="$(GIT_OPTIONAL_LOCKS=0 git -C "$R" status --porcelain)"; idx0="$(fhash "$R/.git/index")"
MTK_CHECKPOINT_MAX_FILE_MB=1 wfa checkpoint "$U" --next "snap it" --offline >/dev/null || fail "snapshot checkpoint failed"
[ "$(git -C "$R" rev-parse HEAD)" = "$head0" ] || fail "snapshot moved HEAD"
[ "$(git -C "$R" symbolic-ref HEAD)" = "$sym0" ] || fail "snapshot changed the branch"
[ "$(fhash "$R/.git/index")" = "$idx0" ] || fail "snapshot rewrote the real index"
[ "$(GIT_OPTIONAL_LOCKS=0 git -C "$R" status --porcelain)" = "$st0" ] || fail "git status changed"
[ "$(cat "$R/a.txt")" = "$(printf 'one\nedited')" ] || fail "snapshot changed the worktree"
[ "$(git -C "$R" show "$REF:a.txt")" = "$(printf 'one\nedited')" ] || fail "snapshot lacks the tracked edit"
[ "$(git -C "$R" show "$REF:new.txt")" = "fresh" ] || fail "snapshot lacks the untracked file"
git -C "$R" cat-file -e "$REF:x.log" 2>/dev/null && fail "snapshot holds an ignored file"
git -C "$R" cat-file -e "$REF:big.bin" 2>/dev/null && fail "snapshot holds an oversized untracked file"
[ "$(git -C "$R" rev-parse "$REF^")" = "$head0" ] || fail "snapshot parent is not HEAD"
grep -qF 'left out 1 untracked file(s) over 1 MB' "$R/docs/handoffs/$U.md" || fail "note does not count skipped files"
grep -qF "git restore --source=$REF" "$R/docs/handoffs/$U.md" || fail "restore hint missing"
msg="$(git -C "$R" log -1 --format=%B "$REF")"
grep -qx 'next_command: /mtk:implement' <<<"$msg" || fail "commit message lacks the frontmatter"
grep -qx '## Next' <<<"$msg" && grep -qx 'snap it' <<<"$msg" || fail "commit message lacks ## Next"
[ "$(git -C "$R" log -1 --format='%an <%ae>' "$REF")" = "MTK Test <test@example.invalid>" ] || fail "configured identity not used"
ok "SC3 snapshot holds tracked + untracked, skips ignored + oversized; HEAD, branch, index, status untouched"

c1="$(git -C "$R" rev-parse "$REF")"
sleep 2  # past a clock second: the `updated:` stamp must not make an unchanged checkpoint look new
MTK_CHECKPOINT_MAX_FILE_MB=1 wfa checkpoint "$U" --offline >/dev/null
[ "$(git -C "$R" rev-parse "$REF")" = "$c1" ] || fail "unchanged tree and message moved the ref"
[ "$(git -C "$R" rev-list --count "$REF")" = "2" ] || fail "unchanged checkpoint added a commit"
tree1="$(git -C "$R" rev-parse "$REF^{tree}")"
MTK_CHECKPOINT_MAX_FILE_MB=1 wfa checkpoint "$U" --next "refreshed next step" --offline >/dev/null
c2="$(git -C "$R" rev-parse "$REF")"
[ "$c2" != "$c1" ] || fail "same tree + changed --next did not move the ref (SF-F003)"
[ "$(git -C "$R" rev-parse "$REF^{tree}")" = "$tree1" ] || fail "refreshed snapshot changed the tree"
[ "$(git -C "$R" rev-parse "$REF^")" = "$head0" ] || fail "refreshed snapshot parent is not HEAD"
grep -qx 'refreshed next step' <<<"$(git -C "$R" log -1 --format=%B "$REF")" || fail "refreshed message lacks the new ## Next"
grep -qF 'message refreshed, tree unchanged' "$R/docs/handoffs/$U.md" || fail "note does not say the message was refreshed"
c1="$c2"
echo again >> "$R/a.txt"
wfa checkpoint "$U" --offline --no-snapshot >/dev/null
[ "$(git -C "$R" rev-parse "$REF")" = "$c1" ] || fail "--no-snapshot moved the ref"
MTK_CHECKPOINT_SNAPSHOT=0 wfa checkpoint "$U" --offline >/dev/null
[ "$(git -C "$R" rev-parse "$REF")" = "$c1" ] || fail "MTK_CHECKPOINT_SNAPSHOT=0 moved the ref"
GIT_CONFIG_GLOBAL="$TMP/gitconfig-empty" MTK_CHECKPOINT_MAX_FILE_MB=1 wfa checkpoint "$U" --offline >/dev/null
[ "$(git -C "$R" rev-parse "$REF")" != "$c1" ] || fail "changed tree did not move the ref"
[ "$(git -C "$R" rev-parse "$REF^")" = "$head0" ] || fail "moved snapshot parent is not HEAD"
[ "$(git -C "$R" log -1 --format='%an <%ae>' "$REF")" = "MTK checkpoint <mtk@localhost>" ] || fail "identity fallback not used"
ok "SC3 unchanged tree keeps the ref; off switches; identity fallback when user.name/email unset"

R2="$(mktemp -d "$TMP/unborn-XXXXXX")"; git -C "$R2" init -q .; echo x > "$R2/f.txt"
U2="$(CLAUDE_PROJECT_DIR="$R2" bash "$WFA" init TASK)"
( export CLAUDE_PROJECT_DIR="$R2"; wfa checkpoint "$U2" --offline >/dev/null ) || fail "checkpoint on an unborn branch failed"
[ "$(git -C "$R2" rev-list --parents -n 1 "refs/mtk/checkpoints/$U2" | wc -w | tr -d ' ')" = "1" ] || fail "unborn snapshot should have no parent"
git -C "$R2" rev-parse -q --verify HEAD >/dev/null && fail "snapshot created HEAD on an unborn branch"
ok "SC3 unborn branch: snapshot from the empty tree, no parent, HEAD still unborn"

python3 - "$(art "$U")" <<'PY'
import json, sys, datetime
p = sys.argv[1]; d = json.load(open(p))
d["updated_at"] = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=40)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(d, open(p, "w"), indent=2)
PY
wfa prune --older-than 1 --dry-run >/dev/null 2>&1
git -C "$R" rev-parse -q --verify "$REF" >/dev/null || fail "prune --dry-run deleted the ref"
out="$(wfa prune --older-than 1 2>/dev/null)"
grep -q "^pruned $U (" <<<"$out" || fail "prune output changed: $out"
git -C "$R" rev-parse -q --verify "$REF" >/dev/null && fail "prune left the checkpoint ref"
ok "SC3 prune deletes the pruned workflow's ref (dry-run keeps it)"

# ---------------------------------------------------------------- SC4 -------
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"
U="$(wfa init BUILD --goal "ignore")"
[ ! -e "$R/docs/handoffs" ] || fail "fixture: docs/handoffs should not exist yet"
wfa checkpoint "$U" --offline --no-snapshot >/dev/null
[ "$(cat "$R/docs/handoffs/.gitignore")" = "*" ] || fail "self-ignoring .gitignore not written"
st="$(git -C "$R" status --porcelain --untracked-files=all)"
grep -q 'docs/handoffs' <<<"$st" && fail "git status shows docs/handoffs: $st"
ok "SC4 first write creates docs/handoffs/.gitignore '*'; git status shows nothing there"

# TR-F004: a note that is already ignored warns about nothing; a foreign .gitignore keeps its bytes.
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"
U="$(wfa init TASK --goal "quiet")"
wfa checkpoint "$U" --offline --no-snapshot >/dev/null 2>&1
err="$(wfa checkpoint "$U" --offline --no-snapshot 2>&1 >/dev/null)" || fail "second checkpoint failed"
[ -z "$err" ] || fail "second checkpoint on an ignored note wrote to stderr: $err"
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"
mkdir -p "$R/docs/handoffs"; printf 'keep.txt\n' > "$R/docs/handoffs/.gitignore"
g0="$(fhash "$R/docs/handoffs/.gitignore")"
U="$(wfa init TASK --goal "foreign ignore")"
err="$(wfa checkpoint "$U" --offline --no-snapshot 2>&1 >/dev/null)" || fail "foreign .gitignore checkpoint failed"
[ "$(fhash "$R/docs/handoffs/.gitignore")" = "$g0" ] || fail "pre-existing .gitignore was rewritten"
[ "$(grep -c . <<<"$err")" = "1" ] && grep -q 'committable' <<<"$err" || fail "expected exactly one warning for a .gitignore without '*': $err"
ok "SC4 TR-F004: ignored note is silent; a foreign .gitignore keeps its bytes and gets one warning"

R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"
mkdir -p "$R/docs/handoffs"; echo old > "$R/docs/handoffs/old.md"
git -C "$R" add docs/handoffs/old.md; git -C "$R" commit -q -m "tracked note"
U="$(wfa init BUILD --goal "tracked")"
err="$(wfa checkpoint "$U" --offline --no-snapshot 2>&1 >/dev/null)" || fail "tracked-notes checkpoint failed"
[ -f "$R/docs/handoffs/$U.md" ] || fail "tracked-notes case did not write the note"
[ "$(grep -c 'committable' <<<"$err")" = "1" ] || fail "expected exactly one committable warning: $err"
[ ! -e "$R/docs/handoffs/.gitignore" ] || fail "tracked-notes case must not add a .gitignore"
ok "SC4 tracked notes: note written plus one stderr warning"

D="$(mktemp -d "$TMP/nogit-XXXXXX")"; export CLAUDE_PROJECT_DIR="$D"
U="$(wfa init TASK --goal "outside git")"
wfa checkpoint "$U" --offline >/dev/null || fail "checkpoint outside git failed"
[ -f "$D/docs/handoffs/$U.md" ] || fail "outside git: note not written"
[ ! -e "$D/docs/handoffs/.gitignore" ] || fail "outside git: no .gitignore expected"
grep -qx 'not a git repository' "$D/docs/handoffs/$U.md" || fail "outside git: Git section wrong"
ok "SC4 outside git the note is written, with no snapshot"

# ---------------------------------------------------------------- SC5 -------
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"
git -C "$R" checkout -q -b feat
U="$(wfa init BUILD --goal "resume")"
U0="$(wfa init BUILD --goal "never checkpointed")"
base0="$(mtkhash "$R")"  # read-only baseline, taken before the first resume call
out="$(wfa resume "$U0" --offline)"
grep -qx 'drift: no checkpoint recorded' <<<"$out" || fail "no-checkpoint drift wrong: $out"
[ "$(mtkhash "$R")" = "$base0" ] || fail "resume on an unchecked workflow wrote under .mtk or docs/handoffs"
: > "$GH_STUB_LOG"
wfa checkpoint "$U" --next "go" --needs-user "Rename? | default: keep" --offline >/dev/null
a0="$(fhash "$(art "$U")")"; e0="$(fhash "$R/.mtk/workflows/$U.events.jsonl")"; n0="$(fhash "$R/docs/handoffs/$U.md")"
base1="$(mtkhash "$R")"  # baseline before the first resume of the checkpointed workflow
out="$(wfa resume "$U" --offline)"
[ "$(wc -l <<<"$out" | tr -d ' ')" = "4" ] || fail "resume should print 4 lines: $out"
grep -qxF "RESUME $U (BUILD, phase-0, active) — note: docs/handoffs/$U.md" <<<"$out" || fail "resume header wrong: $out"
grep -qx 'drift: none; PR not checked (offline)' <<<"$out" || fail "fresh offline checkpoint drift wrong: $out"
grep -qx 'next_command: /mtk:implement' <<<"$out" || fail "resume next_command wrong: $out"
grep -qx 'needs_user: 1 open question(s) — see the note' <<<"$out" || fail "resume needs_user wrong: $out"
[ ! -s "$GH_STUB_LOG" ] || fail "--offline invoked gh: $(cat "$GH_STUB_LOG")"
ok "SC5 resume block; --offline never invokes gh"

[ "$(mtkhash "$R")" = "$base1" ] || fail "resume --offline wrote under .mtk or docs/handoffs"
echo more >> "$R/a.txt"; git -C "$R" commit -q -am "after checkpoint"
out="$(wfa resume "$U" --offline)"
grep -q '^drift: sha moved [0-9a-f]\{7\}→[0-9a-f]\{7\} (1 commits); PR not checked (offline)$' <<<"$out" || fail "sha-moved drift wrong: $out"
out="$(GH_STUB_MODE=merged wfa resume "$U")"
grep -q 'PR #9 merged' <<<"$out" || fail "merged PR drift missing: $out"
out="$(GH_STUB_MODE=fail wfa resume "$U")"
grep -qF '(PR not checked: gh exited 4' <<<"$out" || fail "gh failure not surfaced in drift: $out"
git -C "$R" checkout -q main
out="$(wfa resume "$U" --offline)"
grep -q 'on branch main, note is for feat' <<<"$out" || fail "wrong-branch drift missing: $out"
git -C "$R" branch -q -D feat
out="$(wfa resume "$U" --offline)"
grep -q 'branch feat gone' <<<"$out" || fail "branch-gone drift missing: $out"
[ "$(fhash "$(art "$U")")" = "$a0" ] && [ "$(fhash "$R/.mtk/workflows/$U.events.jsonl")" = "$e0" ] \
  && [ "$(fhash "$R/docs/handoffs/$U.md")" = "$n0" ] && [ "$(mtkhash "$R")" = "$base1" ] \
  || fail "resume wrote to the artifact, event log or note"
old_wt="$(jget "$U" 'd["results"]["checkpoint"]["worktree"]')"
mv "$R" "$R-moved"; export CLAUDE_PROJECT_DIR="$R-moved"
out="$(wfa resume "$U" --offline)"
grep -qF "worktree $old_wt gone" <<<"$out" || fail "worktree-gone drift missing: $out"
rc=0; wfa resume wf-nope --offline >/dev/null 2>&1 || rc=$?; [ "$rc" = 1 ] || fail "resume unknown uuid should exit 1 (got $rc)"
ok "SC5 drift: sha moved, PR merged, gh failure, wrong branch, branch gone, worktree gone; resume is read-only"

# ---------------------------------------------------------------- SC6 -------
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"
U="$(wfa init TASK --goal "lightweight")" || fail "init TASK rejected"
[ "$(jget "$U" 'd["workflow_type"]')" = "TASK" ] || fail "init TASK stored the wrong type"
err="$(wfa init 2>&1)" && fail "init without a type accepted"
grep -q 'TASK' <<<"$err" || fail "init error text should list TASK: $err"
out="$(wfa batch "$U" set results.foo=1 -- checkpoint --next "after foo" --offline --no-snapshot)" || fail "batch with checkpoint last failed"
grep -q 'batch applied 2 op(s)' <<<"$out" || fail "batch summary wrong: $out"
[ "$(jget "$U" 'd["results"]["foo"]')" = "1" ] || fail "batch set op not applied"
grep -qx 'after foo' "$R/docs/handoffs/$U.md" || fail "batch checkpoint op not applied"
grep -qx "next_command: read docs/handoffs/$U.md and continue" <(fm "$R/docs/handoffs/$U.md") || fail "TASK default next_command wrong"
ok "SC6 init TASK; batch set + checkpoint (last) applies both"

a0="$(fhash "$(art "$U")")"
rc=0; err="$(wfa batch "$U" checkpoint --next x -- set results.bar=2 2>&1 >/dev/null)" || rc=$?
[ "$rc" = 1 ] || fail "checkpoint not last should be rejected (got $rc)"
grep -q 'must be the last op' <<<"$err" || fail "misordered batch error unclear: $err"
rc=0; printf '%s\n' '["checkpoint","--next","x"]' '["set","results.bar=2"]' | ( cd "$R" && bash "$WFA" batch "$U" ) >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "stdin batch with checkpoint not last should be rejected (got $rc)"
[ "$(fhash "$(art "$U")")" = "$a0" ] || fail "misordered batch applied an op"
err="$(wfa batch "$U" read 2>&1)" && fail "non-batchable op accepted"
grep -qF 'allowed: set event gate criteria remediation seal trap checkpoint' <<<"$err" || fail "allowed list lacks checkpoint: $err"
ok "SC6 batch with checkpoint not last is rejected before any op runs"

write_sidecar "$R/docs/specs/2026-03-03-batch.md" '["B1"]'
wfa set "$U" results.spec_path=docs/specs/2026-03-03-batch.md >/dev/null
# The note path was fixed by the first checkpoint (computed once).
NOTE="$R/docs/handoffs/$U.md"; n0="$(fhash "$NOTE")"
rc=0; wfa batch "$U" set results.baz=3 -- checkpoint --next "redo B1" --offline --no-snapshot >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] || fail "checkpoint rejection inside a batch should exit 3 (got $rc)"
[ "$(jget "$U" 'd["results"]["baz"]')" = "3" ] || fail "earlier batch op should stay applied"
[ "$(fhash "$NOTE")" = "$n0" ] || fail "rejected batch checkpoint changed the note"
[ ! -e "$R/docs/handoffs/2026-03-03-batch.md" ] || fail "checkpoint_path was recomputed instead of kept"
ok "SC6 checkpoint rejection inside a batch exits 3 with the earlier op applied"

# ---------------------------------------------------------------- FIX-A1 ----
# TR-F002: pushed / ahead / behind from a real upstream, and the 14-day expiry.
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"
BARE="$(mktemp -d "$TMP/bare-XXXXXX")"; git -C "$BARE" init -q --bare .
git -C "$R" remote add origin "$BARE"; git -C "$R" push -q -u origin main 2>/dev/null
U="$(wfa init TASK --goal "upstream")"
wfa checkpoint "$U" --offline --no-snapshot >/dev/null
NOTE="$R/docs/handoffs/$U.md"
grep -qx 'pushed: true' <(fm "$NOTE") || fail "pushed should be true at the upstream tip: $(fm "$NOTE")"
grep -qx 'ahead: 0' <(fm "$NOTE") && grep -qx 'behind: 0' <(fm "$NOTE") || fail "ahead/behind should be 0/0"
want_exp="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=14)).strftime("%Y-%m-%d"))')"
grep -qx "expires: $want_exp" <(fm "$NOTE") || fail "expires is not today(UTC)+14d ($want_exp): $(fm "$NOTE")"
echo local >> "$R/a.txt"; git -C "$R" commit -q -am "local only"
wfa checkpoint "$U" --offline --no-snapshot >/dev/null
for kv in 'pushed: false' 'ahead: 1' 'behind: 0'; do
  grep -qx "$kv" <(fm "$NOTE") || fail "after a local commit expected '$kv': $(fm "$NOTE")"
done
ok "FIX-A1 TR-F002 pushed/ahead/behind follow the upstream; expires is +14 days"

# TR-F003: setting spec_path later keeps the note at its first path (checkpoint_path kept).
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"
U="$(wfa init BUILD --goal "keep path")"
wfa checkpoint "$U" --offline --no-snapshot >/dev/null 2>&1
write_sidecar "$R/docs/specs/2026-04-04-kept.md" '[]'
wfa set "$U" results.spec_path=docs/specs/2026-04-04-kept.md >/dev/null
wfa checkpoint "$U" --next "start B1" --offline --no-snapshot >/dev/null || fail "checkpoint after setting spec_path failed"
[ "$(jget "$U" 'd["results"]["checkpoint_path"]')" = "docs/handoffs/$U.md" ] || fail "checkpoint_path was replaced"
[ ! -e "$R/docs/handoffs/2026-04-04-kept.md" ] || fail "a spec-slug note appeared"
grep -qx '| B1 | Core | next |' "$R/docs/handoffs/$U.md" || fail "original note was not rewritten with the units"
ok "FIX-A1 TR-F003 the original note is rewritten; no spec-slug note appears"

# TR-F005 + SF-F001: units sidecar variants and the inactive-validator warning.
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"
U="$(wfa init BUILD --goal "missing sidecar")"
wfa set "$U" results.spec_path=docs/specs/2026-05-01-missing.md >/dev/null
rc=0; err="$(wfa checkpoint "$U" --offline --no-snapshot 2>&1 >/dev/null)" || rc=$?
[ "$rc" = 0 ] || fail "missing sidecar must not change the exit code (got $rc)"
grep -qF 'no plan sidecar (docs/specs/2026-05-01-missing.json not found)' "$R/docs/handoffs/2026-05-01-missing.md" || fail "missing-sidecar Units text wrong"
[ "$(grep -c 'validator inactive' <<<"$err")" = "1" ] && grep -q 'not found' <<<"$err" || fail "expected one inactive-validator warning naming the reason: $err"
U="$(wfa init BUILD --goal "bad json")"
mkdir -p "$R/docs/specs"; echo "# spec" > "$R/docs/specs/2026-05-02-bad.md"; echo '{not json' > "$R/docs/specs/2026-05-02-bad.json"
wfa set "$U" results.spec_path=docs/specs/2026-05-02-bad.md >/dev/null
rc=0; err="$(wfa checkpoint "$U" --offline --no-snapshot 2>&1 >/dev/null)" || rc=$?
[ "$rc" = 0 ] || fail "invalid sidecar JSON must not change the exit code (got $rc)"
grep -qF 'no plan sidecar (docs/specs/2026-05-02-bad.json unreadable' "$R/docs/handoffs/2026-05-02-bad.md" || fail "invalid-JSON Units text wrong"
[ "$(grep -c 'validator inactive' <<<"$err")" = "1" ] && grep -q 'unreadable' <<<"$err" || fail "expected one inactive-validator warning for invalid JSON: $err"
U="$(wfa init BUILD --goal "json path")"
write_sidecar "$R/docs/specs/2026-05-03-json.md" '[]'
wfa set "$U" results.spec_path=docs/specs/2026-05-03-json.json >/dev/null
err="$(wfa checkpoint "$U" --offline --no-snapshot 2>&1 >/dev/null)" || fail "spec_path ending .json failed"
grep -qx '| B1 | Core | next |' "$R/docs/handoffs/2026-05-03-json.md" || fail "spec_path ending .json did not load the sidecar"
[ -z "$err" ] || fail "a valid .json spec_path should not warn: $err"
U="$(wfa init BUILD --goal "absolute path")"
write_sidecar "$R/docs/specs/2026-05-04-abs.md" '["B1"]'
wfa set "$U" "results.spec_path=$R/docs/specs/2026-05-04-abs.md" >/dev/null
wfa checkpoint "$U" --offline --no-snapshot >/dev/null 2>&1 || fail "absolute spec_path failed"
grep -qx '| B1 | Core | done |' "$R/docs/handoffs/2026-05-04-abs.md" || fail "absolute spec_path did not load the sidecar"
U="$(wfa init BUILD --goal "no spec")"
err="$(wfa checkpoint "$U" --offline --no-snapshot 2>&1 >/dev/null)" || fail "BUILD without spec_path failed"
[ "$(grep -c 'validator inactive' <<<"$err")" = "1" ] || fail "BUILD without spec_path should warn once: $err"
U="$(wfa init TASK --goal "no spec task")"
err="$(wfa checkpoint "$U" --offline --no-snapshot 2>&1 >/dev/null)" || fail "TASK failed"
grep -q 'validator inactive' <<<"$err" && fail "TASK without spec_path must not warn: $err"
ok "FIX-A1 TR-F005 sidecar missing / invalid / .json / absolute; SF-F001 warns once when the validator is inactive"

# TR-F006: flag handling.
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"
U="$(wfa init BUILD --goal "flags")"
wfa checkpoint "$U" --next-command "/mtk:custom go" --needs-user "Q1? | default: a" --offline --no-snapshot >/dev/null 2>&1
NOTE="$R/docs/handoffs/$U.md"
grep -qx 'next_command: /mtk:custom go' <(fm "$NOTE") || fail "--next-command not in frontmatter"
grep -qx 'next_command: `/mtk:custom go`' "$NOTE" || fail "--next-command not in ## Next"
wfa checkpoint "$U" --needs-user "Q2? | default: b" --offline --no-snapshot >/dev/null 2>&1
n="$(fm "$NOTE" | awk '/^needs_user:/')"
grep -qF 'Q2?' <<<"$n" && ! grep -qF 'Q1?' <<<"$n" || fail "second --needs-user should replace the first: $n"
wfa checkpoint "$U" --no-needs-user --offline --no-snapshot >/dev/null 2>&1
grep -qx 'needs_user: \[\]' <(fm "$NOTE") || fail "--no-needs-user did not empty the list"
rc=0; wfa checkpoint "$U" --wait-until "tomorrow" --offline --no-snapshot >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "bad --wait-until should exit 1 (got $rc)"
wfa checkpoint "$U" --next-command "$(printf 'line one\nline two')" --offline --no-snapshot >/dev/null 2>&1
grep -qx 'next_command: line one line two' <(fm "$NOTE") || fail "multi-line --next-command should be one frontmatter line: $(fm "$NOTE")"
[ "$(fm "$NOTE" | awk '/^next_command:/' | wc -l | tr -d ' ')" = "1" ] || fail "next_command repeated in frontmatter"
grep -qx 'next_command: `line one line two`' "$NOTE" || fail "## Next next_command should be one line"
wfa checkpoint "$U" --verify "bash t.sh => exit 0" --offline --no-snapshot >/dev/null 2>&1
[ "$(jget "$U" 'd["results"]["last_verify"]["sha"]')" = "$(git -C "$R" rev-parse --short HEAD)" ] || fail "last_verify did not record the sha"
grep -qF "(sha $(git -C "$R" rev-parse --short HEAD)," "$NOTE" || fail "note does not show the verify sha"
UF="$(wfa init FIX --goal "fixing")"
wfa checkpoint "$UF" --offline --no-snapshot >/dev/null 2>&1
grep -qx 'next_command: /mtk:batch-fix' <(fm "$R/docs/handoffs/$UF.md") || fail "FIX default next_command wrong"
ok "FIX-A1 TR-F006 --next-command, FIX default, --needs-user replace, --no-needs-user, bad --wait-until, multi-line, verify sha"

# TR-F007: gh stub modes through checkpoint and resume.
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"; git -C "$R" checkout -q -b ghfeat
U="$(wfa init TASK --goal "gh modes")"
GH_STUB_MODE=none wfa checkpoint "$U" --no-snapshot >/dev/null 2>&1
grep -qF 'no pull request for `ghfeat`' "$R/docs/handoffs/$U.md" || fail "gh none: PR line wrong"
grep -qx 'drift: none' <(GH_STUB_MODE=none wfa resume "$U") || fail "gh none: resume drift should be none"
GH_STUB_MODE=closed wfa checkpoint "$U" --no-snapshot >/dev/null 2>&1
grep -qF -- '- PR #11 CLOSED' "$R/docs/handoffs/$U.md" || fail "gh closed: PR line wrong"
grep -q '^drift: PR #11 closed$' <(GH_STUB_MODE=closed wfa resume "$U") || fail "gh closed: resume drift wrong"
GH_STUB_MODE=badjson wfa checkpoint "$U" --no-snapshot >/dev/null 2>&1
grep -qF 'not checked (gh returned unparseable JSON)' "$R/docs/handoffs/$U.md" || fail "gh badjson: PR line wrong"
grep -qF '(PR not checked: gh returned unparseable JSON)' <(GH_STUB_MODE=badjson wfa resume "$U") || fail "gh badjson: resume drift wrong"
t0="$(date +%s)"
GH_STUB_MODE=hang wfa checkpoint "$U" --no-snapshot >/dev/null 2>&1 || fail "gh hang: checkpoint failed"
t1="$(date +%s)"
[ $((t1 - t0)) -lt 25 ] || fail "gh hang: checkpoint took $((t1 - t0))s, the 8s timeout did not bound it"
grep -qF 'not checked (gh timed out after 8s)' "$R/docs/handoffs/$U.md" || fail "gh hang: PR line wrong"
ok "FIX-A1 TR-F007 gh none / closed / badjson / hang (bounded) in the note and in resume drift"

# TR-F008: snapshot failure is non-fatal, stated in ## Git, warned once.
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"
printf x > "$R/.git/refs/mtk"
U="$(wfa init TASK --goal "snapfail")"
rc=0; err="$(wfa checkpoint "$U" --offline 2>&1 >/dev/null)" || rc=$?
[ "$rc" = 0 ] || fail "snapshot failure should not fail the checkpoint (got $rc)"
[ -f "$R/docs/handoffs/$U.md" ] || fail "snapshot failure: note not written"
grep -qF -- '- snapshot: failed' "$R/docs/handoffs/$U.md" || fail "snapshot failure not stated in ## Git"
[ "$(grep -c 'snapshot skipped' <<<"$err")" = "1" ] || fail "expected one snapshot warning: $err"
ok "FIX-A1 TR-F008 a failing update-ref keeps the note, says so in ## Git, warns once"

# TR-F009: ## Goal content.
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"
U="$(wfa init TASK --goal "Ship the exact goal text")"
wfa checkpoint "$U" --offline --no-snapshot >/dev/null
[ "$(awk '/^## Goal$/{getline; getline; print; exit}' "$R/docs/handoffs/$U.md")" = "Ship the exact goal text" ] || fail "## Goal does not equal the init --goal text"
U="$(wfa init TASK)"
wfa checkpoint "$U" --offline --no-snapshot >/dev/null
[ "$(awk '/^## Goal$/{getline; getline; print; exit}' "$R/docs/handoffs/$U.md")" = "(no goal recorded)" ] || fail "## Goal without a goal should say so"
ok "FIX-A1 TR-F009 ## Goal renders the init goal, or says none was recorded"

# SF-F002: drift never says `none` for a check that did not run.
D="$(mktemp -d "$TMP/nogit-resume-XXXXXX")"; export CLAUDE_PROJECT_DIR="$D"
U="$(wfa init TASK --goal "outside")"
wfa checkpoint "$U" --offline >/dev/null
out="$(wfa resume "$U" --offline)"
grep -qx 'drift: unchecked (not in a git repository); PR not checked (offline)' <<<"$out" || fail "outside git drift wrong: $out"
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"; git -C "$R" checkout -q --detach
U="$(wfa init TASK --goal "detached")"
wfa checkpoint "$U" --offline >/dev/null
grep -qx 'branch: -' <(fm "$R/docs/handoffs/$U.md") || fail "fixture: detached HEAD should record branch '-'"
out="$(wfa resume "$U" --offline)"
grep -q '^drift: unchecked (checkpoint recorded no branch' <<<"$out" || fail "branch '-' drift wrong: $out"
grep -qx 'drift: none' <<<"$out" && fail "drift said none for a skipped comparison"
ok "FIX-A1 SF-F002 drift is unchecked outside git or with no branch; offline is stated"

# AR-F001: resume --porcelain contract.
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"; git -C "$R" checkout -q -b pfeat
U="$(wfa init BUILD --goal "porcelain")"
wfa checkpoint "$U" --next-command "$(printf '/mtk:implement\nnow')" --needs-user "Go? | default: yes" --offline >/dev/null 2>&1
h0="$(mtkhash "$R")"
out="$(wfa resume "$U" --porcelain --offline)"
keys="$(awk -F= '{printf "%s%s", (NR>1?",":""), $1}' <<<"$out")"
[ "$keys" = "uuid,type,phase,status,note,drift,pr_checked,next_command,needs_user" ] || fail "porcelain keys/order wrong: $keys"
[ "$(wc -l <<<"$out" | tr -d ' ')" = "9" ] || fail "porcelain should be 9 single-line entries: $out"
for kv in "uuid=$U" 'type=BUILD' 'status=active' "note=docs/handoffs/$U.md" 'drift=none; PR not checked (offline)' \
          'pr_checked=offline' 'next_command=/mtk:implement now' 'needs_user=1'; do
  grep -qxF "$kv" <<<"$out" || fail "porcelain lacks '$kv': $out"
done
[ "$(mtkhash "$R")" = "$h0" ] || fail "resume --porcelain wrote to .mtk or docs/handoffs"
grep -qx 'pr_checked=true' <(GH_STUB_MODE=open wfa resume "$U" --porcelain) || fail "pr_checked should be true when gh answered"
grep -qx 'pr_checked=false' <(GH_STUB_MODE=fail wfa resume "$U" --porcelain) || fail "pr_checked should be false when gh failed"
rc=0; wfa resume wf-nope --porcelain >/dev/null 2>&1 || rc=$?; [ "$rc" = 1 ] || fail "porcelain unknown uuid should exit 1 (got $rc)"
rc=0; wfa resume "$U" --porcelain --bogus >/dev/null 2>&1 || rc=$?; [ "$rc" = 1 ] || fail "porcelain bad flag should exit 1 (got $rc)"
[ "$(jget "$U" 'd["results"]["handoff_path"]')" = "docs/handoffs/$U.md" ] || fail "results.handoff_path not recorded (X-HANDOFF-PATH)"
ok "FIX-A1 AR-F001 resume --porcelain keys, order, single lines, read-only; X-HANDOFF-PATH recorded"

# FR2-F002: the inactive-validator warning is exactly one line for a FIX without
# spec_path, and for a TASK whose spec_path names a missing sidecar.
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"
U="$(wfa init FIX --goal "fix no spec")"
err="$(wfa checkpoint "$U" --offline --no-snapshot 2>&1 >/dev/null)" || fail "FIX without spec_path failed"
[ "$(grep -c 'validator inactive' <<<"$err")" = "1" ] || fail "FIX without spec_path should warn once: $err"
U="$(wfa init TASK --goal "task with missing sidecar")"
wfa set "$U" results.spec_path=docs/specs/2026-05-09-gone.md >/dev/null
err="$(wfa checkpoint "$U" --offline --no-snapshot 2>&1 >/dev/null)" || fail "TASK with missing sidecar failed"
[ "$(grep -c 'validator inactive' <<<"$err")" = "1" ] || fail "TASK with a missing sidecar should warn once: $err"
ok "FR2 F002 validator-inactive warning once for FIX without spec_path and TASK with a missing sidecar"

# FR2-F003: a checkpoint taken on an unborn branch recorded no sha; after the
# first commit, resume must say so instead of claiming "none".
R3="$(mktemp -d "$TMP/unborn-resume-XXXXXX")"; git -C "$R3" init -q .; echo x > "$R3/f.txt"
export CLAUDE_PROJECT_DIR="$R3"
U3="$(wfa init TASK --goal "unborn then commit")"
wfa checkpoint "$U3" --offline --no-snapshot >/dev/null 2>&1 || fail "unborn checkpoint failed"
git -C "$R3" add -A; git -C "$R3" commit -q -m first
out="$(wfa resume "$U3" --offline)"
grep -qxF 'drift: unchecked (checkpoint recorded no sha); PR not checked (offline)' <<<"$out" || fail "unborn-then-commit drift wrong: $out"
ok "FR2 F003 unborn checkpoint then commit: resume reports unchecked (no sha)"

# FR2-F005: unchanged / refreshed / moved snapshots — note line, event word, parents.
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"
U="$(wfa init TASK --goal "snapshot words")"
REF="refs/mtk/checkpoints/$U"
last_snap() { python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["data"]["snapshot"])' "$R/.mtk/workflows/$U.events.jsonl"; }
wfa checkpoint "$U" --next "step one" --offline >/dev/null 2>&1 || fail "first snapshot failed"
[ "$(last_snap)" = "moved" ] || fail "first snapshot event word should be moved (got $(last_snap))"
sleep 2
wfa checkpoint "$U" --next "step one" --offline >/dev/null 2>&1 || fail "unchanged snapshot failed"
[ "$(last_snap)" = "unchanged" ] || fail "unchanged snapshot event word wrong (got $(last_snap))"
grep -qF '(unchanged since the previous checkpoint)' "$R/docs/handoffs/$U.md" || fail "note lacks the unchanged-checkpoint line"
wfa checkpoint "$U" --next "step two" --offline >/dev/null 2>&1 || fail "refreshed snapshot failed"
[ "$(last_snap)" = "moved" ] || fail "refreshed snapshot event word should be moved (got $(last_snap))"
grep -qF 'message refreshed, tree unchanged' "$R/docs/handoffs/$U.md" || fail "note lacks the refreshed line"
[ "$(git -C "$R" rev-list --parents -n 1 "$REF" | wc -w | tr -d ' ')" = "2" ] || fail "refreshed commit should have exactly one parent"
echo more >> "$R/a.txt"
wfa checkpoint "$U" --next "step two" --offline >/dev/null 2>&1 || fail "moved snapshot failed"
[ "$(last_snap)" = "moved" ] || fail "moved snapshot event word wrong (got $(last_snap))"
ok "FR2 F005 snapshot unchanged/refreshed/moved: note line, event word, single parent"

# FR2-F004: --porcelain phase, TASK type, and the never-checkpointed output.
R="$(new_repo)"; export CLAUDE_PROJECT_DIR="$R"
U="$(wfa init TASK --goal "porcelain extras")"
out="$(wfa resume "$U" --porcelain --offline)"
for kv in 'type=TASK' 'note=(none written)' 'drift=no checkpoint recorded' 'pr_checked=false'; do
  grep -qxF "$kv" <<<"$out" || fail "never-checkpointed porcelain lacks '$kv': $out"
done
wfa set "$U" phase_cursor=phase-7 >/dev/null || fail "could not set phase_cursor"
grep -qxF 'phase=phase-7' <(wfa resume "$U" --porcelain --offline) || fail "porcelain phase did not follow phase_cursor"
ok "FR2 F004 porcelain: phase from phase_cursor, TASK type, never-checkpointed values"

mkdir -p "$TMP/nopy"; ln -s "$(command -v dirname)" "$TMP/nopy/dirname"
rc=0; err="$(env PATH="$TMP/nopy" "$BASH" "$WFA" checkpoint "$U" 2>&1)" || rc=$?
[ "$rc" = 2 ] || fail "missing python3 should exit 2 (got $rc): $err"
grep -q 'requires python3' <<<"$err" || fail "missing python3 message unclear: $err"
ok "checkpoint without python3 exits 2 with a clear message"

echo "test-workflow-artifact-checkpoint: all checks passed"
