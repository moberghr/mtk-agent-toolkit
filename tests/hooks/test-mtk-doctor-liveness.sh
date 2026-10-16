#!/usr/bin/env bash
set -euo pipefail

# test-mtk-doctor-liveness.sh — hook liveness and instruction-load checks in
# `mtk-doctor` health mode, and shadow-log counts in `--usage`.
#
# Liveness: every hook registered in hooks/hooks.json refreshes a stamp named
# after its file under ${TMPDIR}/mtk-hook-seen-<uid>/<root>/ (mtk_hook_seen), and
# session-start counts sessions in <stamp dir>/.sessions (mtk_liveness_tick).
# The doctor derives the hook set from hooks.json (SubagentStart = event-rare,
# info only; everything else per-call) and WARNs on a per-call hook whose stamp
# is missing, or more than 14 days older than the last session tick (the
# mtime of .sessions, so an idle repo is not stale), only once .sessions counts
# >= 5 — a missing
# .sessions is 0, and .claude/analytics.json's lifetime count is not used. No
# stamp directory is "unknown"; no python3 or an unreadable hooks.json is "not
# checked". Instruction load: each scripts/check-instruction-load.sh finding is
# a WARN; exit 2, or exit 1 with no finding, is "not checked" with the script's
# first stderr line, never a clean result.
#
# Everything runs in a mktemp -d sandbox: CLAUDE_PROJECT_DIR is a throwaway git
# repo and TMPDIR a sibling directory, so no real stamp or log is read or
# written. Cases that need a different hooks.json or a stub script run a copy of
# the doctor from a sandbox "kit" tree.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/mtk-doctor.sh"
HOOK_IO="$REPO_ROOT/hooks/lib/hook-io.sh"

command -v python3 >/dev/null 2>&1 || { echo "test-mtk-doctor-liveness: python3 required" >&2; exit 2; }

SBX="$(mktemp -d -t mtk-doctor-liveness-XXXXXX)"
trap 'rm -rf "$SBX"' EXIT
PROJ="$SBX/project"
mkdir -p "$PROJ/.claude" "$SBX/home" "$SBX/tmp"
( cd "$PROJ" && git init -q . )
export TMPDIR="$SBX/tmp"
unset MTK_CODEX_DOC_MAX_BYTES MTK_CONFIG_GUARD 2>/dev/null || true

fails=0
expect() {
  local label="$1" want="$2" got="$3"
  if [ "$got" != "$want" ]; then
    printf 'FAIL: %s — expected %s, got %s\n' "$label" "$want" "$got" >&2
    fails=$((fails + 1))
  else
    printf '  PASS  %s\n' "$label"
  fi
}
expect_has() { # $1 label  $2 needle  $3 haystack
  case "$3" in
    *"$2"*) printf '  PASS  %s\n' "$1" ;;
    *) printf 'FAIL: %s — %s not in: %s\n' "$1" "$2" "$3" >&2; fails=$((fails + 1)) ;;
  esac
}

# DOC = doctor to run (default: the real one); XENV = extra VAR=value for env.
DOC="$DOCTOR"
XENV=()
run_doctor() {
  ( cd "$PROJ" && env -u MTK_HELPER_ROOT -u CLAUDE_PLUGIN_ROOT HOME="$SBX/home" \
      CLAUDE_PROJECT_DIR="$PROJ" TMPDIR="$SBX/tmp" ${XENV[@]+"${XENV[@]}"} bash "$DOC" "$@" 2>/dev/null ) || true
}
# status<TAB>name lines for one category of `mtk-doctor --json`. The JSON is
# kept in $SBX/last.json so detail_of reads the same run (one doctor run each).
checks() { # $1 category
  run_doctor --json > "$SBX/last.json"
  python3 -c 'import json,sys
for c in json.load(open(sys.argv[2]))["checks"]:
    if c["category"] == sys.argv[1]: print(c["status"] + "\t" + c["name"])' "$1" "$SBX/last.json"
}
detail_of() { # $1 check name — its detail in the last checks() run
  python3 -c 'import json,sys
for c in json.load(open(sys.argv[2]))["checks"]:
    if c["name"] == sys.argv[1]: print(c["detail"])' "$1" "$SBX/last.json"
}
count_lines() { # $1 ERE  $2 text — count without grep -c's exit 1 on zero
  awk -v re="$1" '$0 ~ re { n++ } END { print n + 0 }' <<<"$2"
}
stamp() { # $@ hook file names, stamped through the real helper
  local h
  for h in "$@"; do
    ( cd "$PROJ" && CLAUDE_PROJECT_DIR="$PROJ" bash -c '. "$1" && mtk_hook_seen "$2"' _ "$HOOK_IO" "$h" )
  done
}
tick() { ( cd "$PROJ" && CLAUDE_PROJECT_DIR="$PROJ" bash -c '. "$1" && mtk_liveness_tick' _ "$HOOK_IO" ); }
analytics() { printf '{\n  "first_session": "2026-10-01",\n  "sessions": %s\n}\n' "$1" > "$PROJ/.claude/analytics.json"; }
sessions() { mkdir -p "$STAMP_DIR"; printf '%s\n' "$1" > "$STAMP_DIR/.sessions"; }
age() { # $1 file  $2 days — set its mtime that many days in the past
  python3 -c 'import os,sys,time; t=time.time()-float(sys.argv[2])*86400; os.utime(sys.argv[1],(t,t))' "$1" "$2"
}

STAMP_DIR="$(cd "$PROJ" && CLAUDE_PROJECT_DIR="$PROJ" bash -c '. "$1" && mtk_hook_seen_dir' _ "$HOOK_IO")"
# The expected sets, derived here independently from the real hooks.json.
hook_set() { # $1 = per-call|rare
  python3 - "$REPO_ROOT/hooks/hooks.json" "$1" <<'PY'
import json, os, sys
out = []
for ev, entries in json.load(open(sys.argv[1]))["hooks"].items():
    for entry in entries:
        for h in entry["hooks"]:
            b = os.path.basename(h["command"].split()[0].strip("\"'"))
            if ((ev == "SubagentStart") == (sys.argv[2] == "rare")) and b not in out:
                out.append(b)
print(" ".join(out))
PY
}
PER_CALL="$(hook_set per-call)"
RARE="$(hook_set rare)"
n_per_call="$(wc -w <<<"$PER_CALL" | tr -d ' ')"
expect_has "derived per-call set includes the async Stop recorders" "cost-tracker.sh" "$PER_CALL"
expect "derived event-rare set is the SubagentStart hook" "subagent-context.sh" "$RARE"

# ============================ unknown: no stamp directory ======================
analytics 12
out="$(checks hooks)"
expect "no stamp dir → liveness unknown (PASS)" 1 "$(count_lines $'^PASS\thook liveness unknown' "$out")"
expect "no stamp dir → no liveness WARN" 0 "$(count_lines $'^WARN\thook (not seen|stale)' "$out")"

# ============================ a real hook leaves its stamp =====================
payload='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$PROJ"'/notes.txt","content":"x"}}'
( cd "$PROJ" && MTK_CONFIG_GUARD=0 CLAUDE_PROJECT_DIR="$PROJ" "$REPO_ROOT/hooks/config-guard.sh" <<<"$payload" >/dev/null 2>&1 ) || true
[ -e "$STAMP_DIR/config-guard.sh" ] && a=present || a=missing
expect "kill-switched hook writes no stamp" missing "$a"
( cd "$PROJ" && CLAUDE_PROJECT_DIR="$PROJ" "$REPO_ROOT/hooks/config-guard.sh" <<<"$payload" >/dev/null 2>&1 ) || true
[ -e "$STAMP_DIR/config-guard.sh" ] && a=present || a=missing
expect "config-guard run → stamp in the stamp dir under \$TMPDIR" present "$a"
n="$(find "$PROJ" -name 'config-guard.sh' | wc -l | tr -d ' ')"
expect "stamp is never written inside the project" 0 "$n"

# ============================ all per-call stamps present ======================
# shellcheck disable=SC2086  # word-split list of hook names
stamp $PER_CALL
out="$(checks hooks)"
expect "all per-call stamps → no liveness WARN" 0 "$(count_lines $'^WARN\thook (not seen|stale)' "$out")"
expect "all per-call stamps → PASS per-call hooks alive" 1 "$(count_lines $'^PASS\tper-call hooks alive' "$out")"
expect_has "alive row counts every per-call hook in hooks.json" "all $n_per_call per-call hooks" "$(detail_of 'per-call hooks alive')"

# ============================ the session count comes from .sessions ===========
rm -f "$STAMP_DIR/security-gate.sh" "$STAMP_DIR/verify-completion"
analytics 40
out="$(checks hooks)"
expect "missing stamps, no .sessions (analytics.json says 40) → no WARN" 0 "$(count_lines $'^WARN\thook (not seen|stale)' "$out")"
expect "missing stamps, no .sessions → reported as not seen yet" 1 "$(count_lines $'^PASS\tper-call hooks not seen yet' "$out")"
expect_has "not-seen-yet row says .sessions counts 0" "counts only 0 session(s)" "$(detail_of 'per-call hooks not seen yet')"
tick; tick; tick; tick
expect "mtk_liveness_tick ×4 → .sessions = 4" 4 "$(cat "$STAMP_DIR/.sessions")"
out="$(checks hooks)"
expect "missing stamps, 4 ticked sessions → no WARN" 0 "$(count_lines $'^WARN\thook (not seen|stale)' "$out")"
tick
out="$(checks hooks)"
expect "missing stamps, 5th ticked session → WARN security-gate" 1 "$(count_lines $'^WARN\thook not seen: security-gate$' "$out")"
expect "missing stamps, 5 sessions → WARN verify-completion" 1 "$(count_lines $'^WARN\thook not seen: verify-completion$' "$out")"
expect "missing stamps, 5 sessions → exactly two WARNs" 2 "$(count_lines $'^WARN\thook (not seen|stale)' "$out")"
rm -f "$PROJ/.claude/analytics.json"
out="$(checks hooks)"
expect "WARN does not need analytics.json" 2 "$(count_lines $'^WARN\thook not seen' "$out")"
sessions abc
out="$(checks hooks)"
expect "non-numeric .sessions counts as 0 → no WARN" 0 "$(count_lines $'^WARN\thook (not seen|stale)' "$out")"

# ============================ stale stamps (> 14 days) =========================
stamp security-gate.sh verify-completion
sessions 12
age "$STAMP_DIR/scope-guard.sh" 15
age "$STAMP_DIR/config-guard.sh" 13
out="$(checks hooks)"
expect "15-day-old stamp, 12 sessions → WARN hook stale: scope-guard" 1 "$(count_lines $'^WARN\thook stale: scope-guard$' "$out")"
expect "13-day-old stamp still counts as seen" 0 "$(count_lines $'^WARN\thook stale: config-guard$' "$out")"
expect "stale stamp → exactly one liveness WARN" 1 "$(count_lines $'^WARN\thook (not seen|stale)' "$out")"
sessions 4
out="$(checks hooks)"
expect "15-day-old stamp, 4 sessions → no WARN" 0 "$(count_lines $'^WARN\thook (not seen|stale)' "$out")"
expect_has "below the gate the stale hook is named" "stale (> 14 days before the last session): scope-guard" "$(detail_of 'per-call hooks not seen yet')"
stamp scope-guard.sh config-guard.sh

# ============================ idle repo: age is relative to the last session ===
# No session for 30 days, every stamp refreshed at that last session: nothing is
# stale, because staleness is measured from the .sessions tick, not from now.
sessions 12
# shellcheck disable=SC2086  # word-split list of hook names
for h in $PER_CALL .sessions; do age "$STAMP_DIR/$h" 30; done
out="$(checks hooks)"
expect "idle 30 days, all stamps from the last session → no stale WARN" 0 "$(count_lines $'^WARN\thook (not seen|stale)' "$out")"
expect "idle 30 days → PASS per-call hooks alive" 1 "$(count_lines $'^PASS\tper-call hooks alive' "$out")"
# Control: one stamp 15 days older than the .sessions tick (45 days old) is stale.
age "$STAMP_DIR/scope-guard.sh" 45
out="$(checks hooks)"
expect "control: stamp 15 days older than .sessions → WARN hook stale: scope-guard" 1 "$(count_lines $'^WARN\thook stale: scope-guard$' "$out")"
expect "control: exactly one liveness WARN" 1 "$(count_lines $'^WARN\thook (not seen|stale)' "$out")"
# shellcheck disable=SC2086
stamp $PER_CALL

# ============================ event-rare hooks are info only ===================
sessions 40
rm -f "$STAMP_DIR/subagent-context.sh"
out="$(checks hooks)"
expect "event-rare stamp missing, 40 sessions → no WARN" 0 "$(count_lines $'^WARN' "$out")"
expect "event-rare stamp missing → info row" 1 "$(count_lines $'^PASS\tevent-rare hooks [(]info[)]' "$out")"
detail="$(detail_of 'event-rare hooks (info)')"
expect_has "event-rare info row names the unseen hook" "not seen: subagent-context —" "$detail"
expect_has "info row says it cannot tell not-fired from invisible" "cannot tell 'not fired' from 'fired but invisible to the model'" "$detail"
expect_has "info row points at the manual check" "manual SubagentStart check" "$detail"
stamp subagent-context.sh
checks hooks >/dev/null
expect_has "stamped event-rare hook → seen" "seen: subagent-context;" "$(detail_of 'event-rare hooks (info)')"

# ============================ the set comes from hooks.json ====================
# A copy of the doctor whose hooks.json registers one extra per-call hook and one
# extra SubagentStart hook, and drops cost-tracker.sh: only what is registered
# is judged, so a hand list could not pass this.
KIT="$SBX/kit"
mkdir -p "$KIT/scripts" "$KIT/hooks/lib"
cp "$DOCTOR" "$KIT/scripts/mtk-doctor.sh"
cp "$HOOK_IO" "$REPO_ROOT/hooks/lib/shrink-guard.sh" "$REPO_ROOT/hooks/lib/hook_registry.py" "$KIT/hooks/lib/"
python3 - "$REPO_ROOT/hooks/hooks.json" "$KIT/hooks/hooks.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
h = d["hooks"]
h["PreToolUse"].append({"matcher": "Bash", "hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/extra-hook.sh\""}]})
h["SubagentStart"][0]["hooks"].append({"type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/extra-rare.sh\""})
h["Stop"] = [e for e in h["Stop"] if not any("cost-tracker.sh" in x["command"] for x in e["hooks"])]
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
DOC="$KIT/scripts/mtk-doctor.sh"
rm -f "$STAMP_DIR/cost-tracker.sh"
out="$(checks hooks)"
expect "kit: unregistered extra-hook.sh, 40 sessions → WARN hook not seen: extra-hook" 1 "$(count_lines $'^WARN\thook not seen: extra-hook$' "$out")"
expect "kit: exactly one liveness WARN" 1 "$(count_lines $'^WARN\thook (not seen|stale)' "$out")"
expect "kit: hook dropped from hooks.json is not judged" 0 "$(count_lines $'^WARN\thook not seen: cost-tracker$' "$out")"
expect_has "kit: extra SubagentStart hook is info only" "not seen: extra-rare" "$(detail_of 'event-rare hooks (info)')"
printf '{ not json' > "$KIT/hooks/hooks.json"
out="$(checks hooks)"
expect "kit: unparseable hooks.json → hook liveness not checked" 1 "$(count_lines $'^PASS\thook liveness not checked$' "$out")"
expect "kit: unparseable hooks.json → no liveness WARN" 0 "$(count_lines $'^WARN\thook (not seen|stale)' "$out")"
expect_has "kit: not-checked detail names the parse error" "JSONDecodeError" "$(detail_of 'hook liveness not checked')"
cp "$REPO_ROOT/hooks/hooks.json" "$KIT/hooks/hooks.json"

# An `if`-filtered handler is event-rare like SubagentStart: its stamp may never
# appear (the filter rarely matches), so it is reported, never WARNed. A script
# registered both with and without `if` fires per call, so per-call wins.
python3 - "$REPO_ROOT/hooks/hooks.json" "$KIT/hooks/hooks.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
pre = d["hooks"]["PreToolUse"]
pre.append({"matcher": "Bash", "hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/if-only.sh\"", "if": "Bash(git push*)", "timeout": 5}]})
# mixed-hook.sh: `if`-filtered first, plain second (the order must not matter)
pre.append({"matcher": "Bash", "hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/mixed-hook.sh\"", "if": "Bash(git push*)", "timeout": 5}]})
pre.append({"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/mixed-hook.sh\"", "timeout": 5}]})
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
DOC="$KIT/scripts/mtk-doctor.sh"
stamp cost-tracker.sh
sessions 40
out="$(checks hooks)"
expect "kit: if-only handler never stamped, 40 sessions → not WARNed" 0 "$(count_lines $'^WARN\thook not seen: if-only$' "$out")"
expect_has "kit: if-only handler is reported on the event-rare row" "not seen: " "$(detail_of 'event-rare hooks (info)')"
expect_has "kit: the event-rare row names if-only" "if-only" "$(detail_of 'event-rare hooks (info)')"
expect "kit: same script with and without if → per-call → WARN hook not seen: mixed-hook" 1 "$(count_lines $'^WARN\thook not seen: mixed-hook$' "$out")"
expect "kit: exactly one liveness WARN (the mixed one)" 1 "$(count_lines $'^WARN\thook (not seen|stale)' "$out")"
sessions 4
out="$(checks hooks)"
expect "kit: 4 sessions → no WARN for if-only or mixed" 0 "$(count_lines $'^WARN\thook (not seen|stale)' "$out")"
sessions 40
cp "$REPO_ROOT/hooks/hooks.json" "$KIT/hooks/hooks.json"
DOC="$DOCTOR"
stamp cost-tracker.sh

# ============================ no python3 → not checked =========================
# PATH with every python* removed (each PATH dir holding python3 is replaced by
# a directory of symlinks to everything else in it).
NOPY_PATH="" i=0
IFS=: read -r -a path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
  if [ -n "$d" ] && [ -e "$d/python3" ]; then
    i=$((i + 1)); nd="$SBX/nopy/$i"; mkdir -p "$nd"
    for f in "$d"/*; do
      case "${f##*/}" in python*) continue ;; esac
      if [ -x "$f" ] && [ ! -e "$nd/${f##*/}" ]; then ln -s "$f" "$nd/${f##*/}"; fi
    done
    NOPY_PATH="$NOPY_PATH:$nd"
  else
    NOPY_PATH="$NOPY_PATH:$d"
  fi
done
NOPY_PATH="${NOPY_PATH#:}"
# A fresh process: a builtin with a PATH= prefix can still hit this shell's hash.
rc=0; env PATH="$NOPY_PATH" bash -c 'command -v python3' >/dev/null 2>&1 || rc=$?
expect "control: python3 is unreachable on the filtered PATH" 1 "$rc"
rm -f "$STAMP_DIR/security-gate.sh"
XENV=("PATH=$NOPY_PATH")
out="$(checks hooks)"
expect "no python3 → hook liveness not checked" 1 "$(count_lines $'^PASS\thook liveness not checked$' "$out")"
expect "no python3 → no liveness WARN despite a missing stamp" 0 "$(count_lines $'^WARN\thook (not seen|stale)' "$out")"
expect_has "no python3 → detail says why" "python3 not found" "$(detail_of 'hook liveness not checked')"
XENV=()
stamp security-gate.sh

# ============================ instruction load ================================
out="$(checks context)"
expect "clean project → instruction load PASS" 1 "$(count_lines $'^PASS\tinstruction load$' "$out")"
expect "clean project → no instruction-load WARN" 0 "$(count_lines $'^WARN\tinstruction load' "$out")"
mkdir -p "$PROJ/.claude/rules"
printf -- '---\nglobs: "src/**"\n---\n# rule\n' > "$PROJ/.claude/rules/cursor-style.md"
out="$(checks context)"
expect "globs-only rule → WARN instruction load: GLOBS-NOT-PATHS" 1 "$(count_lines $'^WARN\tinstruction load: GLOBS-NOT-PATHS$' "$out")"
XENV=("MTK_CODEX_DOC_MAX_BYTES=abc")
out="$(run_doctor --json)"
XENV=()
st="$(python3 -c 'import json,sys
for c in json.load(sys.stdin)["checks"]:
    if c["category"] == "context" and c["name"].startswith("instruction load"): print(c["status"] + "\t" + c["name"] + "\t" + c["detail"])' <<<"$out")"
expect "check-instruction-load exit 2 → not checked, never WARN" $'PASS\tinstruction load not checked' "$(cut -f1,2 <<<"$st")"
expect_has "exit 2 → detail carries the script's first stderr line" "exited 2: check-instruction-load: MTK_CODEX_DOC_MAX_BYTES must be a positive integer" "$st"
rm -f "$PROJ/.claude/rules/cursor-style.md"

# Stub check scripts in the kit: exit 1 with no finding, and a finding plus a
# not-checked stderr line.
DOC="$KIT/scripts/mtk-doctor.sh"
printf '#!/usr/bin/env bash\necho "stub: scan aborted" >&2\nexit 1\n' > "$KIT/scripts/check-instruction-load.sh"
out="$(checks context)"
expect "exit 1 with no finding → instruction load not checked" 1 "$(count_lines $'^PASS\tinstruction load not checked$' "$out")"
expect "exit 1 with no finding → no WARN" 0 "$(count_lines $'^WARN\tinstruction load' "$out")"
expect_has "exit 1 with no finding → detail says so, with stderr" "exited 1 but printed no finding: stub: scan aborted" "$(detail_of 'instruction load not checked')"
printf '#!/usr/bin/env bash\necho "GLOBS-NOT-PATHS .claude/rules/x.md: d"\necho "check-instruction-load: r; SHADOWED-AGENTS not checked" >&2\nexit 1\n' > "$KIT/scripts/check-instruction-load.sh"
out="$(checks context)"
expect "finding + stderr line → WARN for the finding" 1 "$(count_lines $'^WARN\tinstruction load: GLOBS-NOT-PATHS$' "$out")"
expect "finding + stderr line → partly not checked row" 1 "$(count_lines $'^PASS\tinstruction load partly not checked$' "$out")"
DOC="$DOCTOR"

# ============================ --usage: shadow counts ===========================
field() { python3 -c 'import json,sys; d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d[k]
print(d)' "$1"; }
out="$(run_doctor --usage --json)"
expect "--usage without a shadow log → absent" absent "$(field enforcement_shadow.status <<<"$out")"
case "$out" in *liveness*|*"not seen"*) a=present ;; *) a=absent ;; esac
expect "--usage carries no liveness verdict" absent "$a"
mkdir -p "$PROJ/.mtk/metrics"
{
  printf '{"ts":"2026-10-15T08:00:00Z","hook":"config-guard","code":"T1-SKIP","target":"1"}\n'
  printf '{"ts":"2026-10-15T08:01:00Z","hook":"config-guard","code":"T1-SKIP","target":"2"}\n'
  printf '{"ts":"2026-10-15T08:02:00Z","hook":"config-guard","code":"T3-FEWER-TESTS","target":"3"}\n'
  printf '{"ts":"2026-10-15T08:03:00Z","hook":"scope-guard","code":"SCOPE-OUT-OF-MANIFEST","target":"4"}\n'
  printf 'not json\n'
} > "$PROJ/.mtk/metrics/enforcement-shadow.jsonl"
before="$(cksum "$PROJ/.mtk/metrics/enforcement-shadow.jsonl")"
out="$(run_doctor --usage --json)"
expect "--usage shadow: n_events" 4 "$(field enforcement_shadow.n_events <<<"$out")"
# by_hook[hook][code] read directly: codes contain dashes, field() splits on dots.
by_hook() { python3 -c 'import json,sys; print(json.load(sys.stdin)["enforcement_shadow"]["by_hook"][sys.argv[1]][sys.argv[2]])' "$1" "$2"; }
expect "--usage shadow: config-guard T1-SKIP" 2 "$(by_hook config-guard T1-SKIP <<<"$out")"
expect "--usage shadow: config-guard T3-FEWER-TESTS" 1 "$(by_hook config-guard T3-FEWER-TESTS <<<"$out")"
expect "--usage shadow: scope-guard code counted" 1 "$(by_hook scope-guard SCOPE-OUT-OF-MANIFEST <<<"$out")"
expect "--usage shadow: unparseable line counted, not fatal" 1 "$(field enforcement_shadow.unparseable_lines <<<"$out")"
expect "--usage leaves the shadow log untouched" "$before" "$(cksum "$PROJ/.mtk/metrics/enforcement-shadow.jsonl")"
txt="$(run_doctor --usage)"
case "$txt" in *ENFORCEMENT_SHADOW*) a=shown ;; *) a=missing ;; esac
expect "--usage text output has the shadow section" shown "$a"

if [ "$fails" -gt 0 ]; then
  printf '%d failure(s)\n' "$fails" >&2
  exit 1
fi
printf 'test-mtk-doctor-liveness: all checks passed\n'
