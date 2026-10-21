#!/usr/bin/env bash
set -euo pipefail

# test-context-guard.sh — hooks/context-guard.sh (PostToolUse Edit|Write|Bash).
# Synthetic transcripts in throwaway projects, TMPDIR/HOME isolated. Covers:
# telemetry.json fields + mode 0600 below the soft threshold; the soft nudge
# once per workflow step (uuid + phase_cursor + batches_completed + level) and
# the hard nudge once; the generic nudge once per 150k band from 300k without a
# workflow; sidechain and zero-usage lines ignored; the compaction window
# precedence (env > local > project > user settings); MTK_CONTEXT_GUARD=0; the
# python-free throttle; un-ignored .mtk (nudge, no telemetry); malformed input;
# the liveness stamp. Failures exit 1 immediately (no subshell counters).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/context-guard.sh"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available" >&2; exit 0; }
REAL_PY="$(command -v python3)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf '  PASS  %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR" "$WORK/home" "$WORK/tr"
export PYTHONDONTWRITEBYTECODE=1
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
: > "$GIT_CONFIG_GLOBAL"
unset MTK_CONTEXT_GUARD MTK_CTX_SOFT MTK_CTX_HARD MTK_CTX_GENERIC MTK_CTX_GUARD_INTERVAL \
      CLAUDE_CODE_AUTO_COMPACT_WINDOW 2>/dev/null || true

mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# assistant <ctx> [sidechain] [model] — one transcript line shaped like Claude Code's.
assistant() {
  local ctx="$1" side="${2:-false}" model="${3:-claude-opus-5-5}"
  printf '{"parentUuid":"p","isSidechain":%s,"type":"assistant","uuid":"u","timestamp":"2026-10-21T08:00:00.000Z","message":{"id":"m","type":"message","role":"assistant","model":"%s","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":%d,"cache_read_input_tokens":%d,"output_tokens":50}}}\n' \
    "$side" "$model" 990 "$((ctx - 1000))"
}
user_line() { printf '{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":"go"}}\n'; }
# mktr <name> <ctx> — a transcript whose newest main-thread context is <ctx>.
mktr() { { user_line; assistant 1000; user_line; assistant "$2"; } > "$WORK/tr/$1.jsonl"; printf '%s' "$WORK/tr/$1.jsonl"; }

# run <project> <session> <transcript> [env...] — sets RC, OUT, ERR; never aborts.
run() {
  local proj="$1" sid="$2" trp="$3"; shift 3
  RC=0
  OUT="$(cd "$proj" && env HOME="$WORK/home" CLAUDE_PROJECT_DIR="$proj" MTK_CTX_GUARD_INTERVAL=0 "$@" bash "$HOOK" \
    <<<"{\"session_id\":\"$sid\",\"transcript_path\":\"$trp\",\"cwd\":\"$proj\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}" \
    2>"$WORK/err")" || RC=$?
  ERR="$(cat "$WORK/err")"
}
# nudge_text — the additionalContext of OUT, after checking it is ONE PostToolUse envelope.
nudge_text() {
  printf '%s' "$OUT" | python3 -c '
import json, sys
raw = sys.stdin.read()
lines = [l for l in raw.splitlines() if l.strip()]
assert len(lines) == 1, "expected one stdout line, got %d" % len(lines)
d = json.loads(lines[0])
h = d["hookSpecificOutput"]
assert h["hookEventName"] == "PostToolUse", h
assert "\n" not in h["additionalContext"]
print(h["additionalContext"])
' || fail "stdout is not one PostToolUse additionalContext envelope: $OUT"
}
expect_silent() { [ "$RC" -eq 0 ] && [ -z "$OUT" ] || fail "$1: expected exit 0 and empty stdout (rc=$RC out=$OUT)"; }
expect_nudge() { # <label> <substring>...
  local label="$1" t; shift
  [ "$RC" -eq 0 ] || fail "$label: exit $RC"
  t="$(nudge_text)"
  case "$t" in '[mtk context-guard] '*) : ;; *) fail "$label: nudge must start with [mtk context-guard]. Got: $t" ;; esac
  for s in "$@"; do
    case "$t" in *"$s"*) : ;; *) fail "$label: nudge must contain '$s'. Got: $t" ;; esac
  done
  NUDGE="$t"
}
telemetry_field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))[sys.argv[2]]; print("null" if v is None else v)' "$1" "$2"; }
write_wf() { # <project> <uuid> <phase> <batches>
  mkdir -p "$1/.mtk/workflows"
  printf '{"workflow_uuid":"%s","workflow_type":"implement","status":"active","updated_at":"%s","phase_cursor":"%s","results":{"batches_completed":%s}}\n' \
    "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$3" "$4" > "$1/.mtk/workflows/$2.json"
}

# A git project that ignores .mtk/, with one active workflow.
P="$WORK/proj"; mkdir -p "$P"; git -C "$P" init -q; printf '.mtk/\n' > "$P/.gitignore"
UUID="wf-20261021T080000Z-abc123"
write_wf "$P" "$UUID" phase-5 2

# --- 1. below soft: silent, telemetry.json written ------------------------------
run "$P" s-wf "$(mktr a 150000)"
expect_silent "below soft"
[ -z "$ERR" ] || fail "below soft: stderr must stay empty. Got: $ERR"
T="$P/.mtk/sessions/s-wf/telemetry.json"
[ -f "$T" ] || fail "telemetry.json not written at $T"
[ "$(mode_of "$T")" = "600" ] || fail "telemetry.json must be mode 0600, got $(mode_of "$T")"
python3 - "$T" "$UUID" <<'PY' || fail "telemetry.json fields wrong: $(cat "$T")"
import json, re, sys
d = json.load(open(sys.argv[1]))
assert set(d) == {"schema_version", "session_id", "context_tokens", "window", "pct", "model", "workflow", "ts"}, sorted(d)
assert d["schema_version"] == 1 and type(d["schema_version"]) is int, d
assert d["session_id"] == "s-wf" and d["context_tokens"] == 150000, d
assert d["window"] is None and d["pct"] is None, d
assert d["model"] == "claude-opus-5-5" and d["workflow"] == sys.argv[2], d
assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", d["ts"]), d["ts"]
PY
pass "below soft: no stdout; telemetry.json has the eight fields incl. schema_version 1, mode 0600"

# --- 2. soft once per workflow step ----------------------------------------------
run "$P" s-wf "$(mktr b 210000)"
expect_nudge "soft" "$UUID" "~210k tokens" "workflow-artifact.sh\" checkpoint $UUID --next" "/clear" \
  "the next session is offered the checkpoint and resumes from it"
case "$NUDGE" in *'Do not start new work'*) fail "soft must not use the hard wording. Got: $NUDGE" ;; esac
[ "$(telemetry_field "$T" context_tokens)" = "210000" ] || fail "telemetry must refresh on every parse"
pass "soft: one additionalContext line naming the uuid and the checkpoint command"
run "$P" s-wf "$(mktr c 215000)"
expect_silent "soft, same step again"
pass "soft: same workflow step stays silent"
write_wf "$P" "$UUID" phase-5 3
run "$P" s-wf "$(mktr d 216000)"
expect_nudge "soft, next batch" "$UUID" "3 batch(es) done"
pass "soft: fires again when batches_completed changes"
write_wf "$P" "$UUID" phase-6 3
run "$P" s-wf "$(mktr d2 217000)"
expect_nudge "soft, next phase" "phase phase-6"
pass "soft: fires again when phase_cursor changes"

# --- 3. hard once -------------------------------------------------------------------
run "$P" s-wf "$(mktr e 260000)"
expect_nudge "hard" "$UUID" "Do not start new work" "checkpoint now" "workflow-artifact.sh\" checkpoint $UUID --next"
run "$P" s-wf "$(mktr f 270000)"
expect_silent "hard, same step again"
pass "hard: fires once per step with the firmer wording"
run "$P" s-wf2 "$(mktr f2 260000)" MTK_CTX_HARD=300000 MTK_CTX_SOFT=255000
expect_nudge "thresholds from env" "Finish the current transition"
pass "MTK_CTX_SOFT / MTK_CTX_HARD move the thresholds"

# --- 4. no workflow: generic once per 150k band from 300k -----------------------------
PN="$WORK/nowf"; mkdir -p "$PN"; git -C "$PN" init -q; printf '.mtk/\n' > "$PN/.gitignore"
run "$PN" s-gen "$(mktr g 290000)"
expect_silent "generic below 300k"
run "$PN" s-gen "$(mktr h 310000)"
expect_nudge "generic 310k" "~310k tokens" "/clear" "/mtk handoff" "Mention it once"
case "$NUDGE" in *'workflow-artifact.sh'*) fail "generic nudge must not name a checkpoint command. Got: $NUDGE" ;; esac
run "$PN" s-gen "$(mktr i 320000)"
expect_silent "generic 320k (same band)"
run "$PN" s-gen "$(mktr j 460000)"
expect_nudge "generic 460k (next band)" "~460k tokens"
[ "$(telemetry_field "$PN/.mtk/sessions/s-gen/telemetry.json" workflow)" = "null" ] || fail "no workflow: telemetry workflow must be null"
run "$PN" s-gen3 "$(mktr j2 210000)" MTK_CTX_GENERIC=200000
expect_nudge "MTK_CTX_GENERIC" "~210k tokens"
pass "generic: 310k fires, 320k silent, 460k fires; MTK_CTX_GENERIC moves the start"

# --- 5. sidechain and zero-usage lines are ignored ----------------------------------
{ user_line; assistant 100000; assistant 900000 true; \
  printf '{"isSidechain":false,"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n'; \
  printf '{"type":"assistant", truncated line "usage"\n'; } > "$WORK/tr/side.jsonl"
run "$PN" s-side "$WORK/tr/side.jsonl"
expect_silent "sidechain 900k"
[ "$(telemetry_field "$PN/.mtk/sessions/s-side/telemetry.json" context_tokens)" = "100000" ] \
  || fail "context must come from the newest main-thread line: $(cat "$PN/.mtk/sessions/s-side/telemetry.json")"
pass "sidechain, zero-usage and unparseable lines are skipped"

# --- 6. compaction window precedence ---------------------------------------------------
PW="$WORK/win"; mkdir -p "$PW/.claude" "$WORK/home/.claude"   # not a git repo: telemetry allowed
printf '{"autoCompactWindow": 500000}\n' > "$WORK/home/.claude/settings.json"
run "$PW" s-w1 "$(mktr w1 250000)"
[ "$(telemetry_field "$PW/.mtk/sessions/s-w1/telemetry.json" window)" = "500000" ] || fail "user settings window not read"
[ "$(telemetry_field "$PW/.mtk/sessions/s-w1/telemetry.json" pct)" = "0.5" ] || fail "pct must be context/window"
printf '{"autoCompactWindow": 400000}\n' > "$PW/.claude/settings.json"
run "$PW" s-w2 "$(mktr w2 250000)"
[ "$(telemetry_field "$PW/.mtk/sessions/s-w2/telemetry.json" window)" = "400000" ] || fail "project settings must beat user settings"
printf '{"autoCompactWindow": 300000}\n' > "$PW/.claude/settings.local.json"
run "$PW" s-w3 "$(mktr w3 250000)"
[ "$(telemetry_field "$PW/.mtk/sessions/s-w3/telemetry.json" window)" = "300000" ] || fail "local settings must beat project settings"
run "$PW" s-w4 "$(mktr w4 250000)" CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000
[ "$(telemetry_field "$PW/.mtk/sessions/s-w4/telemetry.json" window)" = "1000000" ] || fail "env must beat settings files"
[ "$(telemetry_field "$PW/.mtk/sessions/s-w4/telemetry.json" pct)" = "0.25" ] || fail "pct with env window"
rm -f "$WORK/home/.claude/settings.json"
pass "window: CLAUDE_CODE_AUTO_COMPACT_WINDOW > settings.local.json > settings.json > ~/.claude/settings.json; pct = ctx/window"

# --- 7. kill switch ---------------------------------------------------------------------
run "$PN" s-off "$(mktr k 900000)" MTK_CONTEXT_GUARD=0
expect_silent "MTK_CONTEXT_GUARD=0"
[ ! -e "$PN/.mtk/sessions/s-off" ] || fail "MTK_CONTEXT_GUARD=0 must write no telemetry"
pass "MTK_CONTEXT_GUARD=0: silent, no telemetry"

# --- 8. throttle: the second call inside the interval starts no python ------------------
mkdir -p "$WORK/shim"
printf '#!/bin/sh\necho call >> "%s/py-calls"\nexec "%s" "$@"\n' "$WORK" "$REAL_PY" > "$WORK/shim/python3"
chmod +x "$WORK/shim/python3"
pycalls() { if [ -f "$WORK/py-calls" ]; then wc -l < "$WORK/py-calls" | tr -d ' '; else echo 0; fi; }
run "$PN" s-thr "$(mktr l 100000)" PATH="$WORK/shim:$PATH" MTK_CTX_GUARD_INTERVAL=60
expect_silent "throttle first call"
first="$(pycalls)"
[ "$first" -ge 1 ] || fail "test setup: the first call must reach python (shim saw $first calls)"
[ "$(telemetry_field "$PN/.mtk/sessions/s-thr/telemetry.json" context_tokens)" = "100000" ] || fail "first call must parse"
run "$PN" s-thr "$(mktr m 900000)" PATH="$WORK/shim:$PATH" MTK_CTX_GUARD_INTERVAL=60
expect_silent "throttled second call (900k would nudge)"
[ "$(pycalls)" = "$first" ] || fail "a throttled call must not start python ($first -> $(pycalls))"
[ "$(telemetry_field "$PN/.mtk/sessions/s-thr/telemetry.json" context_tokens)" = "100000" ] || fail "a throttled call must not parse"
run "$PN" s-thr "$(mktr n 900000)" PATH="$WORK/shim:$PATH" MTK_CTX_GUARD_INTERVAL=0
expect_nudge "interval 0 parses again" "~900k tokens"
pass "throttle: a second call within MTK_CTX_GUARD_INTERVAL starts no python and nudges nothing"

# --- 9. .mtk/ not ignored: nudge still emitted, no telemetry ------------------------------
PU="$WORK/unignored"; mkdir -p "$PU"; git -C "$PU" init -q
run "$PU" s-un "$(mktr o 310000)"
expect_nudge "un-ignored .mtk" "~310k tokens"
[ ! -e "$PU/.mtk" ] || fail "a git repo that does not ignore .mtk/ must get no telemetry: $(find "$PU/.mtk")"
pass "un-ignored .mtk: nudge emitted, nothing written under .mtk"

# --- 10. malformed / incomplete input: exit 0, silent ---------------------------------------
for bad in '{ not json' 'null' '' '{"session_id":"s-x"}' \
           "{\"transcript_path\":\"$WORK/tr/h.jsonl\"}" \
           "{\"session_id\":\"s-x\",\"transcript_path\":\"$WORK/tr/missing.jsonl\"}" \
           "{\"session_id\":\"..\",\"transcript_path\":\"$WORK/tr/h.jsonl\"}"; do
  RC=0
  OUT="$(cd "$PN" && env HOME="$WORK/home" CLAUDE_PROJECT_DIR="$PN" MTK_CTX_GUARD_INTERVAL=0 bash "$HOOK" <<<"$bad" 2>"$WORK/err")" || RC=$?
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -s "$WORK/err" ] || fail "payload '$bad': exit 0, empty stdout and stderr expected (rc=$RC out=$OUT err=$(cat "$WORK/err"))"
done
printf 'garbage\n{"type":"assistant"\n' > "$WORK/tr/garbage.jsonl"
run "$PN" s-garbage "$WORK/tr/garbage.jsonl"
expect_silent "garbage transcript"
[ -z "$ERR" ] || fail "garbage transcript must stay quiet on stderr. Got: $ERR"
[ ! -e "$PN/.mtk/sessions/s-garbage" ] || fail "no usage found: no telemetry"
pass "malformed payload, missing transcript, bad session id and garbage transcript: exit 0, silent"

# --- 11. checkpoint CLI is named by ABSOLUTE path (CR-F001) ------------------------------
write_wf "$P" "$UUID" phase-7 1
run "$P" s-abs "$(mktr abs 210000)"
expect_nudge "absolute checkpoint path" "$UUID"
case "$NUDGE" in *'`bash scripts/workflow-artifact.sh'*) fail "nudge must not use the repo-relative script path. Got: $NUDGE" ;; esac
CK="$(printf '%s' "$NUDGE" | sed -n 's/.*`bash "\(\/[^"]*\/scripts\/workflow-artifact\.sh\)" checkpoint .*/\1/p')"
[ -n "$CK" ] || fail "nudge must quote an absolute .../scripts/workflow-artifact.sh path. Got: $NUDGE"
[ "$CK" = "$REPO_ROOT/scripts/workflow-artifact.sh" ] || fail "absolute path must resolve from the hook location: $CK"
[ -f "$CK" ] || fail "the named checkpoint script must exist: $CK"
pass "nudge names the checkpoint CLI by absolute, quoted path resolved from the hook location"

# Hook copied where ../scripts is missing: falls back to CLAUDE_PLUGIN_ROOT.
mkdir -p "$WORK/copy/hooks" "$WORK/plug dir/scripts"
cp "$HOOK" "$WORK/copy/hooks/context-guard.sh"; cp -R "$REPO_ROOT/hooks/lib" "$WORK/copy/hooks/lib"
write_wf "$P" "$UUID" phase-7 2
RC=0
OUT="$(cd "$P" && env HOME="$WORK/home" CLAUDE_PROJECT_DIR="$P" MTK_CTX_GUARD_INTERVAL=0 CLAUDE_PLUGIN_ROOT="$WORK/plug dir" bash "$WORK/copy/hooks/context-guard.sh" \
  <<<"{\"session_id\":\"s-fb\",\"transcript_path\":\"$(mktr fb 210000)\",\"cwd\":\"$P\"}" 2>"$WORK/err")" || RC=$?
expect_nudge "CLAUDE_PLUGIN_ROOT fallback" "bash \"$WORK/plug dir/scripts/workflow-artifact.sh\" checkpoint $UUID --next"
pass "no ../scripts next to the hook: the nudge falls back to CLAUDE_PLUGIN_ROOT (path with a space stays quoted)"

# --- 12. threshold override, stale/completed workflows, window text, default throttle -------
write_wf "$P" "$UUID" phase-8 1
run "$P" s-ov "$(mktr ov 220000)" MTK_CTX_SOFT=255000
expect_silent "220k with MTK_CTX_SOFT=255000"
run "$P" s-ov "$(mktr ov2 260000)" MTK_CTX_SOFT=255000 MTK_CTX_HARD=300000
expect_nudge "260k with soft 255000" "Finish the current transition"
pass "MTK_CTX_SOFT override: 220k silent, 260k nudges"

PO="$WORK/oldwf"; mkdir -p "$PO"; git -C "$PO" init -q; printf '.mtk/\n' > "$PO/.gitignore"
mkdir -p "$PO/.mtk/workflows"
old_ts="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=10)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
printf '{"workflow_uuid":"wf-old","workflow_type":"implement","status":"active","updated_at":"%s","phase_cursor":"phase-5","results":{"batches_completed":1}}\n' "$old_ts" > "$PO/.mtk/workflows/wf-old.json"
printf '{"workflow_uuid":"wf-done","workflow_type":"implement","status":"completed","updated_at":"%s","phase_cursor":"phase-9","results":{"batches_completed":4}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$PO/.mtk/workflows/wf-done.json"
run "$PO" s-oldwf "$(mktr oldwf 220000)"
expect_silent "stale and completed workflows at 220k (below the generic 300k)"
run "$PO" s-oldwf "$(mktr oldwf2 310000)"
expect_nudge "stale and completed workflows take the generic path" "Mention it once"
case "$NUDGE" in *wf-old*|*wf-done*|*'workflow-artifact.sh'*) fail "a stale or completed workflow must not drive the workflow nudge. Got: $NUDGE" ;; esac
[ "$(telemetry_field "$PO/.mtk/sessions/s-oldwf/telemetry.json" workflow)" = "null" ] || fail "telemetry workflow must be null for stale/completed workflows"
pass "workflow older than 7 days or completed: generic path, no workflow nudge"

run "$P" s-win "$(mktr win 220000)" CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000
expect_nudge "window text" "(55% of the 400k auto-compact window)"
run "$PN" s-win2 "$(mktr win2 330000)" CLAUDE_CODE_AUTO_COMPACT_WINDOW=600000
expect_nudge "window text, generic" "(55% of the 600k auto-compact window)"
pass "nudges state the share of the auto-compact window when it is known"

# Default interval (MTK_CTX_GUARD_INTERVAL unset): the second call inside 20 s is throttled.
dflt() { # <project> <session> <transcript>
  RC=0
  OUT="$(cd "$1" && env -u MTK_CTX_GUARD_INTERVAL HOME="$WORK/home" CLAUDE_PROJECT_DIR="$1" bash "$HOOK" \
    <<<"{\"session_id\":\"$2\",\"transcript_path\":\"$3\",\"cwd\":\"$1\"}" 2>"$WORK/err")" || RC=$?
  ERR="$(cat "$WORK/err")"
}
dflt "$PN" s-dflt "$(mktr d1 100000)"
expect_silent "default interval, first call"
[ "$(telemetry_field "$PN/.mtk/sessions/s-dflt/telemetry.json" context_tokens)" = "100000" ] || fail "first default-interval call must parse"
dflt "$PN" s-dflt "$(mktr d2 900000)"
expect_silent "default interval, second call within 20 s (900k would nudge)"
[ "$(telemetry_field "$PN/.mtk/sessions/s-dflt/telemetry.json" context_tokens)" = "100000" ] || fail "default 20 s throttle must skip the second parse"
pass "default interval: the second call within 20 s is throttled"

# Dedupe-key cap: a keys file with 70 entries is cut back to 64 when a nudge is recorded.
KEYS="$TMPDIR/mtk-context-guard-${UID:-0}-s-cap.keys"
for i in $(seq 1 70); do printf 'step:old-%s|p|0|soft\n' "$i"; done > "$KEYS"
write_wf "$P" "$UUID" phase-cap 0
run "$P" s-cap "$(mktr cap 210000)"
expect_nudge "dedupe cap" "phase phase-cap"
[ "$(wc -l < "$KEYS" | tr -d ' ')" = "64" ] || fail "dedupe keys must be capped at 64, got $(wc -l < "$KEYS")"
case "$(tail -n 1 "$KEYS")" in "step:$UUID|phase-cap|0|soft") : ;; *) fail "the newest key must be kept: $(tail -n 1 "$KEYS")" ;; esac
pass "dedupe keys are capped at 64, newest kept"

# --- 13. hostile session ids and planted symlinks (TR-F013) ----------------------------------
PH="$WORK/hostile"; mkdir -p "$PH"; git -C "$PH" init -q; printf '.mtk/\n' > "$PH/.gitignore"
run "$PH" 'a/../../b' "$(mktr h1 310000)"
expect_nudge "traversal session id" "~310k tokens"
[ -f "$TMPDIR/mtk-context-guard-${UID:-0}-a_.._.._b" ] || fail "state file name must be the sanitised id: $(ls "$TMPDIR")"
[ -d "$PH/.mtk/sessions/a_.._.._b" ] || fail "telemetry dir must be the sanitised id: $(find "$PH/.mtk")"
[ ! -e "$WORK/b" ] && [ ! -e "$PH/b" ] && [ ! -e "$PH/.mtk/b" ] && [ ! -e "$PH/.mtk/sessions/b" ] || fail "a traversal id created a path outside its session dir"
for n in "$TMPDIR"/* "$TMPDIR"/.[!.]*; do [ -e "$n" ] || continue; case "${n#"$TMPDIR"/}" in */*) fail "nested path created in TMPDIR: $n" ;; esac; done
run "$PH" 'my session id' "$(mktr h2 310000)"
expect_nudge "session id with spaces" "~310k tokens"
[ -f "$TMPDIR/mtk-context-guard-${UID:-0}-my_session_id" ] && [ -d "$PH/.mtk/sessions/my_session_id" ] || fail "spaces must be sanitised to underscores"
pass "session ids with ../ or spaces are sanitised; nothing is created outside TMPDIR / the session dir"

printf 'keep\n' > "$WORK/victim"
ln -s "$WORK/victim" "$TMPDIR/mtk-context-guard-${UID:-0}-s-link"
run "$PH" s-link "$(mktr lk 900000)"
expect_silent "symlinked state file"
[ "$(cat "$WORK/victim")" = "keep" ] || fail "a planted state symlink must not be written through"
[ ! -e "$PH/.mtk/sessions/s-link" ] || fail "a symlinked state file disables the guard for the session"
printf 'keep2\n' > "$WORK/victim2"
ln -s "$WORK/victim2" "$TMPDIR/mtk-context-guard-${UID:-0}-s-link2.keys"
run "$PH" s-link2 "$(mktr lk2 900000)"
[ "$(cat "$WORK/victim2")" = "keep2" ] || fail "a planted keys symlink must not be written through"
pass "planted symlinks at the state and keys paths are never written through"

# Large transcript: only the last 512 KB are read; the newest usage line sits at the end.
BIG="$WORK/tr/big.jsonl"
{ assistant 900000; python3 -c 'import sys
line = "{\"type\":\"user\",\"isSidechain\":false,\"message\":{\"role\":\"user\",\"content\":\"" + "x" * 900 + "\"}}\n"
sys.stdout.write(line * 700)'; assistant 310000; user_line; } > "$BIG"
[ "$(wc -c < "$BIG" | tr -d ' ')" -gt 524288 ] || fail "test setup: transcript must exceed 512 KB"
run "$PH" s-big "$BIG"
expect_nudge "transcript over 512 KB" "~310k tokens"
# The only usage line is cut by the tail window: the partial first line is dropped, nothing parsed.
{ python3 -c 'import sys
sys.stdout.write("{\"type\":\"assistant\",\"isSidechain\":false,\"pad\":\"" + "y" * 600000 + "\",\"message\":{\"model\":\"m\",\"usage\":{\"input_tokens\":950000}}}\n")'; user_line; } > "$WORK/tr/partial.jsonl"
run "$PH" s-partial "$WORK/tr/partial.jsonl"
expect_silent "partial first line of the tail"
[ ! -e "$PH/.mtk/sessions/s-partial" ] || fail "a partial first line must be dropped, not parsed"
pass "transcripts over 512 KB: newest usage near the end parses; a cut first line is dropped"

# --- 13b. documented default boundaries (FR2-F010) ---------------------------------------
write_wf "$P" "$UUID" phase-9 4
run "$P" s-b1 "$(mktr bd1 199999)"
expect_silent "199999 with a workflow"
run "$P" s-b1 "$(mktr bd2 200000)"
expect_nudge "200000 with a workflow" "~200k tokens" "Finish the current transition"
run "$P" s-b2 "$(mktr bd3 249999)"
expect_nudge "249999 is soft only" "Finish the current transition"
case "$NUDGE" in *'Do not start new work'*) fail "249999 must not be hard. Got: $NUDGE" ;; esac
run "$P" s-b2 "$(mktr bd4 250000)"
expect_nudge "250000 is hard" "Do not start new work"
run "$PN" s-b3 "$(mktr bd5 299999)"
expect_silent "299999 without a workflow"
run "$PN" s-b3 "$(mktr bd6 300000)"
expect_nudge "300000 without a workflow" "Session context is ~300k tokens"
run "$PN" s-b3 "$(mktr bd7 449999)"
expect_silent "449999 is still band 0"
run "$PN" s-b3 "$(mktr bd8 450000)"
expect_nudge "450000 starts band 1" "Session context is ~450k tokens"
pass "boundaries: 199999/200000 soft, 249999/250000 hard, 299999/300000 generic, band step 449999/450000"

# --- 13c. telemetry pct rounding and ts (FR2-F009) ----------------------------------------
run "$P" s-pct "$(mktr pct 250000)" CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000
TP="$P/.mtk/sessions/s-pct/telemetry.json"
[ "$(telemetry_field "$TP" window)" = "300000" ] || fail "window not recorded: $(cat "$TP")"
[ "$(telemetry_field "$TP" pct)" = "0.8333" ] || fail "pct 250000/300000 must round to 0.8333: $(cat "$TP")"
python3 - "$TP" <<'PY' || fail "telemetry ts is not within 120 s of UTC now: $(cat "$TP")"
import datetime, json, sys
d = json.load(open(sys.argv[1]))
ts = datetime.datetime.strptime(d["ts"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
assert abs((datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds()) < 120, d["ts"]
PY
pass "telemetry: pct rounded to 4 places, ts within 120 s of UTC now"

# --- 13d. real hook in the repo layout wins over CLAUDE_PLUGIN_ROOT (FR2-F011) -----------------
write_wf "$P" "$UUID" phase-9 5
run "$P" s-root "$(mktr root 210000)" CLAUDE_PLUGIN_ROOT="$WORK/plug dir"
expect_nudge "repo layout beats CLAUDE_PLUGIN_ROOT" "bash \"$REPO_ROOT/scripts/workflow-artifact.sh\" checkpoint $UUID --next"
case "$NUDGE" in *'plug dir'*) fail "nudge must not name the CLAUDE_PLUGIN_ROOT copy. Got: $NUDGE" ;; esac
pass "hook in the repo layout names <repo>/scripts/workflow-artifact.sh even with CLAUDE_PLUGIN_ROOT elsewhere"

# --- 14. liveness stamp --------------------------------------------------------------------
SEEN_DIR="$(CLAUDE_PROJECT_DIR="$P" bash -c 'source "$1"; mtk_hook_seen_dir' _ "$REPO_ROOT/hooks/lib/hook-io.sh")" \
  || fail "test setup: no stamp dir"
[ -f "$SEEN_DIR/context-guard.sh" ] || fail "context-guard.sh must stamp liveness in $SEEN_DIR"
pass "liveness stamp refreshed"

[ ! -d "$REPO_ROOT/hooks/lib/__pycache__" ] || fail "the hook left hooks/lib/__pycache__ behind"
pass "no hooks/lib/__pycache__ written"

printf '\ntest-context-guard: all checks passed\n'
