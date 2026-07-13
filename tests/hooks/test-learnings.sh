#!/usr/bin/env bash
set -euo pipefail
# test-learnings.sh — scripts/learnings.sh regression coverage for defects A-E.
#
# Fully sandboxed: every run happens inside a throwaway git repo under mktemp, so
# the store anchors there and the real repo / live session state is never touched.
# Assertions abort on first failure (no accumulating counters — bash subshells
# would lose them; see tasks/lessons.md).

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LS="$REPO_ROOT/scripts/learnings.sh"
[ -f "$LS" ] || { echo "FAIL: cannot find $LS"; exit 1; }

SBX="$(mktemp -d -t mtk-learnings-XXXXXX)"
cleanup() { rm -rf "$SBX"; }
trap cleanup EXIT

fail() { echo "FAIL: $1"; exit 1; }
ok()   { echo "PASS: $1"; }

# Spin up a fresh sandbox git repo and echo its path.
new_repo() {
  local d; d="$(mktemp -d "$SBX/repo-XXXXXX")"
  git -C "$d" init -q
  printf '%s' "$d"
}

# ---------------------------------------------------------------------------
# E — store anchors to the INVOKING repo (git toplevel of cwd), not the script
#     root (the plugin cache). No MTK_LEARNINGS_PATH override here on purpose.
# ---------------------------------------------------------------------------
R="$(new_repo)"
( cd "$R" && bash "$LS" add --source manual --title "Anchor test" >/dev/null )
[ -f "$R/.mtk/learnings.jsonl" ] || fail "E: store not written into invoking repo ($R/.mtk/learnings.jsonl missing)"
[ ! -e "$REPO_ROOT/scripts/.mtk" ] || fail "E: store leaked next to the script"
ok "E: store anchored to invoking repo, not script root"

# MTK_LEARNINGS_PATH override is still honored (sandboxed store).
R="$(new_repo)"
( cd "$R" && MTK_LEARNINGS_PATH="$R/custom/store.jsonl" bash "$LS" add --source manual --title "Override" >/dev/null )
[ -f "$R/custom/store.jsonl" ] || fail "E: MTK_LEARNINGS_PATH override not honored"
ok "E: MTK_LEARNINGS_PATH override honored"

# ---------------------------------------------------------------------------
# B — next_id survives past 8 entries/day (no octal parse abort). Add 12.
# ---------------------------------------------------------------------------
R="$(new_repo)"
(
  cd "$R"
  i=1
  while [ "$i" -le 12 ]; do
    bash "$LS" add --source manual --title "entry $i" >/dev/null
    i=$((i + 1))
  done
)
n="$(wc -l < "$R/.mtk/learnings.jsonl" | tr -d ' ')"
[ "$n" -eq 12 ] || fail "B: expected 12 entries, got $n (octal id bug?)"
today="$(date -u +%Y-%m-%d)"
grep -q "\"id\":\"L-${today}-012\"" "$R/.mtk/learnings.jsonl" || fail "B: id L-${today}-012 not allocated"
ok "B: 12 same-day adds, ids monotonic past octal boundary"

# ---------------------------------------------------------------------------
# A — regen-markdown works with shrink-guard present (SCRIPT_ROOT resolves it).
#     The pre-fix bug passed file CONTENT to the guard and exited 2.
# ---------------------------------------------------------------------------
[ -f "$REPO_ROOT/hooks/lib/shrink-guard.sh" ] || fail "A: precondition — shrink-guard.sh missing from script root"
R="$(new_repo)"
(
  cd "$R"
  bash "$LS" add --source manual --scope team --title "Regen A team" >/dev/null
  bash "$LS" regen-markdown
) > "$SBX/regen.out" 2> "$SBX/regen.err" || fail "A: regen-markdown exited non-zero. stderr: $(cat "$SBX/regen.err")"
grep -q "source not readable" "$SBX/regen.err" && fail "A: shrink-guard 'source not readable' (content passed instead of path)"
[ -f "$R/tasks/lessons.md" ] || fail "A: tasks/lessons.md not generated"
grep -q '<!-- Auto-generated below' "$R/tasks/lessons.md" || fail "A: auto-generated marker missing"
grep -q "Regen A team" "$R/tasks/lessons.md" || fail "A: team entry not rendered"
ok "A: regen-markdown succeeds through shrink-guard (path passed, not content)"

# ---------------------------------------------------------------------------
# C — personal entries must NOT leak into the committed team file.
# ---------------------------------------------------------------------------
R="$(new_repo)"
(
  cd "$R"
  bash "$LS" add --source manual --scope team     --title "TEAM-visible rule" >/dev/null
  bash "$LS" add --source correction --scope personal --decision-origin user-directed \
    --title "PERSONAL-secret preference" >/dev/null
  bash "$LS" regen-markdown >/dev/null
)
grep -q "TEAM-visible rule" "$R/tasks/lessons.md" || fail "C: team entry missing from lessons.md"
grep -q "PERSONAL-secret preference" "$R/tasks/lessons.md" && fail "C: personal entry leaked into committed team file"
ok "C: regen renders team-scope only; personal entries excluded"

# ---------------------------------------------------------------------------
# A/guard — regen refuses to clobber a hand-written (marker-less) lessons.md.
# ---------------------------------------------------------------------------
R="$(new_repo)"
mkdir -p "$R/tasks"
printf '# My hand-written lessons\n\n- do not delete me\n' > "$R/tasks/lessons.md"
(
  cd "$R"
  bash "$LS" add --source manual --scope team --title "New entry" >/dev/null
  bash "$LS" regen-markdown
) > "$SBX/refuse.out" 2> "$SBX/refuse.err" && fail "A/guard: regen should have refused a marker-less file"
grep -q "refusing to overwrite" "$SBX/refuse.err" || fail "A/guard: expected refusal message, got: $(cat "$SBX/refuse.err")"
grep -q "do not delete me" "$R/tasks/lessons.md" || fail "A/guard: hand-written content was destroyed"
ok "A/guard: refuses to overwrite marker-less hand-written lessons.md"

# ---------------------------------------------------------------------------
# D — migrate parses '## ' heading blocks (not bullets), is idempotent via
#     title hash, and survives >8 entries (combines with the octal fix).
# ---------------------------------------------------------------------------
R="$(new_repo)"
mkdir -p "$R/tasks"
cp "$REPO_ROOT/tasks/lessons.md" "$R/tasks/lessons.md"
cp "$REPO_ROOT/tasks/lessons.md" "$SBX/orig-lessons.md"
heading_count="$(grep -c '^## ' "$SBX/orig-lessons.md" | tr -d ' ')"
[ "$heading_count" -gt 8 ] || fail "D: precondition — need >8 headings to exercise octal fix (got $heading_count)"

( cd "$R" && bash "$LS" migrate >/dev/null ) || fail "D: migrate exited non-zero"
entries="$(wc -l < "$R/.mtk/learnings.jsonl" | tr -d ' ')"
[ "$entries" -eq "$heading_count" ] || fail "D: expected $heading_count entries (one per heading), got $entries (bullet-shredding?)"
ok "D: migrate produced one entry per heading block ($entries == $heading_count)"

# Second run: 'Already migrated' guard → adds zero.
( cd "$R" && bash "$LS" migrate >/dev/null ) || fail "D: second migrate exited non-zero"
entries2="$(wc -l < "$R/.mtk/learnings.jsonl" | tr -d ' ')"
[ "$entries2" -eq "$entries" ] || fail "D: second migrate added entries ($entries -> $entries2)"
ok "D: second migrate is a no-op (already-migrated guard)"

# Title-hash idempotency, isolated from the marker guard: restore the pristine
# marker-less legacy file over the (now marker-carrying) regenerated one and
# migrate again — every title hash already exists, so zero adds.
cp "$SBX/orig-lessons.md" "$R/tasks/lessons.md"
( cd "$R" && bash "$LS" migrate >/dev/null ) || fail "D: title-hash migrate exited non-zero"
entries3="$(wc -l < "$R/.mtk/learnings.jsonl" | tr -d ' ')"
[ "$entries3" -eq "$entries" ] || fail "D: title-hash dedup failed ($entries -> $entries3)"
ok "D: migrate idempotent via title hash even on a marker-less re-feed"

echo "ALL LEARNINGS TESTS PASSED"
