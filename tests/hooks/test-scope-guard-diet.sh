#!/usr/bin/env bash
set -euo pipefail

# scope-guard.sh runtime diet:
#   (a) the advisory fires once per file per session, not on every edit; a
#       payload without session_id keeps warning (nothing to key on), and the
#       opt-in enforce mode still denies every time
#   (b) a spec whose workflow artifact is complete/completed/archived/abandoned,
#       or that has an archive receipt beside it, does not anchor the guard —
#       field run: it fired on a new branch against a finished earlier spec.
#       A spec an ACTIVE workflow still references keeps guarding.
#   (c) manifest paths are extracted on any awk (no gawk 3-arg match)
#   (d) matching is exact path or directory prefix — never substring either way
#   (e) the project root comes from mtk_repo_root (CLAUDE_PROJECT_DIR first), so
#       a hook whose cwd is outside the repo still guards instead of failing open
#   (f) MTK_SCOPE_GUARD_ENFORCE modes: active (and the legacy truthy set) denies
#       with today's text; shadow warns AND logs to .mtk/metrics; off is silent;
#       advisory/unset is today's behaviour. deny:/allow: labels feed
#       scripts/check-guard-twins.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/scope-guard.sh"

FAILS=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1" >&2; FAILS=$((FAILS + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
unset MTK_SCOPE_GUARD_ENFORCE 2>/dev/null || true

FIX="$WORK/repo"
mkdir -p "$FIX/docs/specs" "$FIX/src/feature" "$FIX/src/feature2" "$FIX/.mtk/workflows"
git -C "$FIX" init -q

SPEC="$FIX/docs/specs/2026-10-01-live.json"
cat > "$SPEC" <<'JSON'
{
  "slug": "live",
  "change_manifest": [
    {"action": "modify", "path": "src/a.cs", "purpose": "t"},
    {"path": "src/feature/", "action": "create", "purpose": "dir with slash"},
    {"path": "src/dir", "action": "create", "purpose": "dir without slash"}
  ],
  "test_manifest": [
    {"covers": ["SC1"], "path": "tests/a_test.cs"}
  ]
}
JSON

run() { # $1=file under $FIX  $2=session id ("" = none)  [$3=cwd]
  local sid="${2:-}" cwd="${3:-$FIX}" payload
  if [ -n "$sid" ]; then
    payload="$(printf '{"session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$sid" "$FIX/$1")"
  else
    payload="$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$FIX/$1")"
  fi
  set +e
  printf '%s' "$payload" | ( cd "$cwd" && CLAUDE_PROJECT_DIR="$FIX" bash "$HOOK" 2>/dev/null )
  set -e
}
warns() { case "$1" in *"SCOPE GUARD"*) return 0 ;; esac; return 1; }

# --- (c) extraction: every manifest path, key order irrelevant ----------------
out="$(run src/a.cs s-c)";            warns "$out" && fail "(c) src/a.cs is in the manifest: $out" || pass "(c) path after another key is extracted"
out="$(run tests/a_test.cs s-c)";     warns "$out" && fail "(c) test_manifest path not extracted: $out" || pass "(c) test_manifest path extracted"

# --- (d) exact or directory-prefix only ----------------------------------------
out="$(run src/a.cs.bak s-d)";        warns "$out" && pass "(d) src/a.cs.bak is not src/a.cs" || fail "(d) prefix of a FILE entry must not match src/a.cs.bak"
out="$(run lib/src/a.cs s-d)";        warns "$out" && pass "(d) lib/src/a.cs is not src/a.cs" || fail "(d) substring match let lib/src/a.cs through"
out="$(run a.cs s-d)";                warns "$out" && pass "(d) a.cs is not src/a.cs" || fail "(d) reverse substring match let a.cs through"
out="$(run src/feature/x.cs s-d)";    warns "$out" && fail "(d) src/feature/ is a directory entry: $out" || pass "(d) directory entry with slash covers its files"
out="$(run src/dir/y.cs s-d)";        warns "$out" && fail "(d) src/dir is a directory entry: $out" || pass "(d) directory entry without slash covers its files"
out="$(run src/dir2/y.cs s-d)";       warns "$out" && pass "(d) src/dir2 is not under src/dir" || fail "(d) src/dir must not cover src/dir2/"
out="$(run src/feature2/x.cs s-d)";   warns "$out" && pass "(d) src/feature2 is not under src/feature/" || fail "(d) src/feature/ must not cover src/feature2/"
out="$(run docs/specs/new.md s-d)";   warns "$out" && fail "(d) docs/specs/ is always allowed: $out" || pass "(d) meta paths stay allowed"

# --- (a) once per file per session ---------------------------------------------
first="$(run src/other.cs s-a)"
second="$(run src/other.cs s-a)"
third="$(run src/another.cs s-a)"
other_session="$(run src/other.cs s-a2)"
warns "$first"  && pass "(a) first out-of-scope edit warns" || fail "(a) first edit must warn"
warns "$second" && fail "(a) second edit of the same file in the same session warned again" || pass "(a) repeat edit in the same session is silent"
warns "$third"  && pass "(a) a different file still warns" || fail "(a) a different file must warn"
warns "$other_session" && pass "(a) another session warns afresh" || fail "(a) dedupe must be per session"
n1="$(run src/nosid.cs '')"; n2="$(run src/nosid.cs '')"
warns "$n1" && warns "$n2" && pass "(a) no session_id: keeps warning" || fail "(a) no session_id must not dedupe (got '$n1' / '$n2')"
# --- (f) guard modes: MTK_SCOPE_GUARD_ENFORCE via mtk_guard_mode -------------
# Labels deny:<code> / allow:<code> are read by scripts/check-guard-twins.sh.
enforce_rc() { # $1=file under $FIX  $2=session id  $3=MTK_SCOPE_GUARD_ENFORCE value; echoes exit code
  local rc=0
  printf '{"session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$2" "$FIX/$1" \
    | ( cd "$FIX" && CLAUDE_PROJECT_DIR="$FIX" MTK_SCOPE_GUARD_ENFORCE="$3" bash "$HOOK" >/dev/null 2>&1 ) || rc=$?
  echo "$rc"
}
enforce_out() { # like run(), with MTK_SCOPE_GUARD_ENFORCE=$3; echoes stdout
  local rc=0 out
  out="$(printf '{"session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$2" "$FIX/$1" \
    | ( cd "$FIX" && CLAUDE_PROJECT_DIR="$FIX" MTK_SCOPE_GUARD_ENFORCE="$3" bash "$HOOK" 2>/dev/null ))" || rc=$?
  printf '%s' "$out"
  return "$rc"
}
log_lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
expect() { # $1 label  $2 want  $3 got
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 — expected $2, got $3"; fi
}

expect "deny:SCOPE-OUT-OF-MANIFEST enforce=1 denies the first out-of-scope edit" 2 "$(enforce_rc src/enf.cs s-e 1)"
expect "deny:SCOPE-OUT-OF-MANIFEST enforce=1 denies the same file again (no dedupe)" 2 "$(enforce_rc src/enf.cs s-e 1)"
expect "deny:SCOPE-OUT-OF-MANIFEST enforce=on (legacy truthy) denies" 2 "$(enforce_rc src/enf-on.cs s-e-on on)"
expect "deny:SCOPE-OUT-OF-MANIFEST enforce=TRUE (legacy truthy) denies" 2 "$(enforce_rc src/enf-true.cs s-e-true TRUE)"
expect "deny:SCOPE-OUT-OF-MANIFEST enforce=YES (legacy truthy) denies" 2 "$(enforce_rc src/enf-yes.cs s-e-yes YES)"
expect "deny:SCOPE-OUT-OF-MANIFEST enforce=Active (mode name, any case) denies" 2 "$(enforce_rc src/enf-act.cs s-e-act Active)"
expect "allow:SCOPE-OUT-OF-MANIFEST enforce=1 lets an in-manifest edit through" 0 "$(enforce_rc src/a.cs s-e-allow 1)"
expect "allow:SCOPE-OUT-OF-MANIFEST enforce=active lets a directory-entry edit through" 0 "$(enforce_rc src/feature/x.cs s-e-allow active)"
expect "allow:SCOPE-OUT-OF-MANIFEST enforce=0 stays advisory (exit 0)" 0 "$(enforce_rc src/enf-zero.cs s-e-zero 0)"

err="$(printf '{"session_id":"s-e-msg","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$FIX/src/enf-msg.cs" \
  | ( cd "$FIX" && CLAUDE_PROJECT_DIR="$FIX" MTK_SCOPE_GUARD_ENFORCE=active bash "$HOOK" 2>&1 >/dev/null ) || true)"
case "$err" in
  *"MTK_SCOPE_GUARD: DENY src/enf-msg.cs — not in approved manifest (2026-10-01-live)"*"disable this guard: unset MTK_SCOPE_GUARD_ENFORCE"*)
    pass "(f) active deny keeps today's reason text and toggle hint" ;;
  *) fail "(f) active deny text changed: $err" ;;
esac

SHADOW_LOG="$FIX/.mtk/metrics/enforcement-shadow.jsonl"
rm -f "$SHADOW_LOG"
rc=0; s1="$(enforce_out src/shadow.cs s-sh shadow)" || rc=$?
expect "(f) shadow: out-of-scope edit is allowed (exit 0)" 0 "$rc"
warns "$s1" && pass "(f) shadow: advisory text still emitted" || fail "(f) shadow must emit the advisory: '$s1'"
n="$(log_lines "$SHADOW_LOG")"
expect "(f) shadow: one log line for the would-be deny" 1 "$n"
grep -q '"hook":"scope-guard","code":"SCOPE-OUT-OF-MANIFEST"' "$SHADOW_LOG" 2>/dev/null \
  && pass "(f) shadow log line names hook and code" || fail "(f) shadow log line malformed: $(cat "$SHADOW_LOG" 2>/dev/null)"
grep -qF 'src/shadow.cs' "$SHADOW_LOG" 2>/dev/null \
  && fail "(f) shadow log must not carry the raw path" || pass "(f) shadow log carries a checksum, not the path"
rc=0; s2="$(enforce_out src/shadow.cs s-sh shadow)" || rc=$?
warns "$s2" && fail "(f) shadow: advisory must stay once per file per session" || pass "(f) shadow: repeat advisory deduped"
n="$(log_lines "$SHADOW_LOG")"
expect "(f) shadow: every would-be deny is logged (not deduped)" 2 "$n"
rm -f "$SHADOW_LOG"
enforce_out src/a.cs s-sh shadow >/dev/null || true
[ ! -e "$SHADOW_LOG" ] && pass "(f) shadow: in-manifest edit logs nothing" || fail "(f) shadow logged an in-manifest edit"

rc=0; o1="$(enforce_out src/off.cs s-off off)" || rc=$?
expect "(f) off: exit 0" 0 "$rc"
[ -z "$o1" ] && [ ! -e "$SHADOW_LOG" ] && pass "(f) off: silent, nothing logged" || fail "(f) off must be silent: '$o1'"

rc=0; a1="$(enforce_out src/adv.cs s-adv advisory)" || rc=$?
warns "$a1" && [ ! -e "$SHADOW_LOG" ] && pass "(f) advisory: warns, nothing logged" || fail "(f) advisory changed: '$a1'"

# --- (e) cwd outside the repo --------------------------------------------------
OUTSIDE="$WORK/outside"; mkdir -p "$OUTSIDE"
out="$(run src/far.cs s-cwd "$OUTSIDE")"
warns "$out" && pass "(e) cwd outside the repo still guards (mtk_repo_root)" || fail "(e) hook failed open with cwd outside the repo: '$out'"

# --- (b) finished specs do not anchor -------------------------------------------
wf() { # $1 uuid  $2 status  $3 spec_path
  cat > "$FIX/.mtk/workflows/$1.json" <<EOF
{
  "workflow_uuid": "$1",
  "workflow_type": "BUILD",
  "status": "$2",
  "phase_cursor": "phase-7",
  "results": {
    "spec_path": "$3"
  }
}
EOF
}
for st in complete completed archived abandoned; do
  rm -f "$FIX/.mtk/workflows/"*.json
  wf "wf-$st" "$st" "docs/specs/2026-10-01-live.md"
  out="$(run src/b-$st.cs "s-b-$st")"
  warns "$out" && fail "(b) status=$st spec still anchors the guard: $out" || pass "(b) status=$st workflow retires its spec"
done

rm -f "$FIX/.mtk/workflows/"*.json
wf wf-done completed "docs/specs/2026-10-01-live.md"
wf wf-live active    "docs/specs/2026-10-01-live.md"
out="$(run src/b-active.cs s-b-active)"
warns "$out" && pass "(b) an active workflow keeps the spec live" || fail "(b) active workflow must keep guarding"

rm -f "$FIX/.mtk/workflows/"*.json
wf wf-other completed "docs/specs/2026-09-01-unrelated.md"
out="$(run src/b-unrelated.cs s-b-unrel)"
warns "$out" && pass "(b) a finished UNRELATED workflow does not retire this spec" || fail "(b) unrelated workflow retired the spec"

rm -f "$FIX/.mtk/workflows/"*.json
printf '# receipt\n' > "$FIX/docs/specs/2026-10-01-live.receipt.md"
out="$(run src/b-receipt.cs s-b-receipt)"
warns "$out" && fail "(b) a spec with an archive receipt still anchors: $out" || pass "(b) archive receipt retires the spec"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "=== scope-guard diet: ALL PASS ==="
else
  echo "=== scope-guard diet: $FAILS FAILURE(S) ===" >&2
  exit 1
fi
