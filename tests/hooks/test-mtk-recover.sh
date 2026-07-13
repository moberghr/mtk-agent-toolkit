#!/usr/bin/env bash
# test-mtk-recover.sh — verifies scripts/mtk-recover.sh on stock /bin/bash 3.2:
#   - lists saved snapshots newest-first WITHOUT `mapfile`/`tac` (both absent
#     on a fresh macOS), i.e. no "command not found" crash;
#   - applies the selected stash with --index so the snapshot's staged/unstaged
#     split is restored (a plain apply would flatten it).
#
# Every run happens inside an isolated mktemp git repo — the real repo and the
# live session's stashes are never touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RECOVER="$REPO_ROOT/scripts/mtk-recover.sh"

echo "=== mtk-recover Test (bash 3.2 portability + --index restore) ==="
[ -f "$RECOVER" ] || { echo "  FAIL  script not found: $RECOVER" >&2; exit 1; }

declare -a FAILS=()

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SANDBOX_N=0
SB=""

# Build a fresh isolated git repo containing a real precompact stash (with a
# staged AND an unstaged change) plus a two-line snapshot log. Sets $SB to the
# path. Must NOT run under command substitution — the counter increment and all
# git chatter would be lost/captured; git output is silenced regardless.
make_sandbox() {
  SANDBOX_N=$((SANDBOX_N + 1))
  SB="$TMP/repo$SANDBOX_N"
  mkdir -p "$SB"
  (
    cd "$SB"
    git init -q >/dev/null 2>&1
    git config user.email "t@example.com"
    git config user.name "t"
    git config commit.gpgsign false
    printf 'original\n' > tracked.txt
    git add tracked.txt >/dev/null 2>&1
    git commit -qm init >/dev/null 2>&1
    # Split state: modify tracked (unstaged) + add a new staged file.
    printf 'modified\n' >> tracked.txt
    printf 'new staged content\n' > staged.txt
    git add staged.txt >/dev/null 2>&1
    git stash push --include-untracked -q -m "mtk-precompact-B" >/dev/null 2>&1
    mkdir -p .claude/observability
    # Older entry (A) has no live stash -> should list as (dropped).
    # Newer entry (B) is the real stash -> should list as (present) and be [1].
    printf '2026-07-01T00:00:00Z\tsaved\tmain\tmtk-precompact-A\n' \
      >> .claude/observability/precompact-snapshots.log
    printf '2026-07-02T00:00:00Z\tsaved\tmain\tmtk-precompact-B\n' \
      >> .claude/observability/precompact-snapshots.log
  )
}

# --- 1) no snapshot log -> exit 1 ------------------------------------------
nolog="$TMP/nolog"
mkdir -p "$nolog"
( cd "$nolog" && git init -q )
set +e
( cd "$nolog" && printf 'q\n' | bash "$RECOVER" ) >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 1 ]; then
  echo "  PASS  missing snapshot log -> exit 1"
else
  FAILS+=("expected exit 1 when log missing, got $rc")
fi

# --- 2) listing newest-first, no mapfile/tac crash (bash AND /bin/bash) -----
for sh in bash /bin/bash; do
  make_sandbox; sb="$SB"
  set +e
  listing="$( cd "$sb" && printf 'q\n' | "$sh" "$RECOVER" 2>&1 )"
  rc=$?
  set -e

  if printf '%s' "$listing" | grep -qiE 'mapfile|command not found|invalid option'; then
    FAILS+=("[$sh] crash token in output: $listing")
  else
    echo "  PASS  [$sh] no mapfile/tac/declare crash"
  fi

  # Newest-first: [1] must be B, [2] must be A.
  line1="$(printf '%s\n' "$listing" | grep '\[1\]' || true)"
  line2="$(printf '%s\n' "$listing" | grep '\[2\]' || true)"
  if printf '%s' "$line1" | grep -q 'mtk-precompact-B'; then
    echo "  PASS  [$sh] newest snapshot listed as [1]"
  else
    FAILS+=("[$sh] expected [1]=mtk-precompact-B, got '$line1'")
  fi
  if printf '%s' "$line2" | grep -q 'mtk-precompact-A'; then
    echo "  PASS  [$sh] older snapshot listed as [2]"
  else
    FAILS+=("[$sh] expected [2]=mtk-precompact-A, got '$line2'")
  fi

  # present/dropped status derived from live stash list.
  if printf '%s' "$line1" | grep -q '(present)'; then
    echo "  PASS  [$sh] live stash shown (present)"
  else
    FAILS+=("[$sh] expected B (present), got '$line1'")
  fi
  if printf '%s' "$line2" | grep -q '(dropped)'; then
    echo "  PASS  [$sh] absent stash shown (dropped)"
  else
    FAILS+=("[$sh] expected A (dropped), got '$line2'")
  fi

  if [ "$rc" -eq 0 ]; then
    echo "  PASS  [$sh] quit -> exit 0"
  else
    FAILS+=("[$sh] expected exit 0 on quit, got $rc")
  fi
done

# --- 3) apply --index restores staged/unstaged split (on /bin/bash 3.2) -----
make_sandbox; sb="$SB"
set +e
apply_out="$( cd "$sb" && printf '1\n' | /bin/bash "$RECOVER" 2>&1 )"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
  echo "  PASS  apply choice 1 -> exit 0"
else
  FAILS+=("expected exit 0 on apply, got $rc. out: $apply_out")
fi

staged="$( cd "$sb" && git diff --cached --name-only )"
unstaged="$( cd "$sb" && git diff --name-only )"

if printf '%s\n' "$staged" | grep -qx 'staged.txt'; then
  echo "  PASS  --index restored the STAGED file (staged.txt in index)"
else
  FAILS+=("expected staged.txt staged after --index apply, staged='$staged'")
fi
if printf '%s\n' "$unstaged" | grep -qx 'tracked.txt'; then
  echo "  PASS  --index restored the UNSTAGED modification (tracked.txt)"
else
  FAILS+=("expected tracked.txt unstaged after apply, unstaged='$unstaged'")
fi

# --- 4) empty choice -> exit 0, nothing applied ----------------------------
make_sandbox; sb="$SB"
set +e
( cd "$sb" && printf '\n' | /bin/bash "$RECOVER" ) >/dev/null 2>&1
rc=$?
set -e
empty_staged="$( cd "$sb" && git diff --cached --name-only )"
if [ "$rc" -eq 0 ] && [ -z "$empty_staged" ]; then
  echo "  PASS  empty choice -> exit 0, nothing applied"
else
  FAILS+=("expected empty choice exit 0 + clean index, got rc=$rc staged='$empty_staged'")
fi

echo ""
if [ ${#FAILS[@]} -gt 0 ]; then
  printf '  FAIL  %s\n' "${FAILS[@]}" >&2
  exit 1
fi
echo "========================================"
echo "TEST PASSED — mtk-recover lists newest-first and applies with --index on bash 3.2"
