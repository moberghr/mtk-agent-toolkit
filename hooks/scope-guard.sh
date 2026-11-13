#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# PreToolUse hook for Edit, Write, MultiEdit and NotebookEdit.
# Detects scope creep by checking if the file being modified is listed in the
# active spec's change_manifest or test_manifest. The path is normalised
# lexically first, so a `..` segment cannot carry it past an exemption or a
# manifest entry; a path holding a control character is out of the manifest. A
# spec whose manifests are empty (or unreadable) guards nothing — active mode
# says so once per session on stderr — and such a result is never cached.
#
# Advisory only (exit 0) — warns once per file per session (opt-in enforce mode,
# MTK_SCOPE_GUARD_ENFORCE=active or 1, denies every time; =shadow warns and logs
# the would-be deny; =off is silent). No-op when there is no active
# spec JSON sidecar. A sidecar is not active once it shipped: archived into
# docs/specs/baseline/*.audit.jsonl, an archive receipt (<stem>.receipt.md)
# beside it, or only finished workflow artifacts (complete/completed/archived/
# abandoned) referencing it.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"
source "${SCRIPT_DIR}/lib/guard-mode.sh"
source "${SCRIPT_DIR}/lib/normalize-path.sh"
mtk_hook_seen scope-guard.sh

INPUT="$(mtk_read_payload)"
# Before anything else: the session's baseline fingerprint must predate the
# first Edit/Write (verify-completion's "did this session change anything").
mtk_ensure_session_baseline "$INPUT"

# Target path from the tool input JSON: NotebookEdit names it notebook_path;
# Edit, Write and MultiEdit name it file_path. A payload without tool_name
# (another harness) falls back to notebook_path when no file_path is present.
case "$(mtk_extract_tool_name "$INPUT" 2>/dev/null || true)" in
  NotebookEdit) FILE_PATH=$(mtk_extract_tool_field "$INPUT" notebook_path 2>/dev/null || echo "") ;;
  *) FILE_PATH=$(mtk_extract_file_path "$INPUT" 2>/dev/null || echo "") ;;
esac
[ -n "$FILE_PATH" ] || FILE_PATH=$(mtk_extract_tool_field "$INPUT" notebook_path 2>/dev/null || echo "")
[ -z "$FILE_PATH" ] && exit 0

# A control character (newline, tab, CR, …) in the target path is hostile: no
# real source path holds one, and line-oriented handling of it is how
# `<root>/.mtk/x<LF>/../../src/b.cs` once read as workflow state. Such a path is
# never exempt and never a manifest match — it is out of the manifest, under the
# guard's usual modes (active denies, advisory warns, off is silent). DISPLAY_PATH
# shows it with each control character as `?`, so the deny text and the advisory
# JSON stay one clean line. Builtins only: this runs on every edit.
HOSTILE=0
case "$FILE_PATH" in *[[:cntrl:]]*) HOSTILE=1 ;; esac

# Make the path relative to the repo root for comparison. Spelling-robust: a
# plain string strip no-ops when the payload spells the root differently than
# git does (case-insensitive FS, symlinked root), which lands in the `/*` case
# below and FAILS THE GUARD OPEN on every edit. See mtk_repo_relative_path.
# mtk_repo_root prefers $CLAUDE_PROJECT_DIR, so a hook whose cwd is outside the
# repo still resolves the project instead of failing open.
REPO_ROOT="$(mtk_repo_root)"
# Lexical normalisation BEFORE any exemption or manifest match: unnormalised,
# `.mtk/../src/b.cs` read as workflow state and `src/a.cs/../b.cs` as a file
# under the `src/a.cs` entry. A relative path is anchored at the repo root (it
# was always read as repo-relative); one that normalises outside the root stays
# absolute below and is an out-of-repo write, never a repo-relative match.
mtk_normalize_path_var NORM_PATH "$FILE_PATH" "$REPO_ROOT"
REL_PATH="$(mtk_repo_relative_path "$NORM_PATH" "$REPO_ROOT" 2>/dev/null || printf '%s' "$NORM_PATH")"
DISPLAY_PATH="${REL_PATH//[[:cntrl:]]/?}"

# Out-of-repo and workflow-state writes can never be scope violations, so they
# must not trip the guard. A still-absolute REL_PATH means the prefix strip was
# a no-op — FILE_PATH is not under REPO_ROOT (a session scratchpad / temp review
# artifact, /tmp, an absolute path elsewhere). `.mtk/` is durable workflow state
# (batch prompt bundles, artifacts) written outside the change_manifest by
# design. Neither is repo source, so exempt both before manifest matching —
# unless the path is hostile (above), which is never exempt.
if [ "$HOSTILE" -eq 0 ]; then
  case "$REL_PATH" in
    /*|.mtk/*) exit 0 ;;
  esac
fi

# Deterministic skip pointer — checked before any mtime-based spec selection.
# Manifest-less workflows (batch-fix) scope by a findings list, not a file
# manifest, so they drop .mtk/scope-guard-skip while running and this guard
# no-ops. This is immune to the mtime race that anchoring to the "freshest"
# sidecar suffers when a concurrent feature spec is newer than the batch stub.
# Freshness-windowed (4h) so a pointer left by a crashed run ages out instead
# of disabling the guard forever; the owning workflow removes it on completion.
# Anchor .mtk/ the same way workflow state does ($CLAUDE_PROJECT_DIR -> git
# top-level -> cwd) so the pointer is found even from a worktree/sub-dir cwd,
# where the writing workflow anchors it identically.
MTK_STATE_ROOT="$REPO_ROOT"
if [ -n "$(find "${MTK_STATE_ROOT}/.mtk" -maxdepth 1 -name scope-guard-skip -mmin -240 2>/dev/null || true)" ]; then
  exit 0
fi

# Find the active spec JSON sidecar (most recently modified, within 7 days).
# Anchored to the RESOLVED artifact root, not the CWD: in a polyglot repo the
# edited file's subtree may own its own docs/specs, and a bare relative path
# would guard against the wrong project's manifest (or none at all).
ARTIFACT_ROOT="$(mtk_artifact_root "$NORM_PATH" 2>/dev/null || printf '%s' "$REPO_ROOT")"
SPEC_DIR="$ARTIFACT_ROOT/docs/specs"
SPEC_JSON=""
WF_DIR="${MTK_STATE_ROOT}/.mtk/workflows"

# True when the sidecar $1 has shipped or was given up on, so it must not anchor
# the guard. Field run: a new branch got "not in the approved spec" on every
# edit against a spec an earlier, finished feature left inside the 7-day window.
#   - an archive receipt <stem>.receipt.md beside it (implement Phase 7.5)
#   - workflow artifacts that reference it (results.spec_path, same stem) and are
#     all finished; one ACTIVE reference keeps it live
# grep, not python3: this runs per candidate on every Edit/Write.
spec_is_finished() {
  local cand="$1" stem dir wf line st live=0 done_ref=0
  stem="$(basename "$cand" .json)"
  dir="$(dirname "$cand")"
  [ -f "$dir/$stem.receipt.md" ] && return 0
  [ -d "$WF_DIR" ] || return 1
  for wf in "$WF_DIR"/*.json; do
    [ -f "$wf" ] || continue
    line="$(grep -m1 -E '"spec_path"[[:space:]]*:' "$wf" 2>/dev/null || true)"
    case "$line" in
      *"/$stem."*|*"\"$stem."*) ;;
      *) continue ;;
    esac
    st="$(grep -m1 -oE '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$wf" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/' || true)"
    case "$st" in
      complete|completed|archived|abandoned) done_ref=1 ;;
      *) live=1 ;;
    esac
  done
  [ "$live" -eq 0 ] && [ "$done_ref" -eq 1 ]
}

if [ -d "$SPEC_DIR" ]; then
  # Candidates newest-first, sidecars only: -maxdepth 1 keeps out
  # docs/specs/baseline/*.json (spec-archive.sh snapshots) and anything under
  # <slug>.baselines/ or <slug>.evidence/, none of which is a spec.
  #
  # A spec that shipped is archived into docs/specs/baseline/*.audit.jsonl by
  # spec-archive.sh. In a repo that keeps shipped sidecars (this toolkit), the
  # freshest sidecar is usually one of those, and anchoring to it tagged every
  # unrelated edit "not in the approved spec (<shipped-slug>)" (issue #59). An
  # archived slug is no longer active, so skip it and take the next-freshest.
  # Same fixed-string slug probe spec-archive.sh uses for idempotency, minus jq
  # (S3.3): the trail is compact JSON, so `"slug":"<slug>"` is exact.
  while IFS= read -r cand; do
    [ -n "$cand" ] && [ -f "$cand" ] || continue
    slug="$(grep -m1 -o '"slug"[[:space:]]*:[[:space:]]*"[^"]*"' "$cand" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/')"
    if [ -n "$slug" ] && grep -qsF "\"slug\":\"$slug\"" "$SPEC_DIR"/baseline/*.audit.jsonl 2>/dev/null; then
      continue
    fi
    spec_is_finished "$cand" && continue
    SPEC_JSON="$cand"
    break
  done < <(find "$SPEC_DIR" -maxdepth 1 -name '*.json' -type f -mtime -7 2>/dev/null | while read -r f; do
    echo "$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null || echo 0) $f"
  done | sort -rn | cut -d' ' -f2-)
fi

# No active spec — nothing to guard
[ -z "${SPEC_JSON:-}" ] || [ ! -f "$SPEC_JSON" ] && exit 0

# Manifest-less workflows (batch-fix) declare a skip marker: they scope by a
# findings list, not a file manifest, so enforcing one is a false positive.
if grep -Eq '"scope_guard"[[:space:]]*:[[:space:]]*"skip"|"workflow"[[:space:]]*:[[:space:]]*"batch-fix"' "$SPEC_JSON" 2>/dev/null; then
  exit 0
fi

# Use a session cache to avoid re-parsing the spec on every tool call.
# Cache key: spec file path + mtime. The cache holds the parsed manifest only,
# without the defaults appended below (v2: v1 caches carried the defaults, so an
# empty manifest could never read as empty again). Only a manifest that was
# read and is non-empty is cached: a failed parse (spec mid-write, python slow
# or crashing) cached as "nothing" would switch the guard off for that spec
# version, across sessions, even after the spec became readable.
CACHE_DIR="${TMPDIR:-/tmp}"
SPEC_MTIME=$(stat -c '%Y' "$SPEC_JSON" 2>/dev/null || stat -f '%m' "$SPEC_JSON" 2>/dev/null || echo "0")
CACHE_KEY=$(printf '%s-%s' "$SPEC_JSON" "$SPEC_MTIME" | cksum | cut -d' ' -f1)
CACHE_FILE="$CACHE_DIR/mtk-scope-cache-v2-$CACHE_KEY"

MANIFEST_STATE=""   # why ALLOWED_FILES is empty: "empty" (parsed, no entries) | "unreadable"
if [ -f "$CACHE_FILE" ]; then
  ALLOWED_FILES=$(cat "$CACHE_FILE")
else
  # Extract all file paths from change_manifest and test_manifest. python3
  # parses the JSON (entries may be objects with "path" or bare strings) and
  # exits 3 when the spec is not a readable JSON object; the fallback, for a
  # missing or failing python3, is POSIX awk — match() + RSTART/RLENGTH, never
  # gawk's 3-arg match(s, re, arr), which BSD/macOS awk rejects as a syntax error.
  ALLOWED_FILES=""
  PY_RC=127   # 127: no python3
  if command -v python3 >/dev/null 2>&1; then
    PY_RC=0
    ALLOWED_FILES="$(python3 - "$SPEC_JSON" <<'PYEOF' 2>/dev/null
import sys; sys.stdout.reconfigure(newline="\n")  # LF even on Windows python3: bash parses this output
import json
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(3)
if not isinstance(doc, dict):
    sys.exit(3)
for key in ("change_manifest", "test_manifest"):
    for e in (doc.get(key) or []):
        p = e.get("path") if isinstance(e, dict) else e
        if isinstance(p, str) and p:
            print(p)
PYEOF
)" || PY_RC=$?
  fi
  CACHEABLE=0
  if [ "$PY_RC" -eq 0 ]; then
    if [ -n "$ALLOWED_FILES" ]; then CACHEABLE=1; else MANIFEST_STATE="empty"; fi
  else
    # python3 failed (or is absent): drop any partial output and read with awk.
    # An awk result is cached only when there is no python3 to do better; after
    # a python3 failure the spec may be mid-write, so the next call re-reads it.
    ALLOWED_FILES="$(awk '
      /"(change_manifest|test_manifest)"/ { in_section=1 }
      in_section {
        line = $0
        while (match(line, /"path"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
          m = substr(line, RSTART, RLENGTH)
          line = substr(line, RSTART + RLENGTH)
          sub(/^"path"[[:space:]]*:[[:space:]]*"/, "", m)
          sub(/"$/, "", m)
          print m
        }
      }
      in_section && /\]/ { in_section=0 }
    ' "$SPEC_JSON" 2>/dev/null || true)"
    if [ -z "$ALLOWED_FILES" ]; then MANIFEST_STATE="unreadable"
    elif [ "$PY_RC" -eq 127 ]; then CACHEABLE=1; fi
  fi

  # Cache for the session — a failed cache write costs a re-parse, nothing more.
  if [ "$CACHEABLE" -eq 1 ]; then
    { printf '%s\n' "$ALLOWED_FILES" > "$CACHE_FILE"; } 2>/dev/null || true
  fi
fi

SPEC_NAME="${SPEC_JSON##*/}"; SPEC_NAME="${SPEC_NAME%.json}"   # basename, no fork

# No manifest entries — the spec's manifests are empty, or it could not be read.
# Either way the edit is allowed (tested BEFORE the defaults are appended: after
# them it could never fire, and a `change_manifest: []` spec denied every edit).
# In active mode, where the engineer expects enforcement, one stderr line per
# session per spec says scope is not being enforced. Stderr on exit 0 reaches the
# hook log, not the model; no stdout. The dedup store is mtk_advise_gated's
# (one key per line in "$(mtk_session_file).advised", keys namespaced
# scope-guard:…); without a session_id every call reports, as advisories do.
if [ -z "$ALLOWED_FILES" ]; then
  if [ "$(mtk_guard_mode SCOPE_GUARD advisory)" = "active" ]; then
    NOTE_KEY="scope-guard:no-manifest:${SPEC_NAME}"
    NOTE_STORE=""
    [ -n "${_MTK_SESSION_ID:-}" ] && NOTE_STORE="$(mtk_session_file).advised"
    if [ -z "$NOTE_STORE" ] || ! grep -qxF -- "$NOTE_KEY" "$NOTE_STORE" 2>/dev/null; then
      [ -z "$NOTE_STORE" ] || { printf '%s\n' "$NOTE_KEY" >>"$NOTE_STORE"; } 2>/dev/null || true
      case "$MANIFEST_STATE" in
        empty) NOTE_WHY="empty change_manifest and test_manifest" ;;
        *)     NOTE_WHY="the spec could not be parsed" ;;
      esac
      printf '[mtk] scope-guard: active spec %s has no readable change manifest (%s); scope is not being enforced (MTK_SCOPE_GUARD_ENFORCE=active).\n' \
        "$SPEC_NAME" "$NOTE_WHY" >&2 || true
    fi
  fi
  exit 0
fi

# Always allow spec/plan/task files themselves
ALLOWED_FILES="$ALLOWED_FILES
docs/specs/
docs/plans/
tasks/
.claude/"

# Match on exact path or directory prefix only. An entry ending in `/` is a
# directory; any other entry matches itself exactly or as a directory
# (`src/dir` covers `src/dir/x`, never `src/dir2/x`). The old two-way substring
# test let `lib/src/a.cs`, `src/a.cs.bak` and even a bare `a.cs` through for an
# `src/a.cs` entry. Paths are compared relative to the repo root and, when it
# differs, to the artifact root (a subtree's manifest is written against it).
ART_REL=""
if [ "$ARTIFACT_ROOT" != "$REPO_ROOT" ]; then
  ART_REL="$(mtk_repo_relative_path "$NORM_PATH" "$ARTIFACT_ROOT" 2>/dev/null || true)"
fi
path_allowed() { # $1 = relative path to test
  local rel="$1" allowed
  [ -n "$rel" ] || return 1
  while IFS= read -r allowed; do
    allowed="${allowed#./}"
    [ -n "$allowed" ] || continue
    case "$allowed" in
      */) case "$rel" in "$allowed"*) return 0 ;; esac ;;
      *)  [ "$rel" = "$allowed" ] && return 0
          case "$rel" in "$allowed"/*) return 0 ;; esac ;;
    esac
  done <<< "$ALLOWED_FILES"
  return 1
}
MATCHED=0
CTL_NOTE=""
if [ "$HOSTILE" -eq 1 ]; then
  # Never a match, whatever it normalises to (see HOSTILE above).
  CTL_NOTE=" — the path contains a control character (shown as ?), so it is treated as out of the manifest"
elif path_allowed "$REL_PATH" || path_allowed "$ART_REL"; then
  MATCHED=1
fi

if [ "$MATCHED" -eq 0 ]; then
  # Mode from MTK_SCOPE_GUARD_ENFORCE (mtk_guard_mode). Default is advisory
  # (tier-1, exit 0): emit a warning, never block.
  #   active (also the legacy truthy 1/true/yes/on) — a write outside the
  #     approved change_manifest/test_manifest is a HARD DENY (exit 2) with a
  #     single named reason, every time.
  #   shadow — the advisory below as usual, plus one line in
  #     .mtk/metrics/enforcement-shadow.jsonl per would-be deny (every edit, not
  #     deduped), to measure what active mode would block before turning it on.
  #   off — silent.
  # Off-by-default enforcement keeps existing installs and manifest-less flows
  # unaffected.
  SCOPE_MODE="$(mtk_guard_mode SCOPE_GUARD advisory)"
  case "$SCOPE_MODE" in
    off) exit 0 ;;
    active|shadow)
      mtk_deny_gated "$SCOPE_MODE" scope-guard SCOPE-OUT-OF-MANIFEST "MTK_SCOPE_GUARD: DENY ${DISPLAY_PATH} — not in approved manifest (${SPEC_NAME})${CTL_NOTE}. Add it to the spec's change_manifest first, then re-issue this edit." "unset MTK_SCOPE_GUARD_ENFORCE (falls back to advisory warnings)" "$REL_PATH"
      ;;
  esac
  # Advisory: once per file per session. The payload's session_id keys the
  # store (bound by mtk_ensure_session_baseline above); without one there is no
  # session to scope to, so every edit warns as before.
  # mtk_advise_gated owns that dedup; the warning is recorded only when emitted.
  # DISPLAY_PATH, not REL_PATH: the store is one key per line.
  if mtk_advise_gated "$SCOPE_MODE" "PreToolUse" "scope-guard:${DISPLAY_PATH}" "SCOPE GUARD: ${DISPLAY_PATH} is not in the approved spec (${SPEC_NAME})${CTL_NOTE}. If this change is necessary, update the spec's change_manifest first. Undeclared file modifications are the #1 source of spec drift."; then
    mtk_record_scope_guard_warning
  fi
fi

exit 0
