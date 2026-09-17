#!/usr/bin/env bash
set -euo pipefail

# scope-guard.sh anchors to the freshest docs/specs/*.json sidecar within 7 days.
# Issue #59: in a repo that keeps shipped sidecars (this toolkit), the freshest
# one is usually a spec that already shipped and was archived into
# docs/specs/baseline/*.audit.jsonl — so every unrelated edit was tagged
# "not in the approved spec (<shipped-slug>)". Archived slugs must not anchor
# the guard, and the archive's own baseline/*.json snapshots must never be
# mistaken for a spec.
#
#   (a) edit inside the ACTIVE spec's manifest → silent (the shipped spec is
#       newer but archived, so it must not be the anchor)
#   (b) edit outside every manifest → warns, naming the active spec, never the
#       archived one
#   (c) every sidecar archived → no active spec → silent
#   (d) only docs/specs/baseline/*.json present → silent (not a sidecar)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/scope-guard.sh"

echo "=== scope-guard archived-spec Test (#59) ==="
FAILS=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1" >&2; FAILS=$((FAILS + 1)); }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"   # isolates the hook's spec cache + session file

FIX="$WORK/repo"
mkdir -p "$FIX/docs/specs/baseline" "$FIX/src"
git -C "$FIX" init -q
: > "$FIX/src/a.cs"; : > "$FIX/src/shipped.cs"; : > "$FIX/src/other.cs"

sidecar() { # $1=file $2=slug $3=manifest path
  printf '{\n  "slug": "%s",\n  "date": "2026-09-17",\n  "scope": "new-feature",\n  "security_impact": "none",\n  "change_manifest": [\n    {"path": "%s", "action": "modify", "purpose": "t"}\n  ],\n  "success_criteria": []\n}\n' "$2" "$3" > "$1"
}
sidecar "$FIX/docs/specs/2026-09-10-active.json"  "active-feature" "src/a.cs"
sidecar "$FIX/docs/specs/2026-09-16-shipped.json" "shipped-thing"  "src/shipped.cs"
# The archive trail spec-archive.sh appends (compact JSON, one line per slug),
# plus its baseline snapshot — a *.json under docs/specs/ that is NOT a sidecar.
printf '{"slug":"shipped-thing","date":"2026-09-16","verdict":"PASS","archived_at":"2026-09-16T10:00:00Z","adds":["src/shipped.cs"],"removes":[]}\n' \
  > "$FIX/docs/specs/baseline/toolkit.audit.jsonl"
printf '{"files":{"src/shipped.cs":{"action":"modify"}},"history":[]}\n' > "$FIX/docs/specs/baseline/toolkit.json"
# mtimes: active = today 00:00 (inside the 7-day window), shipped + baseline = now.
touch -t "$(date +%Y%m%d)0000" "$FIX/docs/specs/2026-09-10-active.json"
touch "$FIX/docs/specs/2026-09-16-shipped.json" "$FIX/docs/specs/baseline/toolkit.json"

run() { # $1=file under $FIX → stdout of the hook (advisory JSON or empty)
  set +e
  printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$FIX/$1" \
    | ( cd "$FIX" && CLAUDE_PROJECT_DIR="$FIX" bash "$HOOK" 2>/dev/null )
  set -e
}

# --- (a) -----------------------------------------------------------------------
out="$(run src/a.cs)"
if [ -z "$out" ]; then pass "(a) edit inside the active manifest is silent although a newer, archived sidecar exists"
else fail "(a) expected silence for src/a.cs, got: $out"; fi

# --- (b) -----------------------------------------------------------------------
out="$(run src/other.cs)"
case "$out" in
  *"SCOPE GUARD"*"(2026-09-10-active)"*) pass "(b) out-of-manifest edit warns and names the ACTIVE spec" ;;
  *"shipped"*) fail "(b) warning anchored to the archived spec: $out" ;;
  "")          fail "(b) expected a warning for src/other.cs, got silence" ;;
  *)           fail "(b) unexpected output: $out" ;;
esac

# --- (c) -----------------------------------------------------------------------
printf '{"slug":"active-feature","date":"2026-09-17","verdict":"PASS","archived_at":"2026-09-17T10:00:00Z","adds":[],"removes":[]}\n' \
  >> "$FIX/docs/specs/baseline/toolkit.audit.jsonl"
out="$(run src/other.cs)"
if [ -z "$out" ]; then pass "(c) all sidecars archived → no active spec → silent"
else fail "(c) expected silence once every slug is archived, got: $out"; fi

# --- (d) -----------------------------------------------------------------------
rm -f "$FIX/docs/specs/"*.json
out="$(run src/other.cs)"
if [ -z "$out" ]; then pass "(d) baseline/*.json alone never anchors the guard"
else fail "(d) baseline snapshot was treated as a spec: $out"; fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "=== scope-guard archived-spec: ALL PASS ==="
else
  echo "=== scope-guard archived-spec: $FAILS FAILURE(S) ===" >&2
  exit 1
fi
