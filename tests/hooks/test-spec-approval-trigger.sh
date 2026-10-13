#!/usr/bin/env bash
set -euo pipefail

# spec-approval-trigger.sh (PostToolUse Edit|Write) speaks directly to the model:
#   - a spec newly carrying `- **Status:** approved` emits a PostToolUse
#     additionalContext envelope naming planning-and-task-breakdown and the spec
#   - re-editing a spec HEAD already has as approved emits nothing
#   - a sealed spec edited after approval emits a STALE-seal advisory; an
#     unsealed spec edit does not
#   - nothing is written to the retired .claude/queue/ (no tier-2 queue)
# Runs in a throwaway git repo: it commits there, never in this checkout.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TRIGGER="$REPO_ROOT/hooks/spec-approval-trigger.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git -C "$WORK" init -q
git -C "$WORK" config user.email t@example.com
git -C "$WORK" config user.name t
mkdir -p "$WORK/docs/specs"
: > "$WORK/README.md"
git -C "$WORK" add README.md
git -C "$WORK" commit -qm init
cd "$WORK"
export CLAUDE_PROJECT_DIR="$WORK"

fire() { # $1 = path relative to $WORK → hook stdout
  printf '{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$WORK/$1" \
    | bash "$TRIGGER" 2>/dev/null || true
}

# --- 1. fresh approval → additionalContext ------------------------------------
SPEC="docs/specs/2026-10-12-approved.md"
printf -- '# Test Spec\n\n- **Status:** approved\n' > "$SPEC"
out="$(fire "$SPEC")"
case "$out" in *'"hookEventName":"PostToolUse"'*'"additionalContext"'*) : ;; *) fail "approval must emit a PostToolUse additionalContext envelope. Got: $out" ;; esac
case "$out" in *planning-and-task-breakdown*) : ;; *) fail "advisory must name planning-and-task-breakdown. Got: $out" ;; esac
case "$out" in *"$SPEC"*) : ;; *) fail "advisory must name the spec path. Got: $out" ;; esac
printf '  PASS  newly-approved spec emits additionalContext naming the next skill and the spec\n'

[ ! -e "$WORK/.claude/queue" ] || fail "no tier-2 queue entry may be written (.claude/queue exists)"
[ ! -e "$REPO_ROOT/.claude/queue/spec-approval-trigger-2026-10-12-approved.json" ] || fail "queue entry written in the toolkit checkout"
printf '  PASS  no queue entry written\n'

# --- 2. already approved in HEAD → silent -------------------------------------
git add -- "$SPEC"
git commit -qm 'approved spec'
out="$(fire "$SPEC")"
[ -z "$out" ] || fail "re-edit of an already-approved spec must be silent. Got: $out"
printf '  PASS  re-edit of already-approved spec stays silent\n'

# --- 3. stale approval seal → STALE advisory; unsealed edit → nothing ----------
SEAL_SPEC="docs/specs/2026-10-12-sealed.md"
printf -- '# Sealed Spec\n\napproved body v1\n' > "$SEAL_SPEC"
WF="$(bash "$REPO_ROOT/scripts/workflow-artifact.sh" init BUILD --goal 'seal hook test')"
bash "$REPO_ROOT/scripts/workflow-artifact.sh" seal "$WF" "$SEAL_SPEC" >/dev/null
printf 'EDITED body v2\n' >> "$SEAL_SPEC"
out="$(fire "$SEAL_SPEC")"
case "$out" in *'"additionalContext"'*'seal STALE'*) : ;; *) fail "stale-sealed spec edit must emit a STALE advisory. Got: $out" ;; esac
case "$out" in *"$WF"*) : ;; *) fail "STALE advisory must name the workflow. Got: $out" ;; esac
printf '  PASS  stale-sealed spec edit emits a STALE advisory\n'

UNRELATED="docs/specs/2026-10-12-unsealed.md"
printf -- '# Unsealed\n' > "$UNRELATED"
out="$(fire "$UNRELATED")"
case "$out" in *'seal STALE'*) fail "unsealed spec edit raised a stale-seal advisory. Got: $out" ;; esac
printf '  PASS  unsealed spec edit raises no stale-seal advisory\n'

# --- 4. non-spec paths are ignored ---------------------------------------------
printf -- '- **Status:** approved\n' > notes.md
out="$(fire notes.md)"
[ -z "$out" ] || fail "a non-spec file must be ignored. Got: $out"
printf '  PASS  non-spec path ignored\n'

printf '\nAll spec-approval checks passed.\n'
