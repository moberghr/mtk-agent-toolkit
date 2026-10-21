#!/usr/bin/env bash
set -euo pipefail

# Anti-resurrection framing (round 8, option B): post-compaction recovery
# context must be framed as a historical snapshot — reference, not
# instructions — so cancelled/superseded work cannot restart itself after
# compaction. session-start owns this now (it absorbed post-compact.sh): on a
# `compact` SessionStart it appends the recovery block; with no recoverable
# state, or on any other source, there is no recovery block.
# Handoffs are branch-scoped: compact re-injects only an open (or accepted this
# session) note for the current branch; startup appends one HANDOFF OFFER line.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/session-start"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"   # Claude Code output format (additionalContext)
COMPACT='{"hook_event_name":"SessionStart","source":"compact","session_id":"s-compact"}'
STARTUP='{"hook_event_name":"SessionStart","source":"startup","session_id":"s-startup"}'

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
export TMPDIR="$WORK/tmp"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
git -C "$WORK" init -q
mkdir -p "$TMPDIR"
cd "$WORK"

# --- 1. no recoverable state → no recovery block ------------------------------

out="$(CLAUDE_PROJECT_DIR="$WORK" bash "$HOOK" <<<"$COMPACT" 2>/dev/null || true)"
case "$out" in *'POST-COMPACTION'*) fail "empty repo must emit no recovery block. Got: $out" ;; esac
printf '  PASS  empty state emits no recovery block\n'

# --- 2. recovered state carries the anti-resurrection framing -------------------

mkdir -p tasks docs/handoffs
printf -- '- [ ] unfinished thing\n' > tasks/todo.md
printf '# handoff\n' > docs/handoffs/2099-session.md

out="$(CLAUDE_PROJECT_DIR="$WORK" bash "$HOOK" <<<"$COMPACT" 2>/dev/null || true)"
case "$out" in *'POST-COMPACTION RECOVERY'*) : ;; *) fail "recoverable state must emit the recovery block on compact. Got: $out" ;; esac
case "$out" in *'HISTORICAL SNAPSHOT'*) : ;; *) fail "framing must declare a historical snapshot. Got: $out" ;; esac
case "$out" in *'latest user message always wins'*) : ;; *) fail "framing must state the latest user message wins. Got: $out" ;; esac
case "$out" in *'do not resume it'*) : ;; *) fail "framing must close cancelled work. Got: $out" ;; esac
case "$out" in *'"additionalContext"'*) : ;; *) fail "must emit the SessionStart additionalContext envelope. Got: $out" ;; esac
printf '  PASS  recovery context framed as reference-only\n'

# --- 3. only on compact: startup with the same state emits no recovery block ----

out="$(CLAUDE_PROJECT_DIR="$WORK" bash "$HOOK" <<<"$STARTUP" 2>/dev/null || true)"
case "$out" in *'POST-COMPACTION'*) fail "startup must not emit the post-compaction block. Got: $out" ;; esac
case "$out" in *'"additionalContext"'*) : ;; *) fail "startup must still emit its SessionStart context. Got: $out" ;; esac
printf '  PASS  recovery block is compact-only\n'

# --- 4. handoffs are branch-scoped (scripts/handoff-state.sh) -------------------
# A fresh project on branch feat/ho-test with a recent spec, one open handoff for
# this branch (older) and one for another branch (newest).

P2="$WORK/p2"
mkdir -p "$P2/docs/specs" "$P2/docs/handoffs"
git -C "$P2" init -q
git -C "$P2" symbolic-ref HEAD refs/heads/feat/ho-test
cd "$P2"
printf '# spec\n' > docs/specs/feature.md
handoff() { # $1 file  $2 branch
  printf -- '---\nstate: open\nbranch: %s\nworktree: %s\nexpires: 2099-12-31\n---\n# handoff\n' "$2" "$P2" > "docs/handoffs/$1"
}
handoff mine.md feat/ho-test
touch -t 202601010000 docs/handoffs/mine.md
handoff other.md feat/elsewhere
COMPACT2='{"hook_event_name":"SessionStart","source":"compact","session_id":"s-compact2"}'
STARTUP2='{"hook_event_name":"SessionStart","source":"startup","session_id":"s-startup2"}'
CLEAR2='{"hook_event_name":"SessionStart","source":"clear","session_id":"s-clear2"}'
RESUME2='{"hook_event_name":"SessionStart","source":"resume","session_id":"s-resume2"}'
run() { CLAUDE_PROJECT_DIR="$P2" bash "$HOOK" <<<"$1" 2>/dev/null || true; }

out="$(run "$COMPACT2")"
case "$out" in *'Recent handoff: docs/handoffs/mine.md'*) : ;; *) fail "compact must re-inject the open handoff for this branch. Got: $out" ;; esac
case "$out" in *'other.md'*) fail "compact must not re-inject another branch's handoff. Got: $out" ;; esac
printf '  PASS  compact shows only the matching-branch open handoff\n'

out="$(run "$STARTUP2")"
case "$out" in *'SESSION RECOVERY: Found recent spec'*'HANDOFF OFFER: open handoff for this branch at docs/handoffs/mine.md (2026-01-01) — read it if you are picking this work up.'*) : ;;
  *) fail "startup must keep the recovery line and append the handoff offer after it. Got: $out" ;; esac
case "$out" in *'POST-COMPACTION'*) fail "startup offer must never use the POST-COMPACTION token. Got: $out" ;; esac
case "$out" in *'other.md'*) fail "startup must not offer another branch's handoff. Got: $out" ;; esac
[ "$(grep -o 'HANDOFF OFFER:' <<<"$out" | wc -l | tr -d ' ')" = "1" ] || fail "startup must carry exactly one offer line. Got: $out"
printf '  PASS  startup carries the recovery line and exactly one HANDOFF OFFER line\n'

out="$(run "$CLEAR2")"
case "$out" in *'HANDOFF OFFER: open handoff for this branch at docs/handoffs/mine.md (2026-01-01) — read it if you are picking this work up.'*) : ;;
  *) fail "clear must offer the branch handoff with the same text as startup. Got: $out" ;; esac
out="$(run "$RESUME2")"
case "$out" in *'HANDOFF OFFER'*) fail "resume must not offer a handoff. Got: $out" ;; esac
printf '  PASS  offer on clear (same text as startup), none on resume\n'

git -C "$P2" symbolic-ref HEAD refs/heads/feat/third
out="$(run "$STARTUP2")"
case "$out" in *'HANDOFF OFFER'*) fail "no offer when no handoff names the current branch. Got: $out" ;; esac
case "$out" in *'SESSION RECOVERY: Found recent spec'*) : ;; *) fail "the recovery line must survive without an offer. Got: $out" ;; esac
out="$(run "$COMPACT2")"
case "$out" in *'Recent handoff'*) fail "compact must not re-inject handoffs for other branches. Got: $out" ;; esac
printf '  PASS  offer and compact handoff absent for another branch\n'

# Accepted during this session: no longer offered, still re-injected on compact.
git -C "$P2" symbolic-ref HEAD refs/heads/feat/ho-test
bash "$REPO_ROOT/scripts/handoff-state.sh" accept "$P2/docs/handoffs/mine.md"
touch -t 202601010000 docs/handoffs/mine.md
out="$(run "$STARTUP2")"
case "$out" in *'HANDOFF OFFER'*) fail "an accepted handoff must not be offered. Got: $out" ;; esac
out="$(run "$COMPACT2")"
case "$out" in *'Recent handoff: docs/handoffs/mine.md'*) : ;; *) fail "a handoff accepted this session must stay visible on compact. Got: $out" ;; esac
printf '  PASS  accepted handoff: no offer, still re-injected on compact\n'

# Accepted in an earlier session (accepted_at 2 days ago): compact omits it.
TWO_DAYS_AGO="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
sed "s/^accepted_at: .*/accepted_at: $TWO_DAYS_AGO/" docs/handoffs/mine.md > "$WORK/mine.rewritten"
cat "$WORK/mine.rewritten" > docs/handoffs/mine.md
grep -q "^accepted_at: $TWO_DAYS_AGO\$" docs/handoffs/mine.md || fail "test setup: accepted_at not rewritten"
touch -t 202601010000 docs/handoffs/mine.md
out="$(run "$COMPACT2")"
case "$out" in *'mine.md'*) fail "a handoff accepted 2 days ago must not be re-injected on compact. Got: $out" ;; esac
case "$out" in *'"additionalContext"'*) : ;; *) fail "compact must still emit its context envelope. Got: $out" ;; esac
# (Positive control: the case just above, same note accepted now, is re-injected.)
printf '  PASS  handoff accepted 2 days ago: omitted on compact\n'

# --- 5. helper script absent → today's compact behaviour -------------------------
# A plugin copy without scripts/: the hook falls back to the newest-<24h pick
# (no branch filter) and offers nothing on startup.

mkdir -p "$WORK/plug"
cp -R "$REPO_ROOT/hooks" "$WORK/plug/hooks"
out="$(CLAUDE_PLUGIN_ROOT="$WORK/plug" CLAUDE_PROJECT_DIR="$P2" bash "$WORK/plug/hooks/session-start" <<<"$COMPACT2" 2>/dev/null || true)"
case "$out" in *'Recent handoff: docs/handoffs/other.md'*) : ;; *) fail "without the helper, compact must keep the plain newest-<24h pick. Got: $out" ;; esac
case "$out" in *'"additionalContext"'*) : ;; *) fail "fallback must still emit the additionalContext envelope. Got: $out" ;; esac
out="$(CLAUDE_PLUGIN_ROOT="$WORK/plug" CLAUDE_PROJECT_DIR="$P2" bash "$WORK/plug/hooks/session-start" <<<"$STARTUP2" 2>/dev/null || true)"
case "$out" in *'HANDOFF OFFER'*) fail "without the helper, startup must offer nothing. Got: $out" ;; esac
printf '  PASS  helper absent: compact keeps the newest-<24h pick, startup offers nothing\n'

# --- 6. helper present but failing → visible stderr line, then the fallback -----
# A plugin copy whose scripts/handoff-state.sh exits non-zero with a message.

mkdir -p "$WORK/plug2/scripts"
cp -R "$REPO_ROOT/hooks" "$WORK/plug2/hooks"
printf '#!/usr/bin/env bash\necho "boom: filter exploded" >&2\necho "second line" >&2\nexit 3\n' > "$WORK/plug2/scripts/handoff-state.sh"
chmod +x "$WORK/plug2/scripts/handoff-state.sh"
out="$(CLAUDE_PLUGIN_ROOT="$WORK/plug2" CLAUDE_PROJECT_DIR="$P2" bash "$WORK/plug2/hooks/session-start" <<<"$COMPACT2" 2>"$WORK/fail.err" || true)"
err="$(cat "$WORK/fail.err")"
case "$err" in *'[mtk-hook:session-start] handoff: boom: filter exploded'*) : ;;
  *) fail "a failing helper's first stderr line must be surfaced. Got stderr: $err" ;; esac
case "$err" in *'[mtk-hook:session-start] handoff filter unavailable (helper exit 3)'*) : ;;
  *) fail "a failing helper must say it is unavailable, with its exit code. Got stderr: $err" ;; esac
case "$err" in *'second line'*) fail "only the helper's first stderr line is surfaced. Got stderr: $err" ;; esac
case "$out" in *'Recent handoff: docs/handoffs/other.md'*) : ;; *) fail "a failing helper must fall back to the newest-<24h pick. Got: $out" ;; esac
# The startup path captures the helper's stderr the same way.
out="$(CLAUDE_PLUGIN_ROOT="$WORK/plug2" CLAUDE_PROJECT_DIR="$P2" bash "$WORK/plug2/hooks/session-start" <<<"$STARTUP2" 2>"$WORK/fail-startup.err" || true)"
err="$(cat "$WORK/fail-startup.err")"
case "$err" in *'[mtk-hook:session-start] handoff: boom: filter exploded'*) : ;;
  *) fail "startup: a failing helper's first stderr line must be surfaced. Got stderr: $err" ;; esac
case "$err" in *'[mtk-hook:session-start] handoff filter unavailable (helper exit 3)'*) : ;;
  *) fail "startup: a failing helper must say it is unavailable. Got stderr: $err" ;; esac
case "$out" in *'HANDOFF OFFER'*) fail "startup: a failing helper must yield no offer. Got: $out" ;; esac
case "$out" in *'"additionalContext"'*) : ;; *) fail "startup: a failing helper must not cost the context envelope. Got: $out" ;; esac
# Negative control: the working helper, with nothing to say, prints neither line.
CLAUDE_PROJECT_DIR="$P2" bash "$HOOK" <<<"$COMPACT2" >/dev/null 2>"$WORK/ok.err" || true
case "$(cat "$WORK/ok.err")" in *'[mtk-hook:session-start] handoff'*) fail "a quiet working helper must surface no handoff line. Got: $(cat "$WORK/ok.err")" ;; esac
CLAUDE_PROJECT_DIR="$P2" bash "$HOOK" <<<"$STARTUP2" >/dev/null 2>"$WORK/ok-startup.err" || true
case "$(cat "$WORK/ok-startup.err")" in *'[mtk-hook:session-start] handoff'*) fail "startup: a quiet working helper must surface no handoff line. Got: $(cat "$WORK/ok-startup.err")" ;; esac
printf '  PASS  failing helper: stderr names the failure on compact and startup, compact falls back\n'

# --- 7. legacy / branchless notes and detached HEAD (helper present) -------------
# P3 on feat/legacy. A legacy note (no frontmatter) and a frontmatter note
# without `branch:` are never offered on startup; the positive control is a
# note tagged with this branch, which is.

P3="$WORK/p3"
mkdir -p "$P3/docs/handoffs"
git -C "$P3" init -q
git -C "$P3" symbolic-ref HEAD refs/heads/feat/legacy
cd "$P3"
COMPACT3='{"hook_event_name":"SessionStart","source":"compact","session_id":"s-compact3"}'
STARTUP3='{"hook_event_name":"SessionStart","source":"startup","session_id":"s-startup3"}'
run3() { CLAUDE_PROJECT_DIR="$P3" bash "$HOOK" <<<"$1" 2>/dev/null || true; }

printf '# legacy handoff\n' > docs/handoffs/legacy.md
out="$(run3 "$STARTUP3")"
case "$out" in *'HANDOFF OFFER'*) fail "startup must not offer a legacy (branch-unknown) note. Got: $out" ;; esac
case "$out" in *'"additionalContext"'*) : ;; *) fail "startup must still emit its context. Got: $out" ;; esac
out="$(run3 "$COMPACT3")"
case "$out" in *'Recent handoff: docs/handoffs/legacy.md'*) : ;; *) fail "compact must re-inject a fresh legacy note when the helper is present. Got: $out" ;; esac
printf '  PASS  legacy note: no startup offer, re-injected on compact\n'

printf -- '---\nstate: open\nworktree: %s\nexpires: 2099-12-31\n---\n# handoff\n' "$P3" > docs/handoffs/nobranch.md
out="$(run3 "$STARTUP3")"
case "$out" in *'HANDOFF OFFER'*) fail "startup must not offer a frontmatter note without branch:. Got: $out" ;; esac
printf -- '---\nstate: open\nbranch: feat/legacy\nworktree: %s\nexpires: 2099-12-31\n---\n# handoff\n' "$P3" > docs/handoffs/tagged.md
out="$(run3 "$STARTUP3")"
case "$out" in *'HANDOFF OFFER: open handoff for this branch at docs/handoffs/tagged.md'*) : ;;
  *) fail "positive control: a note tagged with this branch must be offered. Got: $out" ;; esac
case "$out" in *'nobranch.md'*|*'legacy.md'*) fail "the offer must name the tagged note only. Got: $out" ;; esac
printf '  PASS  branchless frontmatter note: no offer; tagged note (control): offered\n'

# Detached HEAD. The branch-tagged note is made the newest so an unfiltered pick
# would choose it; the branchless note is expired so the legacy note is the only
# branch-unknown candidate left.
bash "$REPO_ROOT/scripts/handoff-state.sh" expire "$P3/docs/handoffs/nobranch.md"
touch -t 209901010000 docs/handoffs/tagged.md
out="$(run3 "$COMPACT3")"
case "$out" in *'Recent handoff: docs/handoffs/tagged.md'*) : ;;
  *) fail "control: on its own branch compact picks the newest tagged note. Got: $out" ;; esac
EMPTY_TREE="$(git -C "$P3" hash-object -t tree -w /dev/null)"
HEAD_SHA="$(git -C "$P3" -c user.name=t -c user.email=t@example.invalid commit-tree "$EMPTY_TREE" -m init)"
git -C "$P3" update-ref --no-deref HEAD "$HEAD_SHA"
git -C "$P3" symbolic-ref -q HEAD >/dev/null 2>&1 && fail "test setup: HEAD must be detached"
out="$(run3 "$COMPACT3")"
case "$out" in *'Recent handoff: docs/handoffs/legacy.md'*) : ;; *) fail "detached HEAD: compact must still show the legacy note. Got: $out" ;; esac
case "$out" in *'tagged.md'*) fail "detached HEAD: a branch-tagged note must be hidden. Got: $out" ;; esac
printf '  PASS  detached HEAD: legacy note shown, branch-tagged note hidden\n'

# --- 8. liveness: startup ticks <stamp dir>/.sessions, other sources do not ------

SEEN_DIR="$(CLAUDE_PROJECT_DIR="$P3" bash -c 'source "$1"; mtk_hook_seen_dir' _ "$REPO_ROOT/hooks/lib/hook-io.sh")" \
  || fail "test setup: no stamp dir for $P3"
sessions() { local n=""; [ -f "$SEEN_DIR/.sessions" ] && IFS= read -r n < "$SEEN_DIR/.sessions"; printf '%s' "${n:-0}"; }
before="$(sessions)"
run3 "$STARTUP3" >/dev/null
after_startup="$(sessions)"
[ "$after_startup" = "$((before + 1))" ] || fail "startup must add one to .sessions (before=$before after=$after_startup)"
run3 "$COMPACT3" >/dev/null
run3 '{"hook_event_name":"SessionStart","source":"resume","session_id":"s-resume3"}' >/dev/null
run3 '{"hook_event_name":"SessionStart","source":"clear","session_id":"s-clear3"}' >/dev/null
[ "$(sessions)" = "$after_startup" ] || fail "compact/resume/clear must not tick .sessions (expected $after_startup, got $(sessions))"
[ -f "$SEEN_DIR/session-start" ] || fail "session-start must still stamp itself in $SEEN_DIR"
printf '  PASS  liveness tick: startup +1, compact/resume/clear unchanged\n'

# --- 9. a succeeding helper's warning still reaches stderr; branchless 24h bound --
# P5 on feat/p5. A note with a typo'd state makes the helper warn but succeed:
# both paths surface the warning. A frontmatter note without `branch:` counts on
# compact only while it is < 24h old, and is never offered on startup.

P5="$WORK/p5"
mkdir -p "$P5/docs/handoffs"
git -C "$P5" init -q
git -C "$P5" symbolic-ref HEAD refs/heads/feat/p5
cd "$P5"
COMPACT5='{"hook_event_name":"SessionStart","source":"compact","session_id":"s-compact5"}'
STARTUP5='{"hook_event_name":"SessionStart","source":"startup","session_id":"s-startup5"}'
P5_REAL="$(cd "$P5" && pwd -P)"

printf -- '---\nstate: opne\nbranch: feat/p5\nexpires: 2099-12-31\n---\n# typo\n' > docs/handoffs/typo.md
for payload in "$COMPACT5" "$STARTUP5"; do
  CLAUDE_PROJECT_DIR="$P5" bash "$HOOK" <<<"$payload" >"$WORK/p5.out" 2>"$WORK/p5.err" || true
  err="$(cat "$WORK/p5.err")"
  case "$err" in *"[mtk-hook:session-start] handoff: handoff-state: "*"/docs/handoffs/typo.md: unknown state 'opne', ignored"*) : ;;
    *) fail "a succeeding helper's warning must be surfaced (payload $payload). Got stderr: $err" ;; esac
  case "$err" in *'handoff filter unavailable'*) fail "a succeeding helper must not be reported unavailable. Got stderr: $err" ;; esac
  case "$(cat "$WORK/p5.out")" in *'typo.md'*) fail "an unknown-state note must not be picked. Got: $(cat "$WORK/p5.out")" ;; esac
done
case "$err" in *"$P5_REAL"*|*"$P5"*) : ;; *) fail "the surfaced warning names the note's path. Got stderr: $err" ;; esac
printf '  PASS  helper warning surfaced on compact and startup without failing the filter\n'

printf -- '---\nstate: open\nexpires: 2099-12-31\n---\n# no branch\n' > docs/handoffs/nobranch.md
touch -t 202001010000 docs/handoffs/nobranch.md
out="$(CLAUDE_PROJECT_DIR="$P5" bash "$HOOK" <<<"$COMPACT5" 2>/dev/null || true)"
case "$out" in *'nobranch.md'*) fail "compact must not re-inject a branchless frontmatter note older than 24h. Got: $out" ;; esac
touch docs/handoffs/nobranch.md
out="$(CLAUDE_PROJECT_DIR="$P5" bash "$HOOK" <<<"$COMPACT5" 2>/dev/null || true)"
case "$out" in *'Recent handoff: docs/handoffs/nobranch.md'*) : ;; *) fail "control: a fresh branchless note is re-injected on compact. Got: $out" ;; esac
out="$(CLAUDE_PROJECT_DIR="$P5" bash "$HOOK" <<<"$STARTUP5" 2>/dev/null || true)"
case "$out" in *'HANDOFF OFFER'*) fail "startup must never offer a branchless note. Got: $out" ;; esac
printf '  PASS  branchless frontmatter note: compact only while < 24h, never offered\n'

# --- 10. COMPACTION OFFER (archives from hooks/compact-archive.sh) -------------------
# P6 on feat/p6 with no handoffs: startup/clear offer the newest same-branch
# archive < 24h old; never for another branch, an older archive, a handoff-offer
# session or the compact source (whose output stays unchanged).

P6="$WORK/p6"
mkdir -p "$P6/docs/handoffs" "$P6/.mtk/sessions/s-a" "$P6/.mtk/sessions/s-b"
git -C "$P6" init -q
git -C "$P6" symbolic-ref HEAD refs/heads/feat/p6
cd "$P6"
STARTUP6='{"hook_event_name":"SessionStart","source":"startup","session_id":"s-startup6"}'
CLEAR6='{"hook_event_name":"SessionStart","source":"clear","session_id":"s-clear6"}'
COMPACT6='{"hook_event_name":"SessionStart","source":"compact","session_id":"s-compact6"}'
RESUME6='{"hook_event_name":"SessionStart","source":"resume","session_id":"s-resume6"}'
run6() { CLAUDE_PROJECT_DIR="$P6" bash "$HOOK" <<<"$1" 2>/dev/null || true; }
archive() { # $1 file  $2 branch
  printf -- '---\nsession: x\nbranch: %s\ntrigger: auto\ncreated: 2026-10-20T10:00:00Z\nworkflow: -\n---\nbody\n' "$2" > "$1"
}
OFFER_RE='COMPACTION OFFER: summary of an earlier compacted session on this branch at .mtk/sessions/s-b/compact-new.md ('

archive .mtk/sessions/s-a/compact-old.md feat/p6
touch -t 202001010000 .mtk/sessions/s-a/compact-old.md
out="$(run6 "$STARTUP6")"
case "$out" in *'COMPACTION OFFER'*) fail "an archive older than 24h must not be offered. Got: $out" ;; esac
archive .mtk/sessions/s-b/compact-other.md feat/elsewhere
out="$(run6 "$STARTUP6")"
case "$out" in *'COMPACTION OFFER'*) fail "another branch's archive must not be offered. Got: $out" ;; esac
printf '  PASS  no compaction offer for a >24h or other-branch archive\n'

archive .mtk/sessions/s-b/compact-new.md feat/p6
mkdir -p .mtk/sessions/s-c
archive .mtk/sessions/s-c/compact-mid.md feat/p6
touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)" .mtk/sessions/s-c/compact-mid.md
for payload in "$STARTUP6" "$CLEAR6"; do
  out="$(run6 "$payload")"
  case "$out" in *"$OFFER_RE"*'a historical snapshot; read it only if you are picking that work up.'*) : ;;
    *) fail "startup/clear must offer the same-branch recent archive. Got: $out" ;; esac
  [ "$(grep -o 'COMPACTION OFFER:' <<<"$out" | wc -l | tr -d ' ')" = "1" ] || fail "exactly one compaction offer line. Got: $out"
  case "$out" in *'compact-old.md'*|*'compact-other.md'*|*'compact-mid.md'*) fail "the offer must name the newest same-branch archive. Got: $out" ;; esac
done
printf '  PASS  startup and clear offer the newest same-branch archive (one line)\n'

out="$(run6 "$RESUME6")"
case "$out" in *'COMPACTION OFFER'*) fail "resume must not offer an archive. Got: $out" ;; esac
printf '  PASS  no compaction offer on resume\n'

# compact source stays byte-identical with and without an archive present.
with_archive="$(run6 "$COMPACT6")"
mv .mtk "$WORK/mtk-aside"
without_archive="$(run6 "$COMPACT6")"
mv "$WORK/mtk-aside" .mtk
[ "$with_archive" = "$without_archive" ] || fail "compact output must not depend on archives. With: $with_archive Without: $without_archive"
case "$with_archive" in *'COMPACTION OFFER'*) fail "compact must not carry the offer. Got: $with_archive" ;; esac
printf '  PASS  compact output unchanged by archives\n'

# A handoff offer takes precedence: no compaction offer alongside it.
printf -- '---\nstate: open\nbranch: feat/p6\nworktree: %s\nexpires: 2099-12-31\n---\n# handoff\n' "$P6" > docs/handoffs/p6.md
out="$(run6 "$STARTUP6")"
case "$out" in *'HANDOFF OFFER: open handoff for this branch at docs/handoffs/p6.md'*) : ;; *) fail "control: handoff offer expected. Got: $out" ;; esac
case "$out" in *'COMPACTION OFFER'*) fail "no compaction offer when a handoff offer was emitted. Got: $out" ;; esac
out="$(run6 "$CLEAR6")"
case "$out" in *'COMPACTION OFFER'*) fail "clear: no compaction offer beside a handoff offer. Got: $out" ;; esac
printf '  PASS  handoff offer suppresses the compaction offer\n'

printf '\nAll session-start compact framing checks passed.\n'
