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
# The *_rc helpers leave the hook's stderr in $LAST_ERR, which reason() reads.
LAST_ERR="$WORK/last.err"
LAST_OUT="$WORK/last.out"
reason() { # $1 label  $2 text the previous run's stderr must carry
  if grep -qF -- "$2" "$LAST_ERR" 2>/dev/null; then pass "$1"; else fail "$1 — stderr: $(cat "$LAST_ERR" 2>/dev/null)"; fi
}
enforce_rc() { # $1=file under $FIX  $2=session id  $3=MTK_SCOPE_GUARD_ENFORCE value; echoes exit code
  local rc=0
  printf '{"session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$2" "$FIX/$1" \
    | ( cd "$FIX" && CLAUDE_PROJECT_DIR="$FIX" MTK_SCOPE_GUARD_ENFORCE="$3" bash "$HOOK" >/dev/null 2>"$LAST_ERR" ) || rc=$?
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

# --- (g) the path is normalised lexically before any exemption or manifest match --
# A `..` segment must not carry an out-of-manifest file past the .mtk/,
# docs/specs/, tasks/, .claude/ exemptions or a FILE entry used as a directory.
# None of these files exist: normalisation is lexical.
expect "deny:SCOPE-OUT-OF-MANIFEST .mtk/../src/b.cs is src/b.cs" 2 "$(enforce_rc .mtk/../src/b.cs s-g active)"
reason "(g) the deny names the normalised path and the reason code's text" \
  "MTK_SCOPE_GUARD: DENY src/b.cs — not in approved manifest (2026-10-01-live)"
expect "deny:SCOPE-OUT-OF-MANIFEST docs/specs/../../src/b.cs is src/b.cs" 2 "$(enforce_rc docs/specs/../../src/b.cs s-g active)"
expect "deny:SCOPE-OUT-OF-MANIFEST src/a.cs/../b.cs is src/b.cs" 2 "$(enforce_rc src/a.cs/../b.cs s-g active)"
expect "deny:SCOPE-OUT-OF-MANIFEST .claude/../src/b.cs is src/b.cs" 2 "$(enforce_rc .claude/../src/b.cs s-g active)"
expect "deny:SCOPE-OUT-OF-MANIFEST tasks/../src/b.cs is src/b.cs" 2 "$(enforce_rc tasks/../src/b.cs s-g active)"
expect "deny:SCOPE-OUT-OF-MANIFEST src/feature/../../src/b.cs leaves the directory entry" 2 \
  "$(enforce_rc src/feature/../../src/b.cs s-g active)"
expect "deny:SCOPE-OUT-OF-MANIFEST a path that leaves the root and re-enters it is still guarded" 2 \
  "$(enforce_rc "src/../../$(basename "$FIX")/src/b.cs" s-g active)"
expect "allow:SCOPE-OUT-OF-MANIFEST src/x/../a.cs is the manifest's src/a.cs" 0 "$(enforce_rc src/x/../a.cs s-g active)"
expect "allow:SCOPE-OUT-OF-MANIFEST src/./a.cs and a doubled slash are src/a.cs" 0 "$(enforce_rc src/.//a.cs s-g active)"
expect "allow:SCOPE-OUT-OF-MANIFEST src/b.cs/../../docs/specs/new.md is a spec file" 0 \
  "$(enforce_rc src/b.cs/../../docs/specs/new.md s-g active)"
expect "allow:SCOPE-OUT-OF-MANIFEST .mtk/./state.json stays workflow state" 0 "$(enforce_rc .mtk/./state.json s-g active)"
rel_rc() { # $1=relative file_path (as sent); echoes the exit code under enforce=active
  local rc=0
  printf '{"session_id":"s-g-rel","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1" \
    | ( cd "$FIX" && CLAUDE_PROJECT_DIR="$FIX" MTK_SCOPE_GUARD_ENFORCE=active bash "$HOOK" >/dev/null 2>"$LAST_ERR" ) || rc=$?
  echo "$rc"
}
expect "deny:SCOPE-OUT-OF-MANIFEST relative tasks/../src/b.cs is src/b.cs" 2 "$(rel_rc tasks/../src/b.cs)"
expect "allow:SCOPE-OUT-OF-MANIFEST relative src/./a.cs is src/a.cs" 0 "$(rel_rc src/./a.cs)"
expect "(g) a path that escapes the repo root is out of the repo, not a manifest match" 0 \
  "$(enforce_rc .mtk/../../elsewhere/x.cs s-g active)"

# --- (h) an empty or unreadable manifest guards nothing ---------------------------
# Defaults (docs/specs/, tasks/, …) are appended after the emptiness check, so a
# spec with nothing to scope against no longer denies every edit.
EMPTY="$WORK/repo-empty"
mkdir -p "$EMPTY/docs/specs" "$EMPTY/src"
git -C "$EMPTY" init -q
empty_rc() { # $1=case name  $2=spec body  $3=file under $EMPTY; echoes exit code under enforce=active
  rm -f "$EMPTY/docs/specs/"*.json
  printf '%s\n' "$2" > "$EMPTY/docs/specs/2026-10-02-$1.json"
  local rc=0
  printf '{"session_id":"s-h","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$EMPTY/$3" \
    | ( cd "$EMPTY" && CLAUDE_PROJECT_DIR="$EMPTY" MTK_SCOPE_GUARD_ENFORCE=active bash "$HOOK" >/dev/null 2>"$LAST_ERR" ) || rc=$?
  echo "$rc"
}
expect "allow:SCOPE-OUT-OF-MANIFEST change_manifest [] and test_manifest [] guard nothing" 0 \
  "$(empty_rc both-empty '{"slug":"e1","change_manifest":[],"test_manifest":[]}' src/x.cs)"
expect "allow:SCOPE-OUT-OF-MANIFEST change_manifest [] alone guards nothing" 0 \
  "$(empty_rc change-empty '{"slug":"e2","change_manifest":[]}' src/x.cs)"
expect "allow:SCOPE-OUT-OF-MANIFEST an unparseable spec guards nothing" 0 \
  "$(empty_rc unparseable '{ "slug": "e3", "change_manifest": [ this is not json' src/x.cs)"
expect "deny:SCOPE-OUT-OF-MANIFEST change_manifest [] with a test_manifest entry still guards" 2 \
  "$(empty_rc tests-only '{"slug":"e4","change_manifest":[],"test_manifest":[{"path":"tests/t.cs"}]}' src/x.cs)"
reason "(h) a test_manifest-only spec denies with the out-of-manifest text" \
  "MTK_SCOPE_GUARD: DENY src/x.cs — not in approved manifest (2026-10-02-tests-only)"
expect "allow:SCOPE-OUT-OF-MANIFEST change_manifest [] with a test_manifest entry allows that entry" 0 \
  "$(empty_rc tests-only-in '{"slug":"e5","change_manifest":[],"test_manifest":[{"path":"tests/t.cs"}]}' tests/t.cs)"
expect "allow:SCOPE-OUT-OF-MANIFEST a non-empty manifest still allows the default docs/specs/" 0 \
  "$(empty_rc defaults '{"slug":"e6","change_manifest":[{"path":"src/a.cs"}]}' docs/specs/x.md)"

# --- (i) MultiEdit and NotebookEdit are guarded like Edit ------------------------
tool_rc() { # $1=tool  $2=path key  $3=file under $FIX; echoes the exit code under enforce=active
  local rc=0 extra=""
  [ "$1" = MultiEdit ] && extra=',"edits":[{"old_string":"a","new_string":"b"}]'
  [ "$1" = NotebookEdit ] && extra=',"new_source":"x = 1","edit_mode":"replace"'
  printf '{"session_id":"s-i","tool_name":"%s","tool_input":{"%s":"%s"%s}}' "$1" "$2" "$FIX/$3" "$extra" \
    | ( cd "$FIX" && CLAUDE_PROJECT_DIR="$FIX" MTK_SCOPE_GUARD_ENFORCE=active bash "$HOOK" >/dev/null 2>"$LAST_ERR" ) || rc=$?
  echo "$rc"
}
expect "deny:SCOPE-OUT-OF-MANIFEST NotebookEdit outside the manifest (notebook_path)" 2 \
  "$(tool_rc NotebookEdit notebook_path notebooks/explore.ipynb)"
reason "(i) a NotebookEdit deny names the notebook" \
  "MTK_SCOPE_GUARD: DENY notebooks/explore.ipynb — not in approved manifest (2026-10-01-live)"
# Another harness may send no tool_name at all: a payload carrying only
# notebook_path is still read and guarded.
nt_rc() { # $1=file under $FIX; payload without tool_name; echoes the exit code under enforce=active
  local rc=0
  printf '{"session_id":"s-i-nt","tool_input":{"notebook_path":"%s","new_source":"x = 1"}}' "$FIX/$1" \
    | ( cd "$FIX" && CLAUDE_PROJECT_DIR="$FIX" MTK_SCOPE_GUARD_ENFORCE=active bash "$HOOK" >/dev/null 2>"$LAST_ERR" ) || rc=$?
  echo "$rc"
}
expect "deny:SCOPE-OUT-OF-MANIFEST no tool_name, notebook_path only, outside the manifest" 2 \
  "$(nt_rc notebooks/other.ipynb)"
reason "(i) the no-tool_name deny names the notebook" "MTK_SCOPE_GUARD: DENY notebooks/other.ipynb"
expect "allow:SCOPE-OUT-OF-MANIFEST no tool_name, notebook_path only, inside a directory entry" 0 \
  "$(nt_rc src/feature/other.ipynb)"
expect "deny:SCOPE-OUT-OF-MANIFEST NotebookEdit with a .. segment out of a directory entry" 2 \
  "$(tool_rc NotebookEdit notebook_path src/feature/../../notebooks/explore.ipynb)"
expect "allow:SCOPE-OUT-OF-MANIFEST NotebookEdit inside a manifest directory entry" 0 \
  "$(tool_rc NotebookEdit notebook_path src/feature/explore.ipynb)"
expect "deny:SCOPE-OUT-OF-MANIFEST MultiEdit outside the manifest" 2 "$(tool_rc MultiEdit file_path src/multi.cs)"
expect "allow:SCOPE-OUT-OF-MANIFEST MultiEdit of a manifest file" 0 "$(tool_rc MultiEdit file_path src/a.cs)"
# Registration: the PreToolUse block that runs scope-guard.sh fires on all four.
wired="$(python3 - "$REPO_ROOT/hooks/hooks.json" <<'PY'
import json, re, sys
hooks = json.load(open(sys.argv[1])).get("hooks", {})
for block in hooks.get("PreToolUse", []) or []:
    if any(h.get("command", "").rstrip().rstrip('"').endswith("/hooks/scope-guard.sh") for h in block.get("hooks", []) or []):
        m = block.get("matcher") or ""
        missing = [t for t in ("Edit", "Write", "MultiEdit", "NotebookEdit") if not re.fullmatch(m, t)]
        print("missing " + ",".join(missing) if missing else "ok")
        sys.exit(0)
print("unregistered")
PY
)"
expect "(i) scope-guard.sh PreToolUse matcher covers Edit, Write, MultiEdit, NotebookEdit" ok "$wired"

# --- (j) a control character in the target path is hostile ----------------------
# `read` stops at a newline, so the old normaliser kept only the first line:
# `<root>/.mtk/x<LF>/../../src/b.cs` read as `.mtk/x` (exempt) and was allowed.
# The payloads are built by json.dumps, so file_path / notebook_path carry a real
# JSON `\n` / `\t` / `\r` escape that the hook's own extraction decodes. A path
# with a control character is out of the manifest whatever it normalises to —
# never exempt, never a match — under the guard's usual modes.
jpayload() { # $1 tool ("" = no tool_name)  $2 path key  $3 path  $4 session id
  python3 -c '
import json, sys
tool, key, path, sid = sys.argv[1:5]
d = {"session_id": sid, "tool_input": {key: path}}
if tool:
    d["tool_name"] = tool
print(json.dumps(d))' "$1" "$2" "$3" "$4"
}
ctl_rc() { # $1 tool  $2 path key  $3 absolute path  $4 mode  $5 session; stdout → $LAST_OUT, stderr → $LAST_ERR
  local rc=0 p
  p="$(jpayload "$1" "$2" "$3" "$5")"
  case "$p" in *'\n'*|*'\t'*|*'\r'*) ;; *) fail "(j) payload carries no JSON control escape: $p" ;; esac
  printf '%s' "$p" \
    | ( cd "$FIX" && CLAUDE_PROJECT_DIR="$FIX" MTK_SCOPE_GUARD_ENFORCE="$4" bash "$HOOK" >"$LAST_OUT" 2>"$LAST_ERR" ) || rc=$?
  echo "$rc"
}
LF=$'\n'; TAB=$'\t'; CR=$'\r'
expect "deny:SCOPE-OUT-OF-MANIFEST Edit .mtk/x<LF>/../../src/b.cs (newline past the .mtk exemption)" 2 \
  "$(ctl_rc Edit file_path "$FIX/.mtk/x${LF}/../../src/b.cs" active s-j)"
reason "(j) the control-character deny says why" "control character"
expect "deny:SCOPE-OUT-OF-MANIFEST Edit docs/specs/x<LF>/../../../src/b.cs (newline past the docs/specs exemption)" 2 \
  "$(ctl_rc Edit file_path "$FIX/docs/specs/x${LF}/../../../src/b.cs" active s-j)"
expect "deny:SCOPE-OUT-OF-MANIFEST NotebookEdit .mtk/x<LF>/../../src/b.cs" 2 \
  "$(ctl_rc NotebookEdit notebook_path "$FIX/.mtk/x${LF}/../../src/b.cs" active s-j)"
expect "deny:SCOPE-OUT-OF-MANIFEST NotebookEdit docs/specs/x<LF>/../../../src/b.cs" 2 \
  "$(ctl_rc NotebookEdit notebook_path "$FIX/docs/specs/x${LF}/../../../src/b.cs" active s-j)"
expect "deny:SCOPE-OUT-OF-MANIFEST no tool_name, notebook_path .mtk/x<LF>/../../src/b.cs" 2 \
  "$(ctl_rc "" notebook_path "$FIX/.mtk/x${LF}/../../src/b.cs" active s-j)"
expect "deny:SCOPE-OUT-OF-MANIFEST a newline path that normalises onto a manifest file is not a match" 2 \
  "$(ctl_rc Edit file_path "$FIX/src/x${LF}/../a.cs" active s-j)"
expect "deny:SCOPE-OUT-OF-MANIFEST a newline inside .mtk/ is not exempt" 2 \
  "$(ctl_rc Edit file_path "$FIX/.mtk/state${LF}.json" active s-j)"
expect "deny:SCOPE-OUT-OF-MANIFEST a tab in the file name" 2 \
  "$(ctl_rc Edit file_path "$FIX/src/feature/a${TAB}.cs" active s-j)"
expect "deny:SCOPE-OUT-OF-MANIFEST a carriage return after a manifest file" 2 \
  "$(ctl_rc Edit file_path "$FIX/src/a.cs${CR}" active s-j)"
ctl_out_ok() { # $1 label — $LAST_OUT is one valid JSON advisory with no raw control character
  if python3 -c '
import json, sys
s = open(sys.argv[1]).read().strip()
ctx = json.loads(s)["hookSpecificOutput"]["additionalContext"]
sys.exit(0 if "SCOPE GUARD" in ctx and not any(ord(c) < 32 for c in ctx) else 1)' "$LAST_OUT" 2>/dev/null; then
    pass "$1"
  else
    fail "$1 — stdout: $(cat "$LAST_OUT" 2>/dev/null)"
  fi
}
expect "(j) advisory: a newline path is allowed with a warning (exit 0)" 0 \
  "$(ctl_rc Edit file_path "$FIX/.mtk/x${LF}/../../src/b.cs" advisory s-j-adv)"
ctl_out_ok "(j) advisory: the warning is valid JSON and shows no raw control character"
expect "(j) advisory: a newline inside .mtk/ is warned about, not exempt" 0 \
  "$(ctl_rc Edit file_path "$FIX/.mtk/state${LF}.json" advisory s-j-adv)"
ctl_out_ok "(j) advisory: the .mtk/ newline path is warned about"
expect "(j) off: a newline path stays silent (exit 0)" 0 \
  "$(ctl_rc Edit file_path "$FIX/.mtk/x${LF}/../../src/b.cs" off s-j-off)"
[ ! -s "$LAST_OUT" ] && pass "(j) off: no output" || fail "(j) off must be silent: $(cat "$LAST_OUT")"
# Spaces and glob characters are ordinary segment text: no IFS split, no globbing.
mkdir -p "$FIX/src/feature/sub"; : > "$FIX/src/feature/sub/match.cs"
expect "allow:SCOPE-OUT-OF-MANIFEST spaces and glob characters inside a directory entry" 0 \
  "$(enforce_rc 'src/feature/a b*?[x].cs' s-j active)"
expect "deny:SCOPE-OUT-OF-MANIFEST a glob that would match a manifest file is not expanded" 2 \
  "$(enforce_rc 'src/*' s-j active)"

# --- (k) mtk_normalize_path: unit cases ---------------------------------------------
NORM_LIB="$REPO_ROOT/hooks/lib/normalize-path.sh"
norm_is() { # $1 label  $2 want  $3 path  [$4 base]: both the printing and the _var form
  local got gotv
  got="$(cd "$WORK" && bash -c '. "$1"; mtk_normalize_path "$2" ${3:+"$3"}; printf .' _ "$NORM_LIB" "$3" "${4:-}" 2>&1)" || got="ERR:$got"
  got="${got%.}"
  gotv="$(cd "$WORK" && bash -c '. "$1"; mtk_normalize_path_var r "$2" ${3:+"$3"}; printf "%s." "$r"' _ "$NORM_LIB" "$3" "${4:-}" 2>&1)" || gotv="ERR:$gotv"
  gotv="${gotv%.}"
  if [ "$got" = "$2" ] && [ "$gotv" = "$2" ]; then pass "(k) $1"
  else fail "(k) $1 — want [$(printf '%q' "$2")], got [$(printf '%q' "$got")] / _var [$(printf '%q' "$gotv")]"; fi
}
: > "$WORK/glob-target.cs"
norm_is "a newline segment is popped by .., not a line break" "/r/src/b.cs" "/r/.mtk/x${LF}/../../src/b.cs"
norm_is "a newline inside a kept segment is kept" "/r/src/a${LF}b.cs" "/r/src/a${LF}b.cs"
norm_is "a tab inside a segment is kept" "/r/src/a${TAB}b.cs" "/r/src/a${TAB}b.cs"
norm_is "a tab segment is popped by .." "/r/c.cs" "/r/src/a${TAB}b/../../c.cs"
norm_is "trailing slash dropped" "/r/src" "/r/src/"
norm_is "doubled slashes collapse" "/r/src/a.cs" "//r//src///a.cs"
norm_is ".. above the root stays at /" "/etc/x" "/../../etc/x"
norm_is "/.. is /" "/" "/.."
norm_is "relative path anchored at the base" "/base/lib/a.cs" "src/../lib/a.cs" "/base"
norm_is "relative ./ path anchored at the base" "/base/a.cs" "./a.cs" "/base"
norm_is "spaces are segment text" "/r/my dir/a b.cs" "/r/my dir/./a b.cs"
norm_is "glob characters are not expanded" "$WORK/*.cs" "$WORK/sub/../*.cs"
norm_is "bracket and ? globs are not expanded" "/r/[a]/?.cs" "/r/[a]/x/../?.cs"
norm_is "IFS characters are not separators" "/r/a:b,c d" "/r/a:b,c d"
norm_is "a dot-dot-dot segment is a name" "/r/.../a" "/r/.../a"
got="$(bash -c '. "$1"; mtk_normalize_path_var r "/r/src/a.cs$2"; printf "%s." "$r"' _ "$NORM_LIB" "$LF" 2>&1)" || got="ERR:$got"
[ "${got%.}" = "/r/src/a.cs${LF}" ] && pass "(k) _var keeps a trailing newline that \$(…) would strip" \
  || fail "(k) _var lost the trailing newline: [$(printf '%q' "${got%.}")]"

# --- (l) a manifest that could not be read is not cached, and active mode says so ---
# A failed parse (spec mid-write, python slow or missing) used to be cached as
# "no manifest" under the spec's path+mtime key, which switched the guard off for
# that spec version across sessions. Neither a failed parse nor an empty result
# is cached; both allow the edit, and active mode writes one stderr line per
# session (advisory, shadow and off: nothing — those modes already allow the
# edit, and active is the mode whose engineer expects enforcement). No stdout.
P2="$WORK/repo-p2"; P2TMP="$WORK/tmp-p2"
mkdir -p "$P2/docs/specs" "$P2/src" "$P2TMP"
git -C "$P2" init -q
P2SPEC="$P2/docs/specs/2026-10-03-p2.json"
# Today 00:00: inside the 7-day window, and never the mtime a later plain `touch` gives.
touch -t "$(date +%Y%m%d)0000" "$WORK/p2-mtime-ref"
p2_rc() { # $1 file under $P2  $2 session  $3 mode; stdout → $LAST_OUT, stderr → $LAST_ERR; echoes rc
  local rc=0
  printf '{"session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$2" "$P2/$1" \
    | ( cd "$P2" && TMPDIR="$P2TMP" CLAUDE_PROJECT_DIR="$P2" MTK_SCOPE_GUARD_ENFORCE="$3" bash "$HOOK" >"$LAST_OUT" 2>"$LAST_ERR" ) || rc=$?
  echo "$rc"
}
p2_caches() { find "$P2TMP" -maxdepth 1 -name 'mtk-scope-cache-*' 2>/dev/null | wc -l | tr -d ' '; }
# The spec is caught mid-write: truncated JSON with no complete entry.
printf '{"slug":"p2","change_manifest":[{"pa' > "$P2SPEC"
touch -r "$WORK/p2-mtime-ref" "$P2SPEC"
expect "allow:SCOPE-OUT-OF-MANIFEST a spec caught mid-write allows the edit" 0 "$(p2_rc src/x.cs s-l1 active)"
reason "(l) active: the unreadable manifest is reported on stderr" "has no readable change manifest"
[ ! -s "$LAST_OUT" ] && pass "(l) active: no stdout for the unreadable-manifest notice" || fail "(l) stdout: $(cat "$LAST_OUT")"
expect "(l) a failed parse writes no cache" 0 "$(p2_caches)"
# The write completes within the same mtime second: same path, same mtime, same cache key.
printf '{"slug":"p2","change_manifest":["src/a.cs"]}\n' > "$P2SPEC"
touch -r "$WORK/p2-mtime-ref" "$P2SPEC"
expect "deny:SCOPE-OUT-OF-MANIFEST the next parse of the same spec version enforces" 2 "$(p2_rc src/x.cs s-l1 active)"
reason "(l) the deny after recovery is the out-of-manifest deny" "MTK_SCOPE_GUARD: DENY src/x.cs — not in approved manifest (2026-10-03-p2)"
expect "(l) a successful parse is cached" 1 "$(p2_caches)"
expect "allow:SCOPE-OUT-OF-MANIFEST the recovered manifest still allows its own file" 0 "$(p2_rc src/a.cs s-l1 active)"
# A genuinely empty manifest: allowed, reported once per session in active mode, not cached.
printf '{"slug":"p2e","change_manifest":[],"test_manifest":[]}\n' > "$P2SPEC"
touch "$P2SPEC"
before_caches="$(p2_caches)"
expect "(l) empty manifest, active: allowed" 0 "$(p2_rc src/x.cs s-l2 active)"
reason "(l) empty manifest, active: first edit reports it" "has no readable change manifest (empty"
expect "(l) an empty manifest writes no cache" "$before_caches" "$(p2_caches)"
expect "(l) empty manifest, active: second edit allowed" 0 "$(p2_rc src/y.cs s-l2 active)"
[ ! -s "$LAST_ERR" ] && pass "(l) empty manifest, active: reported once per session" \
  || fail "(l) the notice repeated in the same session: $(cat "$LAST_ERR")"
expect "(l) empty manifest, active, new session: allowed" 0 "$(p2_rc src/x.cs s-l3 active)"
reason "(l) a new session gets the notice again" "has no readable change manifest"
for m in advisory shadow off; do
  expect "(l) empty manifest, $m: allowed" 0 "$(p2_rc src/x.cs "s-l-$m" "$m")"
  [ ! -s "$LAST_ERR" ] && [ ! -s "$LAST_OUT" ] && pass "(l) empty manifest, $m: no notice, no output" \
    || fail "(l) $m mode printed: out=[$(cat "$LAST_OUT")] err=[$(cat "$LAST_ERR")]"
done

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
