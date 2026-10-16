#!/usr/bin/env bash
set -euo pipefail

# scripts/handoff-state.sh — handoff notes are branch-scoped and carry a
# lifecycle state (open → accepted / expired). `list --open` is what
# session-start reads: it must hide other branches, expired and past-`expires`
# notes, show accepted notes only when accepted after --include-accepted-since,
# bound branchless notes (legacy, or frontmatter without branch:) to 24h, report
# and skip a typo'd state, and sort newest first. `accept` / `expire` must
# rewrite only the state lines, whatever the note's shape, and keep its mode.
#
# Every case runs in a mktemp -d sandbox (TMPDIR and --dir point into it).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HS="$REPO_ROOT/scripts/handoff-state.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/tmp" "$SANDBOX/proj/docs/handoffs"
export TMPDIR="$SANDBOX/tmp"
export CLAUDE_PROJECT_DIR="$SANDBOX/proj"
D="$SANDBOX/proj/docs/handoffs"
cd "$SANDBOX/proj"

fails=0
T=$'\t'
pass() { printf '  PASS  %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

# expect_has LABEL NEEDLE HAYSTACK / expect_lacks LABEL NEEDLE HAYSTACK
expect_has() { case "$3" in *"$2"*) pass "$1" ;; *) bad "$1 — expected '$2' in: $3" ;; esac; }
expect_lacks() { case "$3" in *"$2"*) bad "$1 — did not expect '$2' in: $3" ;; *) pass "$1" ;; esac; }
expect_eq() { if [ "$2" = "$3" ]; then pass "$1"; else bad "$1 — expected '$2', got '$3'"; fi; }

# note FILE STATE BRANCH EXPIRES [ACCEPTED_AT] [TOUCH_STAMP]
note() {
  local f="$D/$1"
  {
    printf -- '---\n'
    printf 'state: %s            # open | accepted | expired\n' "$2"
    [ -n "$3" ] && printf 'branch: %s\n' "$3"
    printf 'worktree: /somewhere/proj\n'
    [ -n "$4" ] && printf 'expires: %s\n' "$4"
    [ -n "${5:-}" ] && printf 'accepted_at: %s\n' "$5"
    printf -- '---\n# Session Handoff — %s\n\n## Branch\n%s\n' "$1" "$3"
  } >"$f"
  [ -z "${6:-}" ] || touch -t "$6" "$f"
}

note mine-old.md open feat/x 2099-12-31 "" 202601010000
note mine-new.md open feat/x 2099-12-31 "" 202601030000
note other.md open feat/y 2099-12-31 "" 202601020000
note gone.md expired feat/x 2099-12-31 "" 202601020000
note stale.md open feat/x 2000-01-01 "" 202601020000
note taken.md accepted feat/x 2099-12-31 2026-06-01T00:00:00Z 202601020000
printf '# legacy fresh\n' >"$D/legacy-fresh.md"
printf '# legacy old\n' >"$D/legacy-old.md"
touch -t 202001010000 "$D/legacy-old.md"

# --- list --open --branch -----------------------------------------------------

out="$(bash "$HS" list --open --branch feat/x --dir "$D")"
expect_has "open + matching branch listed" "$D/mine-old.md${T}open${T}feat/x${T}2026-01-01" "$out"
expect_lacks "other branch hidden" "other.md" "$out"
expect_lacks "state expired hidden" "gone.md" "$out"
expect_lacks "past expires hidden" "stale.md" "$out"
expect_lacks "accepted hidden without --include-accepted-since" "taken.md" "$out"
expect_has "legacy < 24h listed, branch unknown" "$D/legacy-fresh.md${T}open${T}-${T}" "$out"
expect_lacks "legacy > 24h hidden" "legacy-old.md" "$out"
order="$(awk -F'\t' '{ n = split($1, p, "/"); printf "%s ", p[n] }' <<<"$out")"
expect_eq "newest mtime first" "legacy-fresh.md mine-new.md mine-old.md " "$order"

out="$(bash "$HS" list --open --branch feat/x --include-accepted-since 2026-05-01T00:00:00Z --dir "$D")"
expect_has "accepted shown when accepted after --include-accepted-since" "taken.md${T}accepted${T}feat/x" "$out"
out="$(bash "$HS" list --open --branch feat/x --include-accepted-since 2026-07-01T00:00:00Z --dir "$D")"
expect_lacks "accepted hidden when accepted before --include-accepted-since" "taken.md" "$out"

out="$(bash "$HS" list --open --branch feat/y --dir "$D")"
expect_has "other branch listed under its own filter" "other.md" "$out"
expect_lacks "feat/x note hidden under feat/y" "mine-new.md" "$out"

# Default directory is <project root>/docs/handoffs (CLAUDE_PROJECT_DIR).
out="$(bash "$HS" list --open --branch feat/x)"
expect_has "default dir anchored to the project root" "mine-new.md" "$out"
# ...also when the cwd is elsewhere (not a git repo, no docs/handoffs there).
mkdir -p "$SANDBOX/elsewhere"
out="$(cd "$SANDBOX/elsewhere" && bash "$HS" list --open --branch feat/x)"
expect_has "default dir anchored to CLAUDE_PROJECT_DIR from another cwd" "$D/mine-new.md${T}open${T}feat/x" "$out"

out="$(bash "$HS" list --open --dir "$SANDBOX/nope")"
expect_eq "missing directory lists nothing" "" "$out"

# --- malformed expires: that one note counts as open, says so, list goes on ------
# 2026-13-45 matches the bare-date shape but is not a date (strptime raises);
# "next week" fails the ISO parse. Neither may abort the listing.

D2="$SANDBOX/bad"
mkdir -p "$D2"
bad_note() { # $1 file  $2 expires  [$3 touch stamp]
  printf -- '---\nstate: open\nbranch: feat/x\nexpires: %s\n---\n# handoff\n' "$2" >"$D2/$1"
  [ -z "${3:-}" ] || touch -t "$3" "$D2/$1"
}
bad_note baddate.md 2026-13-45 202601010000
bad_note badiso.md "next week" 202601020000
bad_note good.md 2099-12-31 202601030000
bad_note past.md 2000-01-01 202601040000
rc=0
out="$(bash "$HS" list --open --branch feat/x --dir "$D2" 2>"$SANDBOX/bad.err")" || rc=$?
err="$(cat "$SANDBOX/bad.err")"
expect_eq "malformed expires does not abort list" "0" "$rc"
expect_has "bad bare date listed as open" "$D2/baddate.md${T}open${T}feat/x" "$out"
expect_has "bad ISO value listed as open" "$D2/badiso.md${T}open${T}feat/x" "$out"
expect_has "good note still listed" "good.md" "$out"
expect_lacks "past expires still hidden beside a bad note" "past.md" "$out"
expect_has "stderr names the bad bare date" "handoff-state: $D2/baddate.md: unparseable expires '2026-13-45', treated as open" "$err"
expect_has "stderr names the bad ISO value" "handoff-state: $D2/badiso.md: unparseable expires 'next week', treated as open" "$err"
expect_eq "one stderr line per bad note" "2" "$(grep -c 'unparseable expires' "$SANDBOX/bad.err" || true)"
# Negative control: a clean directory prints nothing on stderr.
bash "$HS" list --open --branch feat/x --dir "$D" >/dev/null 2>"$SANDBOX/clean.err"
expect_eq "no stderr when every expires parses" "" "$(cat "$SANDBOX/clean.err")"

# --- a frontmatter note without branch: is bounded to 24h like a legacy note ----

D3="$SANDBOX/nobranch"
mkdir -p "$D3"
printf -- '---\nstate: open\nexpires: 2099-12-31\n---\n# no branch, fresh\n' >"$D3/nb-fresh.md"
printf -- '---\nstate: open\nexpires: 2099-12-31\n---\n# no branch, old\n' >"$D3/nb-old.md"
touch -t 202001010000 "$D3/nb-old.md"
out="$(bash "$HS" list --open --branch feat/x --dir "$D3")"
expect_has "branchless frontmatter note < 24h listed, branch unknown" "$D3/nb-fresh.md${T}open${T}-${T}" "$out"
expect_lacks "branchless frontmatter note > 24h hidden under --open" "nb-old.md" "$out"
out="$(bash "$HS" list --dir "$D3")"
expect_has "the 24h bound is an --open filter only" "nb-old.md" "$out"

# --- a state: typo is reported and the note skipped ------------------------------

printf -- '---\nstate: opne\nbranch: feat/x\nexpires: 2099-12-31\n---\n# typo\n' >"$D3/typo.md"
rc=0
out="$(bash "$HS" list --open --branch feat/x --dir "$D3" 2>"$SANDBOX/typo.err")" || rc=$?
expect_eq "unknown state does not abort list" "0" "$rc"
expect_lacks "unknown-state note not listed" "typo.md" "$out"
expect_has "other notes still listed beside an unknown state" "nb-fresh.md" "$out"
expect_has "stderr names the unknown state" "handoff-state: $D3/typo.md: unknown state 'opne', ignored" "$(cat "$SANDBOX/typo.err")"
out="$(bash "$HS" list --dir "$D3" 2>"$SANDBOX/typo2.err")"
expect_lacks "unknown-state note skipped without --open too" "typo.md" "$out"
expect_has "stderr names the unknown state without --open" "unknown state 'opne', ignored" "$(cat "$SANDBOX/typo2.err")"

# --- a bare-date expires lasts through that whole UTC day -----------------------

D4="$SANDBOX/dates"
mkdir -p "$D4"
TODAY="$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"))')"
YESTERDAY="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=1)).strftime("%Y-%m-%d"))')"
printf -- '---\nstate: open\nbranch: feat/x\nexpires: %s\n---\n' "$TODAY" >"$D4/today.md"
printf -- '---\nstate: open\nbranch: feat/x\nexpires: %s\n---\n' "$YESTERDAY" >"$D4/yesterday.md"
out="$(bash "$HS" list --open --branch feat/x --dir "$D4")"
expect_has "expires = today (UTC) still listed" "$D4/today.md${T}open" "$out"
expect_lacks "expires = yesterday (UTC) hidden" "yesterday.md" "$out"

# --- note shapes: quoted value, CRLF, unterminated block, key casing, file mode --

D5="$SANDBOX/shapes"
mkdir -p "$D5"
printf -- '---\nstate: open\nbranch: "feat/q"\nexpires: 2099-12-31\n---\n# quoted\n' >"$D5/quoted.md"
printf -- '---\r\nstate: open\r\nbranch: feat/q\r\nexpires: 2099-12-31\r\n---\r\n# crlf\r\nbody\r\n' >"$D5/crlf.md"
# No closing ---: must NOT be read as frontmatter (else: expired, other branch, hidden).
printf -- '---\nstate: expired\nbranch: feat/other\n# unterminated body\n' >"$D5/unterm.md"
printf -- '---\nState: Open\nBranch: feat/q\nexpires: 2099-12-31\n---\n# casing\n' >"$D5/casing.md"
printf -- '---\nstate: open\nbranch: feat/q\nexpires: 2099-12-31\n---\n# mode\n' >"$D5/mode.md"
chmod 0750 "$D5/mode.md"

out="$(bash "$HS" list --open --branch feat/q --dir "$D5")"
expect_has "quoted branch value unquoted and matched" "$D5/quoted.md${T}open${T}feat/q${T}" "$out"
expect_has "CRLF note parsed" "$D5/crlf.md${T}open${T}feat/q${T}" "$out"
expect_has "unterminated block read as a legacy note" "$D5/unterm.md${T}open${T}-${T}" "$out"
expect_has "State:/Branch: keys and Open value match case-insensitively" "$D5/casing.md${T}open${T}feat/q${T}" "$out"
expect_has "0750 note listed" "$D5/mode.md${T}open${T}feat/q${T}" "$out"

# keep FILE OUT — every line except the state / accepted_at lines, bytes as-is.
keep() { grep -v -i -e '^state:' -e '^accepted_at:' "$1" >"$2" || true; }
mode_of() { ls -l "$1" | awk '{ print substr($1, 1, 10) }'; }
for f in quoted crlf casing mode; do
  cp "$D5/$f.md" "$SANDBOX/$f.orig"
  keep "$D5/$f.md" "$SANDBOX/$f.before"
  mode_before="$(mode_of "$D5/$f.md")"
  bash "$HS" accept "$D5/$f.md"
  keep "$D5/$f.md" "$SANDBOX/$f.after"
  if cmp -s "$SANDBOX/$f.before" "$SANDBOX/$f.after"; then pass "accept $f: every other byte kept"; else bad "accept $f: other bytes changed — $(od -c "$D5/$f.md")"; fi
  expect_eq "accept $f: exactly one state line" "1" "$(grep -c -i '^state:' "$D5/$f.md")"
  expect_eq "accept $f: file mode kept" "$mode_before" "$(mode_of "$D5/$f.md")"
done
expect_eq "0750 mode really was 0750" "-rwxr-x---" "$(mode_of "$D5/mode.md")"
expect_has "quoted: state rewritten" "state: accepted" "$(cat "$D5/quoted.md")"
expect_has "casing: the State: line itself is rewritten" "State: accepted" "$(cat "$D5/casing.md")"
expect_eq "CRLF: every line still ends CRLF" "$(wc -l <"$D5/crlf.md" | tr -d ' ')" "$(grep -c $'\r$' "$D5/crlf.md")"
if grep -Eq $'^accepted_at: [0-9T:-]+Z\r$' "$D5/crlf.md"; then pass "CRLF: accepted_at written with CRLF"; else bad "CRLF: accepted_at line — $(od -c "$D5/crlf.md")"; fi

cp "$D5/unterm.md" "$SANDBOX/unterm.orig"
bash "$HS" accept "$D5/unterm.md"
usize="$(wc -c <"$SANDBOX/unterm.orig" | tr -d ' ')"
if cmp -s <(tail -c "$usize" "$D5/unterm.md") "$SANDBOX/unterm.orig"; then
  pass "accept unterminated: original bytes kept as the body"
else
  bad "accept unterminated: original bytes changed — $(cat "$D5/unterm.md")"
fi
expect_eq "accept unterminated: new block on top" "---|state: accepted" "$(awk 'NR <= 2' "$D5/unterm.md" | paste -sd '|' -)"

out="$(bash "$HS" list --open --branch feat/q --dir "$D5")"
for f in quoted crlf casing mode unterm; do expect_lacks "accepted $f no longer open" "$f.md" "$out"; done
out="$(bash "$HS" list --open --branch feat/q --include-accepted-since 2000-01-01T00:00:00Z --dir "$D5")"
for f in quoted crlf casing mode; do expect_has "accepted $f listed as accepted" "$D5/$f.md${T}accepted${T}feat/q" "$out"; done

# --- accept / expire rewrite only the state lines -------------------------------

strip_state() { grep -v -e '^state:' -e '^accepted_at:' "$1" || true; }
before="$(strip_state "$D/mine-old.md")"
bash "$HS" accept "$D/mine-old.md"
after="$(strip_state "$D/mine-old.md")"
expect_eq "accept keeps every other line" "$before" "$after"
expect_has "accept sets state: accepted (comment kept)" "state: accepted            # open" "$(cat "$D/mine-old.md")"
if grep -Eq '^accepted_at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$D/mine-old.md"; then
  pass "accept adds accepted_at (ISO UTC)"
else
  bad "accept adds accepted_at (ISO UTC) — got: $(cat "$D/mine-old.md")"
fi
expect_eq "accept writes exactly one state line" "1" "$(grep -c '^state:' "$D/mine-old.md")"

bash "$HS" accept "$D/taken.md"
expect_eq "re-accept updates accepted_at in place" "1" "$(grep -c '^accepted_at:' "$D/taken.md")"
expect_lacks "re-accept replaces the old accepted_at" "2026-06-01T00:00:00Z" "$(cat "$D/taken.md")"

out="$(bash "$HS" list --open --branch feat/x --dir "$D")"
expect_lacks "accepted note no longer open" "mine-old.md" "$out"

before="$(grep -v '^state:' "$D/mine-new.md")"
bash "$HS" expire "$D/mine-new.md"
expect_eq "expire keeps every other line" "$before" "$(grep -v '^state:' "$D/mine-new.md")"
expect_has "expire sets state: expired" "state: expired" "$(cat "$D/mine-new.md")"
expect_lacks "expire adds no accepted_at" "accepted_at" "$(cat "$D/mine-new.md")"

bash "$HS" accept "$D/legacy-fresh.md"
expect_has "accept on a legacy note adds frontmatter" "---
state: accepted
accepted_at: " "$(cat "$D/legacy-fresh.md")"
expect_has "accept on a legacy note keeps its body" "# legacy fresh" "$(cat "$D/legacy-fresh.md")"

# Relative path resolves against the project root.
bash "$HS" expire docs/handoffs/other.md
expect_has "relative path resolves" "state: expired" "$(cat "$D/other.md")"

# --- errors ---------------------------------------------------------------------

rc=0; bash "$HS" accept "$D/missing.md" 2>/dev/null || rc=$?
expect_eq "accept on a missing file exits 1" "1" "$rc"
rc=0; bash "$HS" frobnicate 2>/dev/null || rc=$?
expect_eq "unknown command exits 2" "2" "$rc"
rc=0; bash "$HS" list --bogus 2>/dev/null || rc=$?
expect_eq "unknown list option exits 2" "2" "$rc"

if [ "$fails" -ne 0 ]; then
  printf '\n%s handoff-state check(s) failed.\n' "$fails" >&2
else
  printf '\nAll handoff-state checks passed.\n'
fi
exit "$fails"
