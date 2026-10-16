#!/usr/bin/env bash
set -euo pipefail

# lesson-mine-state.sh keeps `lessons mine` from re-reading mined transcript
# bytes (watermark), re-proposing ruled candidates (decision ledger) and
# trusting quotes the transcript does not contain (decoded-quote evidence).
#
# Every case runs in a mktemp -d sandbox: CLAUDE_PROJECT_DIR is a sandbox
# project, transcripts live in a sandbox projects dir passed through
# --projects-dir, and TMPDIR points into the sandbox, so neither the real repo's
# .mtk/ nor the engineer's ~/.claude is ever read or written.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LMS="$REPO_ROOT/scripts/lesson-mine-state.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/proj" "$SANDBOX/tmp" "$SANDBOX/transcripts" "$SANDBOX/config"
PROJ="$SANDBOX/proj"
TR="$SANDBOX/transcripts"
export CLAUDE_PROJECT_DIR="$PROJ"
export CLAUDE_CONFIG_DIR="$SANDBOX/config"
export TMPDIR="$SANDBOX/tmp"
cd "$PROJ"

fails=0

# Runs the script; echoes its exit code. Output goes to $SANDBOX/out.
run() {
  bash "$LMS" "$@" >"$SANDBOX/out" 2>"$SANDBOX/err" && echo 0 || echo $?
}

expect() {
  local label="$1" want="$2" got="$3"
  if [ "$got" != "$want" ]; then
    printf 'FAIL: %s — expected %s, got %s\n' "$label" "$want" "$got" >&2
    fails=$((fails + 1))
  else
    printf '  PASS  %s\n' "$label"
  fi
}

# Writes a transcript line per argument (each argument is the user message text),
# JSON-encoded by python3 so quotes, newlines and non-ASCII are escaped exactly as
# Claude Code escapes them (ensure_ascii: ć becomes ć).
write_transcript() { # $1 path, $2.. message texts
  python3 - "$@" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "a", encoding="utf-8") as fh:
    for text in sys.argv[2:]:
        fh.write(json.dumps({"type": "user", "message": {"role": "user", "content": text}}) + "\n")
PY
}

size_of() { wc -c <"$1" | tr -d ' '; }

# ================================ window =====================================

write_transcript "$TR/sess-a.jsonl" "first message"
write_transcript "$TR/sess-b.jsonl" "other session"
write_transcript "$TR/sess-old.jsonl" "ancient history"
touch -t 202001010000 "$TR/sess-old.jsonl"
printf 'not a transcript\n' >"$TR/notes.txt"

rc="$(run window --projects-dir "$TR")"
expect "window exits 0" 0 "$rc"
out="$(cat "$SANDBOX/out")"
case "$out" in *"sess-a	$TR/sess-a.jsonl	0"*) got=listed ;; *) got=missing ;; esac
expect "window: never-seen recent file listed from offset 0" listed "$got"
case "$out" in *sess-old*) got=listed ;; *) got=absent ;; esac
expect "window: never-seen file older than --days (default 7) skipped" absent "$got"
case "$out" in *notes*) got=listed ;; *) got=absent ;; esac
expect "window: only *.jsonl files are transcripts" absent "$got"

run window --projects-dir "$TR" --days 100000 >/dev/null
case "$(cat "$SANDBOX/out")" in *"sess-old	"*"	0"*) got=listed ;; *) got=missing ;; esac
expect "window: --days N widens the fallback for never-seen files" listed "$got"

expect "window: --days must be an integer" 2 "$(run window --projects-dir "$TR" --days x)"
expect "window: missing projects dir is an empty window" 0 "$(run window --projects-dir "$SANDBOX/nope")"
expect "window: missing projects dir prints nothing" "" "$(cat "$SANDBOX/out")"
case "$(cat "$SANDBOX/err")" in *"projects dir not found: $SANDBOX/nope"*) got=named ;; *) got="$(cat "$SANDBOX/err")" ;; esac
expect "window: missing projects dir is named on stderr" named "$got"
mkdir -p "$SANDBOX/empty-tr"
printf 'x\n' >"$SANDBOX/empty-tr/notes.txt"
expect "window: projects dir without transcripts is an empty window" 0 "$(run window --projects-dir "$SANDBOX/empty-tr")"
case "$(cat "$SANDBOX/err")" in *"no transcripts in projects dir: $SANDBOX/empty-tr"*) got=named ;; *) got="$(cat "$SANDBOX/err")" ;; esac
expect "window: projects dir without transcripts is named on stderr" named "$got"
run window --projects-dir "$TR" >/dev/null
expect "window: a dir with transcripts prints nothing on stderr" "" "$(cat "$SANDBOX/err")"

# Mine sess-a up to its current end; it must drop out of the window.
a_end="$(size_of "$TR/sess-a.jsonl")"
expect "advance: forward move accepted" 0 "$(run advance "$TR/sess-a.jsonl" "$a_end")"
[ -f "$PROJ/.mtk/lessons/mine-watermark.json" ] && got=yes || got=no
expect "advance: watermark stored under <project>/.mtk/lessons/" yes "$got"
run window --projects-dir "$TR" >/dev/null
case "$(cat "$SANDBOX/out")" in *sess-a*) got=listed ;; *) got=absent ;; esac
expect "window: fully mined file is not listed" absent "$got"
case "$(cat "$SANDBOX/out")" in *sess-b*) got=listed ;; *) got=missing ;; esac
expect "window: unmined file still listed" listed "$got"

# New content arrives in sess-a; window lists it from the watermark, not from 0.
write_transcript "$TR/sess-a.jsonl" "second message"
run window --projects-dir "$TR" >/dev/null
case "$(cat "$SANDBOX/out")" in *"sess-a	$TR/sess-a.jsonl	$a_end"*) got=from-watermark ;; *) got="$(cat "$SANDBOX/out")" ;; esac
expect "window: only content past the watermark is listed" from-watermark "$got"

# A watermarked file older than --days still lists when it has new bytes:
# the watermark governs once a file has been seen.
touch -t 202001010000 "$TR/sess-a.jsonl"
run window --projects-dir "$TR" >/dev/null
case "$(cat "$SANDBOX/out")" in *"sess-a	"*) got=listed ;; *) got=missing ;; esac
expect "window: seen file ignores the --days fallback" listed "$got"

# Default projects dir: ${CLAUDE_CONFIG_DIR}/projects/<root, non-alnum -> '-'>.
sanitized="$(python3 -c 'import re,sys; print(re.sub(r"[^A-Za-z0-9]", "-", sys.argv[1]))' "$PROJ")"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$sanitized"
write_transcript "$CLAUDE_CONFIG_DIR/projects/$sanitized/sess-default.jsonl" "hello"
run window >/dev/null
case "$(cat "$SANDBOX/out")" in *sess-default*) got=listed ;; *) got=missing ;; esac
expect "window: default dir is CLAUDE_CONFIG_DIR/projects/<sanitized root>" listed "$got"

# ================================ advance ====================================

expect "advance: backward move refused with exit 1" 1 "$(run advance "$TR/sess-a.jsonl" 1)"
case "$(cat "$SANDBOX/err")" in *backward*) got=explained ;; *) got=silent ;; esac
expect "advance: backward refusal says why" explained "$got"
mark="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sess-a.jsonl"])' "$PROJ/.mtk/lessons/mine-watermark.json")"
expect "advance: refused move leaves the watermark unchanged" "$a_end" "$mark"
expect "advance: same offset is a no-op success" 0 "$(run advance sess-a "$a_end")"
expect "advance: bare session id addresses the same watermark" 1 "$(run advance sess-a 0)"
expect "advance: non-integer offset is a usage error" 2 "$(run advance sess-a -5)"

# ================================== id =======================================

run id "Never call Foo.Bar() inside a loop" >/dev/null
id1="$(cat "$SANDBOX/out")"
run id "  never   CALL foo.bar()
 inside a LOOP " >/dev/null
id2="$(cat "$SANDBOX/out")"
expect "id: stable across case and whitespace" "$id1" "$id2"
case "$id1" in mine-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) got=shape-ok ;; *) got="$id1" ;; esac
expect "id: mine-<hash12> shape" shape-ok "$got"
run id "Never call Foo.Baz() inside a loop" >/dev/null
[ "$(cat "$SANDBOX/out")" != "$id1" ] && got=differs || got=same
expect "id: different rule text gives a different id" differs "$got"
expect "id: empty text is a usage error" 2 "$(run id "   ")"

# ============================ decide + filter =================================

run id "rule two" >/dev/null; id_two="$(cat "$SANDBOX/out")"
run id "rule three" >/dev/null; id_three="$(cat "$SANDBOX/out")"
expect "decide: rejected recorded" 0 "$(run decide "$id1" rejected "R4 generic advice")"
first_line="$(sed -n '3p' "$PROJ/.mtk/lessons/decisions.md")"
expect "decide: ledger line format" "- $id1 rejected $(date -u +%Y-%m-%d) — R4 generic advice" "$first_line"
expect "decide: accepted recorded" 0 "$(run decide "$id_two" accepted "A1 redirect
with reason")"
third_now="$(sed -n '3p' "$PROJ/.mtk/lessons/decisions.md")"
expect "decide: append-only (earlier line untouched)" "$first_line" "$third_now"
lines="$(grep -c '^- mine-' "$PROJ/.mtk/lessons/decisions.md")"
expect "decide: one line per decision" 2 "$lines"
last="$(awk 'END{print}' "$PROJ/.mtk/lessons/decisions.md")"
case "$last" in *"accepted"*"— A1 redirect with reason") got=one-line ;; *) got="$last" ;; esac
expect "decide: multi-line reason folded onto one ledger line" one-line "$got"
expect "decide: bad verdict refused" 2 "$(run decide "$id_three" maybe "x")"
expect "decide: non mine-id refused" 2 "$(run decide "L-2026-01-01-001" rejected "x")"
expect "decide: missing reason refused" 2 "$(run decide "$id_three" rejected)"

run filter "$id1" "$id_two" "$id_three" "$id_three" >/dev/null
expect "filter: drops decided ids (both verdicts), keeps undecided once" "$id_three" "$(cat "$SANDBOX/out")"
( export CLAUDE_PROJECT_DIR="$SANDBOX/fresh"; mkdir -p "$SANDBOX/fresh"; bash "$LMS" filter "$id1" >"$SANDBOX/out" )
expect "filter: no ledger yet passes every id through" "$id1" "$(cat "$SANDBOX/out")"

# =============================== evidence ====================================

Q=$'Don\'t say "always" here —\nuse the ćevapi path'
write_transcript "$TR/sess-ev.jsonl" "preamble" "before. $Q. after"
printf '{this line is not json\n' >>"$TR/sess-ev.jsonl"
python3 - "$TR/sess-ev.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "t1",
         "content": [{"type": "text", "text": "user rejected: wrong branch, use origin/main"}]}]}}) + "\n")
PY
grep -qF 'ć' "$TR/sess-ev.jsonl" && raw=raw-utf8 || raw=escaped
expect "evidence fixture: ć is JSON-escaped in the raw line" escaped "$raw"
grep -qF "$Q" "$TR/sess-ev.jsonl" && raw=grep-hit || raw=grep-miss
expect "evidence fixture: raw grep -F cannot find the quote" grep-miss "$raw"

expect "evidence: decoded quote with \", newline and ć matches (path)" 0 "$(run evidence "$TR/sess-ev.jsonl" "$Q")"
expect "evidence: session id resolves under --projects-dir" 0 "$(run evidence --projects-dir "$TR" sess-ev "$Q")"
expect "evidence: near-miss (c for ć) rejected" 1 "$(run evidence "$TR/sess-ev.jsonl" "${Q/ć/c}")"
expect "evidence: near-miss (space for newline) rejected" 1 "$(run evidence "$TR/sess-ev.jsonl" "${Q/$'\n'/ }")"
expect "evidence: nested tool_result text is searched" 0 "$(run evidence "$TR/sess-ev.jsonl" "wrong branch, use origin/main")"
expect "evidence: JSON keys are not message text" 1 "$(run evidence "$TR/sess-ev.jsonl" "tool_use_id")"
expect "evidence: missing transcript is exit 1" 1 "$(run evidence "$TR/nope.jsonl" "x")"
expect "evidence: empty quote is a usage error" 2 "$(run evidence "$TR/sess-ev.jsonl" "")"

# ============================ evidence-count ==================================

write_transcript "$TR/sess-c1.jsonl" "the build cache lies after a rebase"
write_transcript "$TR/sess-c2.jsonl" "again: the build cache lies after a rebase"
run evidence-count --projects-dir "$TR" sess-c1 "build cache lies" sess-c2 "cache lies after" >/dev/null
expect "evidence-count: two distinct sessions" 2 "$(cat "$SANDBOX/out")"
run evidence-count --projects-dir "$TR" sess-c1 "build cache lies" "$TR/sess-c1.jsonl" "after a rebase" >/dev/null
expect "evidence-count: same session twice (id and path) counts once" 1 "$(cat "$SANDBOX/out")"
run evidence-count --projects-dir "$TR" sess-c1 "build cache lies" sess-c2 "invented quote" >/dev/null
expect "evidence-count: failing quote does not count" 1 "$(cat "$SANDBOX/out")"
expect "evidence-count: odd argument count is a usage error" 2 "$(run evidence-count sess-c1)"
run evidence-count --projects-dir "$TR" sess-gone "build cache lies" sess-c1 "build cache lies" >/dev/null
expect "evidence-count: pair with a missing transcript does not count" 1 "$(cat "$SANDBOX/out")"
case "$(cat "$SANDBOX/err")" in *"transcript not found: sess-gone"*) got=named ;; *) got="$(cat "$SANDBOX/err")" ;; esac
expect "evidence-count: missing transcript is named on stderr" named "$got"

# ================================ watch ======================================
# Sweep 1 sees the A2 candidate in session wa only (below the floor): it is
# recorded with `watch`. Sweep 2 sees it in session wb and passes only wb's
# pair plus --id: the stored wa record, re-verified, makes it 2.

WATCH_STORE="$PROJ/.mtk/lessons/watching.jsonl"
run id "the build cache lies after a rebase" >/dev/null; wid="$(cat "$SANDBOX/out")"
write_transcript "$TR/sess-wa.jsonl" "sweep one: the build cache lies after a rebase"
write_transcript "$TR/sess-wb.jsonl" "sweep two: the build cache lies after a rebase"

run evidence-count --projects-dir "$TR" --id "$wid" sess-wb "build cache lies" >/dev/null
expect "evidence-count --id: no watching record yet → one session" 1 "$(cat "$SANDBOX/out")"

expect "watch: record accepted" 0 "$(run watch "$wid" "$TR/sess-wa.jsonl" "build cache lies")"
[ -f "$WATCH_STORE" ] && got=yes || got=no
expect "watch: stored under <project>/.mtk/lessons/watching.jsonl" yes "$got"
rec="$(python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).readline()); print(r["id"], r["session"], r["quote"], r["date"])' "$WATCH_STORE")"
expect "watch: record holds id, session id (not path), quote, date" "$wid sess-wa build cache lies $(date -u +%Y-%m-%d)" "$rec"

run evidence-count --projects-dir "$TR" --id "$wid" sess-wb "build cache lies" >/dev/null
expect "evidence-count --id: watch(sweep 1, wa) + pair(sweep 2, wb) → 2" 2 "$(cat "$SANDBOX/out")"
run evidence-count --projects-dir "$TR" --id "$wid" >/dev/null
expect "evidence-count --id with no pairs counts stored sessions" 1 "$(cat "$SANDBOX/out")"
run evidence-count --projects-dir "$TR" --id "$wid" sess-wa "after a rebase" >/dev/null
expect "evidence-count --id: stored session also passed as a pair counts once" 1 "$(cat "$SANDBOX/out")"
run evidence-count --projects-dir "$TR" sess-wb "build cache lies" >/dev/null
expect "evidence-count without --id ignores watching records" 1 "$(cat "$SANDBOX/out")"

expect "watch: duplicate id+session accepted" 0 "$(run watch "$wid" sess-wa "cache lies after")"
lines="$(grep -c "\"session\": \"sess-wa\"" "$WATCH_STORE" || true)"
expect "watch: duplicate id+session (path then id) stored once" 1 "$lines"
expect "watch: second session for the same id accepted" 0 "$(run watch "$wid" sess-wb "build cache lies")"
first="$(sed -n '1p' "$WATCH_STORE")"
case "$first" in *'"session": "sess-wa"'*) got=untouched ;; *) got="$first" ;; esac
expect "watch: append-only (earlier record untouched)" untouched "$got"
run evidence-count --projects-dir "$TR" --id "$wid" sess-wb "build cache lies" >/dev/null
expect "evidence-count --id: duplicate watch is not double-counted" 2 "$(cat "$SANDBOX/out")"

# A stored session whose transcript was deleted no longer counts.
run id "a rule watched in a deleted session" >/dev/null; gid="$(cat "$SANDBOX/out")"
write_transcript "$TR/sess-wgone.jsonl" "the build cache lies after a rebase"
expect "watch: record for a soon-deleted session accepted" 0 "$(run watch "$gid" sess-wgone "build cache lies")"
rm -f "$TR/sess-wgone.jsonl"
run evidence-count --projects-dir "$TR" --id "$gid" sess-wb "build cache lies" >/dev/null
expect "evidence-count --id: stored session with deleted transcript does not count" 1 "$(cat "$SANDBOX/out")"
case "$(cat "$SANDBOX/err")" in *"transcript not found: sess-wgone"*) got=named ;; *) got="$(cat "$SANDBOX/err")" ;; esac
expect "evidence-count --id: deleted stored transcript is named on stderr" named "$got"

# A stored quote is re-verified, not trusted.
run id "a rule with an invented stored quote" >/dev/null; fid="$(cat "$SANDBOX/out")"
expect "watch: record with an unverified quote accepted" 0 "$(run watch "$fid" sess-wa "a quote nobody typed")"
run evidence-count --projects-dir "$TR" --id "$fid" sess-wb "build cache lies" >/dev/null
expect "evidence-count --id: stored quote that fails the decoder does not count" 1 "$(cat "$SANDBOX/out")"

# Watching is not a decision.
run filter "$wid" >/dev/null
expect "filter: a watched id is still undecided" "$wid" "$(cat "$SANDBOX/out")"

printf 'not json\n' >>"$WATCH_STORE"
run evidence-count --projects-dir "$TR" --id "$wid" >/dev/null
expect "evidence-count --id: malformed watching line skipped, valid records still count" 2 "$(cat "$SANDBOX/out")"
case "$(cat "$SANDBOX/err")" in *"malformed, skipped"*) got=reported ;; *) got=silent ;; esac
expect "evidence-count --id: malformed watching line reported on stderr" reported "$got"

expect "watch: non mine-id refused" 2 "$(run watch "L-2026-01-01-001" sess-wa "x")"
expect "watch: empty quote refused" 2 "$(run watch "$wid" sess-wa "")"
expect "watch: wrong argument count refused" 2 "$(run watch "$wid" sess-wa)"
expect "evidence-count: --id without a valid id is a usage error" 2 "$(run evidence-count --id nope)"

# ================================ misc =======================================

expect "unknown subcommand is a usage error" 2 "$(run frobnicate)"
expect "no subcommand is a usage error" 2 "$(run)"

if [ "$fails" -ne 0 ]; then
  printf '\n%s assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf '\nlesson-mine-state: all assertions passed\n'
