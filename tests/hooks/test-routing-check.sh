#!/usr/bin/env bash
set -euo pipefail

# scripts/routing-check.sh — offline skill-description routing check.
#
# The script scores each skill's name and description with stemmed TF-IDF and
# cosine similarity, then checks:
#   - every skill pair against the warn and fail thresholds, unless the pair is
#     on the prompts file's allow-list;
#   - positive prompts: the expected skill is in the top k (ties count against it,
#     a score of 0 is a miss), and whether it ranks first;
#   - negative prompts: the named skill does not rank first (a tie counts as
#     first), and an owner, when named, scores strictly above it;
#   - name-free positives (no word of the skill's name in the prompt) and their
#     own rank-1 rate;
#   - per-skill coverage (min_positive_per_skill, min_name_free_per_skill, minus
#     the exempt list), with warnings for stale exempt entries and negatives that
#     cannot fail;
#   - both ratchets (--min-rank1 / min_rank1, --min-rank1-name-free /
#     min_rank1_name_free);
#   - the frontmatter reader: every supported description shape, and a failure
#     for each shape it does not read.
# Exit 0 pass, 1 check failed, 2 usage or environment error. The last sections
# check the wiring: run-fixtures.sh and validate-toolkit.sh fail when it fails.
#
# The fixture skills below are built so their similarities fall clearly inside
# one band each: an identical pair (fail), an overlapping pair (warn), an
# identical pair on the allow-list, and unrelated skills. The identical pairs use
# the same words in a different order, so their vectors match and a prompt ties.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RC_SCRIPT="$REPO_ROOT/scripts/routing-check.sh"
[ -f "$RC_SCRIPT" ] || { echo "FAIL: script not found: $RC_SCRIPT"; exit 1; }

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT

fails=0
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
pass() { echo "PASS: $1"; }

# run <args…> — sets OUT (stdout), ERR (stderr), RC (exit code).
run() {
  RC=0
  OUT="$(bash "$RC_SCRIPT" "$@" 2>"$SBX/err")" || RC=$?
  ERR="$(cat "$SBX/err")"
}

expect_rc() { # <label> <want>
  if [ "$RC" -eq "$2" ]; then pass "$1"; else fail "$1 — expected exit $2, got $RC (err: $ERR)"; fi
}

# jq-free JSON probe: py <python expression over `d`> — prints the value.
py() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1" <<<"$OUT"
}
expect_py() { # <label> <expression> <expected>
  local got
  got="$(py "$2" 2>&1)" || got="ERROR: $got"
  if [ "$got" = "$3" ]; then pass "$1"; else fail "$1 — expected [$3], got [$got]"; fi
}

mkskill() { # <dir> <name> <description>
  mkdir -p "$1/$2"
  printf -- '---\nname: %s\ndescription: %s\ntype: skill\n---\n\n# %s\n' "$2" "$3" "$2" > "$1/$2/SKILL.md"
}

# --- Fixture: skills with known similarity bands -------------------------------
SK="$SBX/skills"
mkskill "$SK" ledger-export        "Export ledger entries to CSV files for the auditors."
mkskill "$SK" export-ledger        "Export ledger entries to CSV files for the auditors."
mkskill "$SK" invoice-reminder     "Send overdue invoice reminders to customers by email."
mkskill "$SK" invoice-reminder-sms "Send overdue invoice reminders as SMS text messages to phones."
mkskill "$SK" archive-move         "Move the archive folder to the new layout."
mkskill "$SK" move-archive         "Move the archive folder to the new layout."
mkskill "$SK" rate-sync            "Sync foreign exchange rates nightly from the central bank feed."
mkskill "$SK" pdf-render           "Render monthly statements as PDF documents with the letterhead."
mkdir -p "$SK/notaskill"                     # no SKILL.md: not a skill
printf 'scratch\n' > "$SK/notaskill/README.md"

MAIN="$SBX/main.json"
cat > "$MAIN" <<'EOF'
{
  "id": "main",
  "fixture_type": "skill-routing",
  "description": "fixture",
  "allow_pairs": [
    { "skills": ["move-archive", "archive-move"], "reason": "legacy alias kept for one release" }
  ],
  "positive": [
    { "prompt": "sync the exchange rates from the bank", "skill": "rate-sync" },
    { "prompt": "render the monthly statement as a pdf", "skill": "pdf-render" },
    { "prompt": "render the monthly statement as a pdf", "skill": "rate-sync" },
    { "prompt": "export the ledger entries to csv", "skill": "ledger-export" }
  ],
  "negative": [
    { "prompt": "email customers about overdue invoices", "not": "invoice-reminder-sms", "owner": "invoice-reminder" },
    { "prompt": "send sms text messages about overdue invoices", "not": "invoice-reminder-sms" },
    { "prompt": "sync the exchange rates", "not": "pdf-render", "owner": "archive-move" },
    { "prompt": "render a pdf", "not": "rate-sync" }
  ]
}
EOF

# --- 1. --help ---------------------------------------------------------------------
run --help
expect_rc "--help exits 0" 0
case "$OUT" in
  *"lexical proxy"*"Exit codes"*) pass "--help states the method and the exit codes" ;;
  *) fail "--help must state the method and exit codes. out: $OUT" ;;
esac

# --- 2. collisions, positives, negatives (one mixed run, --json) ---------------------
run --skills-dir "$SK" --prompts "$MAIN" --json
expect_rc "a failing collision, miss and negative exit 1" 1
expect_py "json: status is fail"              'd["status"]' "fail"
expect_py "json: skills_total ignores a dir without SKILL.md" 'd["skills_total"]' "8"
expect_py "json: method names the lexical proxy" '"lexical proxy" in d["method"]' "True"
expect_py "json: default thresholds"          '(d["thresholds"]["warn"], d["thresholds"]["fail"], d["thresholds"]["top_k"])' "(0.5, 0.75, 3)"
expect_py "json: every pair is reported (8 skills -> 28 pairs)" 'len(d["pairs"])' "28"
pair_level() { printf 'next(p["level"] for p in d["pairs"] if p["skills"]==["%s","%s"])' "$1" "$2"; }
expect_py "collision: identical descriptions fail"     "$(pair_level export-ledger ledger-export)" "fail"
expect_py "collision: overlapping descriptions warn"   "$(pair_level invoice-reminder invoice-reminder-sms)" "warn"
expect_py "collision: allow-listed pair is allowed (either order in the file)" "$(pair_level archive-move move-archive)" "allowed"
expect_py "collision: allowed pair carries its reason" \
  'next(p["reason"] for p in d["pairs"] if p["level"]=="allowed")' "legacy alias kept for one release"
expect_py "collision: unrelated skills are ok"         "$(pair_level pdf-render rate-sync)" "ok"
expect_py "collision: pairs sorted by similarity, highest first" \
  'all(a["similarity"] >= b["similarity"] for a, b in zip(d["pairs"], d["pairs"][1:]))' "True"
expect_py "collision: the fail pair is listed under failures" \
  'any("export-ledger <-> ledger-export" in f for f in d["failures"])' "True"
expect_py "collision: the warn pair is a warning, not a failure" \
  '(any("invoice-reminder <-> invoice-reminder-sms" in w for w in d["warnings"]), any("invoice-reminder <->" in f for f in d["failures"]))' "(True, False)"

pos() { printf 'd["positive"][%s]["%s"]' "$1" "$2"; }
expect_py "positive hit: rate-sync ranks 1"              "($(pos 0 rank), $(pos 0 rank1), $(pos 0 pass))" "(1, True, True)"
expect_py "positive hit: pdf-render ranks 1"             "($(pos 1 rank), $(pos 1 pass))" "(1, True)"
expect_py "positive miss: a skill scoring 0 is unranked and fails" "($(pos 2 rank), $(pos 2 pass))" "(None, False)"
expect_py "positive tie: a tie counts against the expected skill (rank 2, still top-3)" \
  "($(pos 3 rank), $(pos 3 rank1), $(pos 3 pass))" "(2, False, True)"
expect_py "positive: top list has top_k entries"         'len(d["positive"][0]["top"])' "3"
expect_py "rank-1 counts"                                '(d["rank1"]["hits"], d["rank1"]["total"], d["rank1"]["rate"])' "(2, 4, 50.0)"
expect_py "top-k counts"                                 '(d["topk"]["k"], d["topk"]["hits"])' "(3, 3)"

neg() { printf 'd["negative"][%s]["pass"]' "$1"; }
expect_py "negative with owner: owner outranks the named skill" "$(neg 0)" "True"
expect_py "negative: the named skill ranking first fails"       "$(neg 1)" "False"
expect_py "negative with owner: owner that does not outrank fails" "$(neg 2)" "False"
expect_py "negative without owner: named skill not first passes"   "$(neg 3)" "True"
expect_py "negatives_passed"                                    'd["negatives_passed"]' "2"
expect_py "negative failure says the owner does not outrank" \
  'any("owner archive-move" in f and "does not outrank pdf-render" in f for f in d["failures"])' "True"

# --- 3. human and --quiet output -------------------------------------------------------
run --skills-dir "$SK" --prompts "$MAIN"
expect_rc "human report exits 1 on the same input" 1
case "$OUT" in
  *COLLISIONS*ALLOWED*POSITIVE*NEGATIVE*"FAIL: collision export-ledger <-> ledger-export"*"summary: FAIL"*) pass "human report has every section, the failure lines and the summary" ;;
  *) fail "human report is missing a section or line. out: $OUT" ;;
esac
case "$OUT" in
  *"WARN: collision invoice-reminder <-> invoice-reminder-sms"*) pass "human report prints the warn pair" ;;
  *) fail "human report must print the warn pair. out: $OUT" ;;
esac
run --skills-dir "$SK" --prompts "$MAIN" --quiet
case "$OUT" in
  *POSITIVE*|*COLLISIONS*) fail "--quiet must not print the full sections. out: $OUT" ;;
  *"summary: FAIL"*) pass "--quiet prints only the problems and the summary" ;;
  *) fail "--quiet must end with the summary. out: $OUT" ;;
esac

# --- 4. threshold flags override the file and the defaults ------------------------------
run --skills-dir "$SK" --prompts "$MAIN" --json --fail 0.6
expect_py "--fail 0.6 turns the overlapping pair into a failure" "$(pair_level invoice-reminder invoice-reminder-sms)" "fail"
expect_py "--fail 0.6 is reported in thresholds"                'd["thresholds"]["fail"]' "0.6"
run --skills-dir "$SK" --prompts "$MAIN" --json --warn 0.95 --fail 0.99
expect_py "--warn 0.95 clears the overlapping pair"            "$(pair_level invoice-reminder invoice-reminder-sms)" "ok"
expect_py "--fail 0.99 still fails the identical pair (1.0)"   "$(pair_level export-ledger ledger-export)" "fail"
run --skills-dir "$SK" --prompts "$MAIN" --json --top-k 1
expect_py "--top-k 1 fails the tie at rank 2"                  "$(pos 3 pass)" "False"

# --- 5. a clean catalog passes; the ratchet ---------------------------------------------
SKC="$SBX/clean"
mkskill "$SKC" archive-move        "Move the archive folder to the new layout."
mkskill "$SKC" move-archive        "Move the archive folder to the new layout."
mkskill "$SKC" invoice-reminder    "Send overdue invoice reminders to customers by email."
mkskill "$SKC" rate-sync           "Sync foreign exchange rates nightly from the central bank feed."
mkskill "$SKC" pdf-render          "Render monthly statements as PDF documents with the letterhead."
clean_prompts() { # <file> <extra top-level JSON members, may be empty>
  cat > "$1" <<EOF
{
  $2
  "allow_pairs": [ { "skills": ["archive-move", "move-archive"], "reason": "legacy alias" } ],
  "positive": [
    { "prompt": "sync the exchange rates from the bank", "skill": "rate-sync" },
    { "prompt": "render the monthly statement as a pdf", "skill": "pdf-render" },
    { "prompt": "email customers about overdue invoices", "skill": "invoice-reminder" },
    { "prompt": "move the archive folder to the new layout", "skill": "archive-move" }
  ],
  "negative": [
    { "prompt": "email the overdue invoice reminders", "not": "pdf-render", "owner": "invoice-reminder" }
  ]
}
EOF
}
CLEAN="$SBX/clean.json"
clean_prompts "$CLEAN" ""
run --skills-dir "$SKC" --prompts "$CLEAN"
expect_rc "a clean catalog exits 0" 0
case "$OUT" in
  *"summary: PASS - rank-1 3/4 (75.0%"*) pass "clean summary: rank-1 3/4 (the alias tie is rank 2)" ;;
  *) fail "expected 'summary: PASS - rank-1 3/4 (75.0%'. out: $OUT" ;;
esac
summary_line="$(printf '%s\n' "$OUT" | grep '^summary: ' || true)"
if LC_ALL=C grep -q "$(printf '[\200-\377]')" <<<"$summary_line"; then
  fail "the summary line must be ASCII. got: $summary_line"
else
  pass "the summary line is ASCII"
fi
run --skills-dir "$SKC" --prompts "$CLEAN" --min-rank1 75
expect_rc "ratchet: rate equal to --min-rank1 passes" 0
run --skills-dir "$SKC" --prompts "$CLEAN" --min-rank1 75.1 --json
expect_rc "ratchet: rate below --min-rank1 exits 1" 1
expect_py "ratchet: the failure names the ratchet" 'any(f.startswith("ratchet:") for f in d["failures"])' "True"
expect_py "ratchet: only the ratchet failed"       'len(d["failures"])' "1"

RATCHET="$SBX/ratchet.json"
clean_prompts "$RATCHET" '"thresholds": { "min_rank1": 80 },'
run --skills-dir "$SKC" --prompts "$RATCHET"
expect_rc "ratchet: the file's min_rank1 applies" 1
run --skills-dir "$SKC" --prompts "$RATCHET" --min-rank1 0
expect_rc "ratchet: --min-rank1 overrides the file" 0

# --- 6. coverage, exempt list, stale allow-list entry, unknown skill ---------------------
COV="$SBX/cov.json"
clean_prompts "$COV" '"thresholds": { "min_positive_per_skill": 1 },'
run --skills-dir "$SKC" --prompts "$COV" --json
expect_rc "coverage: a skill without positive prompts exits 1" 1
expect_py "coverage: the short skill is named" 'd["short"]' "['move-archive']"
expect_py "coverage: per-skill counts"         '(d["coverage"]["rate-sync"], d["coverage"]["move-archive"])' "(1, 0)"

EXEMPT="$SBX/exempt.json"
clean_prompts "$EXEMPT" '"thresholds": { "min_positive_per_skill": 1 }, "exempt": [ { "skill": "move-archive", "reason": "alias" } ],'
run --skills-dir "$SKC" --prompts "$EXEMPT" --json
expect_rc "coverage: an exempt skill needs no prompts" 0
expect_py "coverage: exempt reason is reported" 'd["exempt"]["move-archive"]' "alias"

STALE="$SBX/stale.json"
python3 - "$CLEAN" "$STALE" <<'PYX'
import json, sys
d = json.load(open(sys.argv[1]))
d["allow_pairs"].append({"skills": ["pdf-render", "rate-sync"], "reason": "not needed"})
json.dump(d, open(sys.argv[2], "w"))
PYX
run --skills-dir "$SKC" --prompts "$STALE" --json
expect_rc "a stale allow-list entry only warns" 0
expect_py "stale allow-list entry is named in warnings" \
  'any("pdf-render <-> rate-sync" in w and "can be removed" in w for w in d["warnings"])' "True"

UNKNOWN="$SBX/unknown.json"
python3 - "$CLEAN" "$UNKNOWN" <<'PYX'
import json, sys
d = json.load(open(sys.argv[1]))
d["positive"].append({"prompt": "anything", "skill": "no-such-skill"})
d["negative"].append({"prompt": "anything", "not": "rate-sync", "owner": "gone-skill"})
json.dump(d, open(sys.argv[2], "w"))
PYX
run --skills-dir "$SKC" --prompts "$UNKNOWN" --json
expect_rc "a case naming an unknown skill exits 1" 1
expect_py "unknown skills are named in failures" \
  '(any("no-such-skill" in f for f in d["failures"]), any("gone-skill" in f for f in d["failures"]))' "(True, True)"

STALE_EX="$SBX/stale-exempt.json"
clean_prompts "$STALE_EX" '"thresholds": { "min_positive_per_skill": 1 }, "exempt": [ { "skill": "rate-sync", "reason": "was an alias" }, { "skill": "move-archive", "reason": "alias" } ],'
run --skills-dir "$SKC" --prompts "$STALE_EX" --json
expect_rc "a stale exempt entry only warns" 0
expect_py "stale exempt entry is named in warnings" \
  'any(w.startswith("exempt entry rate-sync") and "can be removed" in w for w in d["warnings"])' "True"
expect_py "a needed exempt entry does not warn" \
  'any(w.startswith("exempt entry move-archive") for w in d["warnings"])' "False"

run --skills-dir "$SKC" --prompts "$CLEAN" --json
expect_py "a negative whose skill scores 0 warns that it cannot fail" \
  'any("email the overdue invoice reminders" in w and "pdf-render scores 0" in w for w in d["warnings"])' "True"

# --- 6b. a negative that ties with its 'not' skill fails --------------------------------------
TIE="$SBX/tie.json"
cat > "$TIE" <<'EOF'
{ "negative": [ { "prompt": "export the ledger entries to csv", "not": "ledger-export" } ] }
EOF
run --skills-dir "$SK" --prompts "$TIE" --json
expect_py "negative tie: the 'not' skill tying for first fails the case" 'd["negative"][0]["pass"]' "False"
expect_py "negative tie: both tied scores are equal" \
  'd["negative"][0]["top"][0]["score"] == d["negative"][0]["top"][1]["score"] == d["negative"][0]["not_score"]' "True"
expect_py "negative tie: the failure says it ranks first" \
  'any("ledger-export ranks first" in f for f in d["failures"])' "True"

# --- 6c. name-free prompts and their ratchet ---------------------------------------------------
NF="$SBX/namefree.json"
nf_prompts() { # <file> <extra top-level JSON members, may be empty>
  cat > "$1" <<EOF
{
  $2
  "allow_pairs": [ { "skills": ["archive-move", "move-archive"], "reason": "legacy alias" } ],
  "positive": [
    { "prompt": "sync the exchange rates from the bank", "skill": "rate-sync" },
    { "prompt": "pull the foreign exchange feed from the central bank", "skill": "rate-sync" },
    { "prompt": "print the statements with our letterhead", "skill": "pdf-render" },
    { "prompt": "send the customers a nudge by email", "skill": "invoice-reminder" },
    { "prompt": "email the customers about late payments", "skill": "pdf-render" }
  ]
}
EOF
}
nf_prompts "$NF" ""
run --skills-dir "$SKC" --prompts "$NF" --json
expect_rc "name-free: a run with name-free prompts exits 1 only for its miss" 1
expect_py "name-free: a prompt with a word of the skill's name is not name-free" "$(pos 0 name_free)" "False"
expect_py "name-free: a prompt with no word of the name is name-free" \
  "($(pos 1 name_free), $(pos 2 name_free), $(pos 3 name_free))" "(True, True, True)"
expect_py "name-free: rank-1 counts over name-free prompts only" \
  '(d["rank1_name_free"]["hits"], d["rank1_name_free"]["total"], d["rank1_name_free"]["rate"])' "(3, 4, 75.0)"
expect_py "name-free: per-skill counts" \
  '(d["coverage_name_free"]["rate-sync"], d["coverage_name_free"]["archive-move"])' "(1, 0)"
run --skills-dir "$SKC" --prompts "$NF"
case "$OUT" in
  *"name-free rank-1 3/4 (75.0%, min 0%)"*) pass "name-free: the summary reports the name-free rate" ;;
  *) fail "summary must report 'name-free rank-1 3/4 (75.0%, min 0%)'. out: $OUT" ;;
esac

NF_OK="$SBX/namefree-ok.json"
python3 - "$NF" "$NF_OK" <<'PYX'
import json, sys
d = json.load(open(sys.argv[1]))
d["positive"] = d["positive"][:4]
json.dump(d, open(sys.argv[2], "w"))
PYX
run --skills-dir "$SKC" --prompts "$NF_OK" --min-rank1-name-free 100
expect_rc "name-free ratchet: 3/3 meets 100%" 0
NF_LOW="$SBX/namefree-low.json"
python3 - "$NF" "$NF_LOW" <<'PYX'
import json, sys
d = json.load(open(sys.argv[1]))
d["positive"] = d["positive"][:4]
# Name-free, and tied with the identical alias, so rank 2: in the top 3, not first.
d["positive"].append({"prompt": "relocate the folder to the new layout", "skill": "archive-move"})
d["thresholds"] = {"min_rank1_name_free": 90}
json.dump(d, open(sys.argv[2], "w"))
PYX
run --skills-dir "$SKC" --prompts "$NF_LOW" --json
expect_py "name-free ratchet: the file's min_rank1_name_free applies" \
  '[f for f in d["failures"] if f.startswith("ratchet:")]' \
  "['ratchet: name-free rank-1 rate 75.0% (3/4) is below min-rank1-name-free 90%']"
run --skills-dir "$SKC" --prompts "$NF_LOW" --min-rank1-name-free 75
expect_rc "name-free ratchet: --min-rank1-name-free overrides the file" 0

NF_COV="$SBX/namefree-cov.json"
nf_prompts "$NF_COV" '"thresholds": { "min_name_free_per_skill": 1 }, "exempt": [ { "skill": "move-archive", "reason": "alias" } ],'
run --skills-dir "$SKC" --prompts "$NF_COV" --json
expect_py "name-free coverage: skills without a name-free prompt are named" 'd["short_name_free"]' "['archive-move']"
expect_py "name-free coverage: the failure says name-free" \
  'any(f.startswith("coverage: archive-move has 0 name-free") for f in d["failures"])' "True"

# --- 6d. the frontmatter reader --------------------------------------------------------------
mkraw() { # <dir> <name> <whole SKILL.md text>
  mkdir -p "$1/$2"
  printf '%s' "$3" > "$1/$2/SKILL.md"
}
FM="$SBX/fm"
mkraw "$FM" plain-multi  $'---\nname: plain-multi\ndescription: Export ledger entries\n  to CSV files\n  for the auditors.\ntype: skill\n---\n'
mkraw "$FM" next-line    $'---\nname: next-line\ndescription:\n  Render monthly statements\n  as PDF documents.\n---\n'
mkraw "$FM" double-q     $'---\nname: double-q\ndescription: "Sync rates: nightly \\"feed\\"\n  from the bank"\n---\n'
mkraw "$FM" single-q     $'---\nname: single-q\ndescription: \'Archive what\'\'s old\'  # a comment\n---\n'
mkraw "$FM" literal      $'---\nname: literal\ndescription: |-\n  Send invoice reminders\n  by email.\n---\n'
mkraw "$FM" folded       $'---\nname: folded\ndescription: >+2\n  Translate help texts\n  into German.\n---\n'
mkraw "$FM" folded-c     $'---\nname: folded-c\ndescription: >2- # a comment\n  Rotate the signing keys.\n---\n'
mkraw "$FM" hash-c       $'---\nname: hash-c\ndescription: Purge stale caches # trailing comment\n---\n'
printf '{ "positive": [] }' > "$SBX/none.json"
run --skills-dir "$FM" --prompts "$SBX/none.json" --json
expect_rc "frontmatter: every supported shape reads without a failure" 0
desc() { printf 'd["descriptions"]["%s"]' "$1"; }
expect_py "frontmatter: plain value over several indented lines" "$(desc plain-multi)" "Export ledger entries to CSV files for the auditors."
expect_py "frontmatter: value starting on the next indented line" "$(desc next-line)"   "Render monthly statements as PDF documents."
expect_py "frontmatter: double-quoted, escapes and two lines"     "$(desc double-q)"    'Sync rates: nightly "feed" from the bank'
expect_py "frontmatter: single-quoted with '' and a comment"      "$(desc single-q)"    "Archive what's old"
expect_py "frontmatter: literal block |-"                          "repr($(desc literal))" "'Send invoice reminders\\nby email.'"
expect_py "frontmatter: folded block with chomping and indent >+2" "$(desc folded)"      "Translate help texts into German."
expect_py "frontmatter: folded block >2- with a comment"           "$(desc folded-c)"    "Rotate the signing keys."
expect_py "frontmatter: a trailing comment is dropped"             "$(desc hash-c)"      "Purge stale caches"

FMB="$SBX/fmbad"
mkraw "$FMB" good        $'---\nname: good\ndescription: Purge stale caches.\n---\n'
mkraw "$FMB" no-fm       $'# Title\n\ndescription: not frontmatter\n'
mkraw "$FMB" empty       $'---\nname: empty\ndescription:\n---\n'
mkraw "$FMB" empty-q     $'---\nname: empty-q\ndescription: ""\n---\n'
mkraw "$FMB" colon       $'---\nname: colon\ndescription: Use for bugs: small ones\n---\n'
mkraw "$FMB" unclosed-q  $'---\nname: unclosed-q\ndescription: "never closes\n  at all\n---\n'
mkraw "$FMB" after-q     $'---\nname: after-q\ndescription: "quoted" then more\n---\n'
mkraw "$FMB" list        $'---\nname: list\ndescription:\n  - one\n  - two\n---\n'
mkraw "$FMB" mapping     $'---\nname: mapping\ndescription:\n  en: English text\n---\n'
mkraw "$FMB" flow        $'---\nname: flow\ndescription: [a, b]\n---\n'
mkraw "$FMB" dup         $'---\nname: dup\ndescription: one\ndescription: two\n---\n'
mkraw "$FMB" bad-block   $'---\nname: bad-block\ndescription: |x\n  text\n---\n'
mkraw "$FMB" tab         $'---\nname: tab\ndescription: one\n\ttwo\n---\n'
run --skills-dir "$FMB" --prompts "$SBX/none.json" --json
expect_rc "frontmatter: an unreadable description exits 1" 1
for s in no-fm empty empty-q colon unclosed-q after-q list mapping flow dup bad-block tab; do
  expect_py "frontmatter: $s fails loudly" \
    "sum(1 for f in d['failures'] if f.startswith('skill $s ') or f.startswith('skill $s:'))" "1"
done
expect_py "frontmatter: the readable skill does not fail" \
  'any(f.startswith("skill good") for f in d["failures"])' "False"
expect_py "frontmatter: a skill without frontmatter says so" \
  'any(f.startswith("skill no-fm:") and "no frontmatter block" in f for f in d["failures"])' "True"
expect_py "frontmatter: an unreadable description is not scored as text" "$(desc colon)" ""

# --- 7. exit-2 paths ------------------------------------------------------------------------
run --skills-dir "$SBX/nope" --prompts "$CLEAN"
expect_rc "missing skills dir exits 2" 2
case "$ERR" in *"$SBX/nope"*) pass "missing skills dir message names the path" ;; *) fail "message must name the path. err: $ERR" ;; esac

run --skills-dir "$SKC" --prompts "$SBX/nope.json"
expect_rc "missing prompts file exits 2" 2

mkdir -p "$SBX/empty-skills"
run --skills-dir "$SBX/empty-skills" --prompts "$CLEAN"
expect_rc "skills dir with no SKILL.md exits 2" 2

printf '{ not json' > "$SBX/bad.json"
run --skills-dir "$SKC" --prompts "$SBX/bad.json"
expect_rc "invalid JSON exits 2" 2

printf '{ "allow_pair": [] }' > "$SBX/typo.json"
run --skills-dir "$SKC" --prompts "$SBX/typo.json"
expect_rc "an unknown top-level key exits 2" 2
case "$ERR" in *allow_pair*) pass "unknown key message names the key" ;; *) fail "message must name the key. err: $ERR" ;; esac

printf '{ "allow_pairs": [ { "skills": ["rate-sync", "pdf-render"] } ] }' > "$SBX/noreason.json"
run --skills-dir "$SKC" --prompts "$SBX/noreason.json"
expect_rc "an allow-list entry without a reason exits 2" 2

printf '{ "thresholds": { "warn": 0.9, "fail": 0.5 } }' > "$SBX/inverted.json"
run --skills-dir "$SKC" --prompts "$SBX/inverted.json"
expect_rc "warn above fail in the file exits 2" 2

run --skills-dir "$SKC" --prompts "$CLEAN" --warn 0.8 --fail 0.6
expect_rc "warn above fail by flag exits 2" 2
run --skills-dir "$SKC" --prompts "$CLEAN" --warn abc
expect_rc "a non-numeric threshold exits 2" 2
run --skills-dir "$SKC" --prompts "$CLEAN" --top-k 0
expect_rc "--top-k 0 exits 2" 2
run --skills-dir "$SKC" --prompts "$CLEAN" --min-rank1 150
expect_rc "--min-rank1 above 100 exits 2" 2
run --skills-dir "$SKC" --prompts "$CLEAN" --min-rank1-name-free 150
expect_rc "--min-rank1-name-free above 100 exits 2" 2

printf '{ "negative": [ { "prompt": "x", "not": "rate-sync", "owner": "rate-sync" } ] }' > "$SBX/owner-is-not.json"
run --skills-dir "$SKC" --prompts "$SBX/owner-is-not.json"
expect_rc "a negative whose owner is its 'not' skill exits 2" 2
case "$ERR" in *"both 'not' and 'owner'"*) pass "owner == not message says why" ;; *) fail "message must say both not and owner. err: $ERR" ;; esac

# Non-finite numbers: by flag, and as JSON constants or overflow in the file.
for v in nan inf -inf Infinity; do
  run --skills-dir "$SKC" --prompts "$CLEAN" --top-k "$v"
  expect_rc "--top-k $v exits 2" 2
done
run --skills-dir "$SKC" --prompts "$CLEAN" --min-rank1 inf
expect_rc "--min-rank1 inf exits 2" 2
run --skills-dir "$SKC" --prompts "$CLEAN" --warn nan
expect_rc "--warn nan exits 2" 2
printf '{ "thresholds": { "top_k": NaN } }' > "$SBX/nan.json"
printf '{ "thresholds": { "min_positive_per_skill": Infinity } }' > "$SBX/inf.json"
printf '{ "thresholds": { "min_rank1": 1e400 } }' > "$SBX/overflow.json"
for f in nan inf overflow; do
  run --skills-dir "$SKC" --prompts "$SBX/$f.json"
  expect_rc "a non-finite number in the file ($f) exits 2" 2
  case "$ERR" in *Traceback*) fail "non-finite number ($f) must not raise a traceback. err: $ERR" ;; *) pass "non-finite number ($f) gives a message, not a traceback" ;; esac
done
run --bogus
expect_rc "unknown argument exits 2" 2
run --prompts
expect_rc "flag without a value exits 2" 2

mkdir -p "$SBX/nopy"
RC=0
OUT="$(PATH="$SBX/nopy" "$BASH" "$RC_SCRIPT" --skills-dir "$SKC" --prompts "$CLEAN" 2>"$SBX/err")" || RC=$?
ERR="$(cat "$SBX/err")"
expect_rc "missing python3 exits 2" 2
case "$ERR" in *python3*) pass "missing python3 message names python3" ;; *) fail "message must name python3. err: $ERR" ;; esac

# --- 7b. a terminal that cannot encode the prompt text -------------------------------------
# The report is ASCII; a prompt from the fixture may not be. Under a Latin-1 locale an
# arrow cannot be encoded, and the report must escape it instead of crashing.
latin1="$(locale -a 2>/dev/null | grep -i -E '^en_US\.(ISO8859-1|iso88591)$' || true)"
if [ -n "$latin1" ]; then
  latin1="$(printf '%s\n' "$latin1" | awk 'NR==1')"
  printf '{ "positive": [ { "prompt": "sync the exchange rates \\u2192 bank", "skill": "rate-sync" } ], "allow_pairs": [ { "skills": ["archive-move", "move-archive"], "reason": "legacy alias" } ] }' > "$SBX/arrow.json"
  RC=0
  OUT="$(LC_ALL="$latin1" bash "$RC_SCRIPT" --skills-dir "$SKC" --prompts "$SBX/arrow.json" 2>"$SBX/err")" || RC=$?
  ERR="$(cat "$SBX/err")"
  expect_rc "a non-UTF-8 terminal: the report still exits 0" 0
  # The '.' stands for the backslash of the escape the report prints for the arrow.
  if grep -q 'rates .u2192 bank' <<<"$OUT" && grep -q '^summary: PASS' <<<"$OUT"; then
    pass "a non-UTF-8 terminal: the character is escaped and the summary prints"
  else
    fail "a non-UTF-8 terminal must get an escaped character and the summary. out: $OUT err: $ERR"
  fi
else
  echo "SKIP: no en_US ISO-8859-1 locale on this machine; the non-UTF-8 terminal case did not run"
fi

# --- 7c. wiring: run-fixtures.sh and validate-toolkit.sh fail when the check fails ------------
# run-fixtures.sh resolves everything from its own location, so a copy in a small tree
# runs the skill-routing fixtures of that tree against its skills.
RF="$SBX/rf"
mkdir -p "$RF/scripts" "$RF/tests/fixtures" "$RF/.claude/references" "$RF/.claude/skills"
cp "$REPO_ROOT/scripts/run-fixtures.sh" "$REPO_ROOT/scripts/routing-check.sh" "$RF/scripts/"
cp "$REPO_ROOT/.claude/references/implement-approval-gate.md" \
   "$REPO_ROOT/.claude/references/orchestration-gates.md" "$RF/.claude/references/"
cp -R "$SKC/." "$RF/.claude/skills/"
clean_prompts "$RF/tests/fixtures/good.json" '"fixture_type": "skill-routing",'
RC=0
OUT="$(bash "$RF/scripts/run-fixtures.sh" 2>"$SBX/err")" || RC=$?
ERR="$(cat "$SBX/err")"
expect_rc "run-fixtures: a passing skill-routing fixture exits 0" 0
case "$OUT" in
  *"OK   good.json (skill-routing, PASS - rank-1 3/4"*) pass "run-fixtures: prints OK with the summary" ;;
  *) fail "run-fixtures must print 'OK   good.json (skill-routing, PASS ...'. out: $OUT err: $ERR" ;;
esac
clean_prompts "$RF/tests/fixtures/bad.json" '"fixture_type": "skill-routing", "thresholds": { "min_rank1": 100 },'
RC=0
OUT="$(bash "$RF/scripts/run-fixtures.sh" 2>"$SBX/err")" || RC=$?
ERR="$(cat "$SBX/err")"
expect_rc "run-fixtures: a failing skill-routing fixture exits 1" 1
case "$ERR" in
  *"FAIL: ratchet: rank-1 rate 75.0%"*"FAIL: bad.json: routing-check.sh exited 1"*) pass "run-fixtures: prints the check's failure and names the fixture" ;;
  *) fail "run-fixtures must print the ratchet failure and 'FAIL: bad.json: routing-check.sh exited 1'. err: $ERR" ;;
esac

# validate-toolkit.sh needs the whole toolkit and a git work tree, so this copies the
# repo's files (tracked and untracked, not ignored) and breaks only the committed ratchet.
if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  VT="$SBX/vt"
  mkdir -p "$VT"
  git -C "$REPO_ROOT" ls-files -z --cached --others --exclude-standard > "$SBX/files.lst"
  (cd "$REPO_ROOT" && tar --null -T "$SBX/files.lst" -cf "$SBX/tree.tar") && tar -xf "$SBX/tree.tar" -C "$VT"
  git -C "$VT" init -q
  python3 - "$VT/tests/fixtures/skill-routing.json" <<'PYX'
import json, sys
d = json.load(open(sys.argv[1]))
d["thresholds"]["min_rank1"] = 100
json.dump(d, open(sys.argv[1], "w"), indent=2)
PYX
  RC=0
  OUT="$(bash "$VT/scripts/validate-toolkit.sh" 2>&1)" || RC=$?
  ERR=""
  expect_rc "validate-toolkit: fails when the routing check fails" 1
  case "$OUT" in
    *"ERROR: skill routing check failed"*) pass "validate-toolkit: names the routing check" ;;
    *) fail "validate-toolkit must stop with 'skill routing check failed'. last lines: $(printf '%s\n' "$OUT" | awk '{l[NR]=$0} END{for(i=NR-4;i<=NR;i++) if(i>0) print l[i]}')" ;;
  esac
else
  echo "SKIP: not in a git work tree; the validate-toolkit wiring case did not run"
fi

# --- 8. real repo: the committed prompts pass on the real skills, deterministically -----------
RC=0
OUT="$(cd "$REPO_ROOT" && bash "$RC_SCRIPT" --json 2>"$SBX/err")" || RC=$?
ERR="$(cat "$SBX/err")"
FIRST="$OUT"
expect_rc "real repo run exits 0" 0
real_skills=0
for f in "$REPO_ROOT"/.claude/skills/*/SKILL.md; do [ -f "$f" ] && real_skills=$((real_skills + 1)); done
expect_py "real repo: skills_total matches .claude/skills/*/SKILL.md" 'd["skills_total"]' "$real_skills"
expect_py "real repo: status pass"                     'd["status"]' "pass"
expect_py "real repo: every positive prompt is in the top k" 'all(c["pass"] for c in d["positive"])' "True"
expect_py "real repo: every negative prompt passes"    'all(c["pass"] for c in d["negative"])' "True"
expect_py "real repo: a ratchet is committed"          'd["thresholds"]["min_rank1"] > 0' "True"
expect_py "real repo: a name-free ratchet is committed" 'd["thresholds"]["min_rank1_name_free"] > 0' "True"
expect_py "real repo: every non-exempt skill has a name-free prompt" \
  'sorted(s for s, n in d["coverage_name_free"].items() if n == 0 and s not in d["exempt"])' "[]"
expect_py "real repo: no warnings (no stale entry, no negative that cannot fail)" 'd["warnings"]' "[]"
expect_py "real repo: no negative repeats a positive prompt" \
  'sorted({c["prompt"] for c in d["negative"]} & {c["prompt"] for c in d["positive"]})' "[]"
expect_py "real repo: no pair at or above fail"        'any(p["level"] == "fail" for p in d["pairs"])' "False"
RC=0
OUT="$(cd "$REPO_ROOT" && bash "$RC_SCRIPT" --json 2>/dev/null)" || RC=$?
if [ "$OUT" = "$FIRST" ]; then pass "real repo: two runs give identical output"; else fail "real repo: output differs between runs"; fi

echo
if [ "$fails" -eq 0 ]; then
  echo "All routing-check tests passed."
  exit 0
fi
echo "$fails routing-check test(s) failed."
exit 1
