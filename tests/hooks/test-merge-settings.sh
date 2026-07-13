#!/usr/bin/env bash
# test-merge-settings.sh — verifies hooks/merge-settings.sh performs a proper
# deep JSON merge on stock /bin/bash 3.2 + BSD userland (no gawk 3-arg match).
#
# Runs the target under BOTH `bash` and explicitly `/bin/bash`, asserts the
# merged output is byte-valid JSON (json.tool round-trip), and checks the
# documented merge semantics: union arrays with dedup, all hook event types
# preserved, matchers/timeouts preserved, values with spaces/quotes intact,
# empty arrays handled, target wins on scalar conflict. All state under mktemp.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SH="$REPO_ROOT/hooks/merge-settings.sh"

echo "=== merge-settings Test (bash 3.2 / BSD portability) ==="
[ -f "$TARGET_SH" ] || { echo "  FAIL  script not found: $TARGET_SH" >&2; exit 1; }

declare -a FAILS=()

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Source = new MTK settings ---------------------------------------------
cat > "$TMP/source.json" <<'EOF'
{
  "permissions": {
    "allowedTools": [
      "Read",
      "Bash(git diff:*)",
      "Bash(git status:*)"
    ],
    "deny": []
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "hooks/security-gate.sh", "timeout": 5 }
        ]
      }
    ],
    "PreCompact": [
      {
        "hooks": [
          { "type": "command", "command": "hooks/pre-compact-snapshot.sh", "timeout": 8 }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "command": "hooks/dispatch.sh", "timeout": 3 }
        ]
      }
    ]
  },
  "env": {
    "MTK_HOOKS_TIER2": "1"
  }
}
EOF

# --- Target = existing repo settings (has customizations to preserve) ------
cat > "$TMP/target.json" <<'EOF'
{
  "permissions": {
    "allowedTools": [
      "Read",
      "Bash(npm test:*)"
    ],
    "deny": [
      "Bash(rm -rf:*)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "hooks/security-gate.sh", "timeout": 5 }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          { "type": "command", "command": "hooks/team-linter.sh", "timeout": 10 }
        ]
      }
    ]
  },
  "env": {
    "MTK_HOOKS_TIER2": "0"
  },
  "teamCustom": "keep me"
}
EOF

OUT_BASH="$(bash "$TARGET_SH" "$TMP/source.json" "$TMP/target.json")"
OUT_BIN="$(/bin/bash "$TARGET_SH" "$TMP/source.json" "$TMP/target.json")"

# 1) byte-valid JSON via json.tool round-trip
if printf '%s' "$OUT_BIN" | python3 -m json.tool >/dev/null 2>&1; then
  echo "  PASS  /bin/bash output is byte-valid JSON (json.tool round-trip)"
else
  FAILS+=("/bin/bash output failed json.tool: $OUT_BIN")
fi

# 2) both shells agree
if [ "$OUT_BASH" = "$OUT_BIN" ]; then
  echo "  PASS  bash and /bin/bash output byte-identical"
else
  FAILS+=("bash vs /bin/bash output differ")
fi

# 3..N) semantic assertions via python
assertions="$(printf '%s' "$OUT_BIN" | python3 -c '
import json, sys
d = json.load(sys.stdin)

def out(label, ok):
    print(("PASS" if ok else "FAIL") + "\t" + label)

allowed = d["permissions"]["allowedTools"]
# union with dedup: Read appears once; both distinctive tools present
out("allowedTools union dedups Read", allowed.count("Read") == 1)
out("allowedTools keeps target-only Bash(npm test:*)", "Bash(npm test:*)" in allowed)
out("allowedTools adds source-only Bash(git diff:*)", "Bash(git diff:*)" in allowed)
# value with spaces/parens/colon preserved verbatim (the old awk gsub bug)
out("value with spaces preserved verbatim", "Bash(git status:*)" in allowed)

deny = d["permissions"]["deny"]
out("empty source deny + target deny -> target entry kept", deny == ["Bash(rm -rf:*)"])

hooks = d["hooks"]
# all event types present (old bash dropped PreCompact/UserPromptSubmit)
for ev in ("PreToolUse", "PostToolUse", "PreCompact", "UserPromptSubmit"):
    out("hook event %s preserved" % ev, ev in hooks)

# PreToolUse Bash security-gate must not be duplicated (dedup by command)
pre_cmds = [h["command"] for grp in hooks["PreToolUse"] for h in grp["hooks"]]
out("PreToolUse dedups shared security-gate command", pre_cmds.count("hooks/security-gate.sh") == 1)

# matcher + timeout preserved on a group
post = hooks["PostToolUse"][0]
out("matcher preserved", post.get("matcher") == "Edit|Write")
out("timeout preserved", post["hooks"][0].get("timeout") == 10)

# scalar conflict: target wins (existing repo MTK_HOOKS_TIER2=0 kept)
out("scalar conflict target wins (env)", d["env"]["MTK_HOOKS_TIER2"] == "0")

# target-only top-level key preserved
out("target-only key preserved", d.get("teamCustom") == "keep me")
')"

while IFS=$'\t' read -r verdict label; do
  [ -n "$verdict" ] || continue
  if [ "$verdict" = "PASS" ]; then
    echo "  PASS  $label"
  else
    FAILS+=("$label (JSON: $OUT_BIN)")
  fi
done <<< "$assertions"

# N+1) empty target -> source echoed verbatim
: > "$TMP/empty.json"
empty_out="$(/bin/bash "$TARGET_SH" "$TMP/source.json" "$TMP/empty.json")"
if [ "$empty_out" = "$(cat "$TMP/source.json")" ]; then
  echo "  PASS  empty target -> source echoed"
else
  FAILS+=("empty target did not echo source verbatim")
fi

# N+2) non-JSON input -> exit 2, no stdout garbage
printf 'not json at all' > "$TMP/garbage.json"
set +e
bad_out="$(/bin/bash "$TARGET_SH" "$TMP/garbage.json" "$TMP/target.json" 2>/dev/null)"
rc=$?
set -e
if [ "$rc" -eq 2 ] && [ -z "$bad_out" ]; then
  echo "  PASS  unparseable JSON -> exit 2, no stdout"
else
  FAILS+=("expected exit 2 + empty stdout on bad JSON, got rc=$rc stdout='$bad_out'")
fi

echo ""
if [ ${#FAILS[@]} -gt 0 ]; then
  printf '  FAIL  %s\n' "${FAILS[@]}" >&2
  exit 1
fi
echo "========================================"
echo "TEST PASSED — merge-settings deep-merges valid JSON on bash 3.2 / BSD"
