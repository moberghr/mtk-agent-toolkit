#!/usr/bin/env bash
set -euo pipefail

# Rule enforcement map (round 8, option D): rules naming a live wired
# enforcer read WIRED, rules naming a missing one read BROKEN, rules naming
# nothing read PROSE (not a failure), and hooks no rule documents surface as
# UNDOC. Token boundaries hold (checksums.sha256 is not checksums.sh).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MAP="$REPO_ROOT/scripts/rule-enforcement-map.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
git -C "$WORK" init -q
cd "$WORK"
mkdir -p .claude/rules hooks scripts

printf '#!/usr/bin/env bash\nset -euo pipefail\n' > hooks/live-guard.sh
printf '#!/usr/bin/env bash\nset -euo pipefail\n' > hooks/orphan-hook.sh
printf '#!/usr/bin/env bash\nset -euo pipefail\n' > scripts/checker.sh
cat > hooks/hooks.json <<'EOF'
{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/live-guard.sh" } ] } ] } }
EOF

cat > .claude/rules/test-rules.md <<'EOF'
# Rules

- **S9.1** Enforced by `hooks/live-guard.sh` on every call.
- **S9.2** Checked by `scripts/checker.sh` before release; regenerate `checksums.sha256` after.
- **S9.3** Enforced by `hooks/ghost-guard.sh` which was deleted long ago.
- **S9.4** Be sensible. Use good judgment.
- **S9.5** The orphan hook is deliberately mentioned here: orphan-hook.
EOF
printf '# P\n\n- **C0.1** Never do the bad thing.\n' > CLAUDE.md

out="$(CLAUDE_PROJECT_DIR="$WORK" bash "$MAP")"
rc=$?
[ "$rc" -eq 0 ] || fail "default posture must exit 0 (got $rc)"

case "$out" in *'WIRED   S9.1'*) : ;; *) fail "live wired hook must read WIRED. Got: $out" ;; esac
case "$out" in *'WIRED   S9.2'*) : ;; *) fail "existing script enforcer must read WIRED. Got: $out" ;; esac
case "$out" in *'BROKEN  S9.3'*'ghost-guard.sh'*) : ;; *) fail "missing enforcer must read BROKEN. Got: $out" ;; esac
case "$out" in *'PROSE   S9.4'*) : ;; *) fail "no-enforcer rule must read PROSE. Got: $out" ;; esac
case "$out" in *'checksums.sh (file missing)'*) fail "checksums.sha256 must not token-match checksums.sh" ;; *) : ;; esac
printf '  PASS  WIRED / BROKEN / PROSE verdicts with clean token boundaries\n'

case "$out" in *'UNDOC'*'orphan-hook.sh'*) fail "orphan-hook is mentioned by S9.5 (spaced/stem) — must not be UNDOC" ;; *) : ;; esac
printf '  PASS  prose mention counts as documentation\n'

# Undocumented hook detection: add one nothing mentions.
printf '#!/usr/bin/env bash\nset -euo pipefail\n' > hooks/mystery-hook.sh
out="$(CLAUDE_PROJECT_DIR="$WORK" bash "$MAP")"
case "$out" in *'UNDOC   hooks/mystery-hook.sh'*) : ;; *) fail "undocumented hook must surface as UNDOC. Got: $out" ;; esac
printf '  PASS  undocumented enforcer surfaces\n'

rc=0
CLAUDE_PROJECT_DIR="$WORK" bash "$MAP" --strict >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "--strict must exit 1 with broken/undocumented present (got $rc)"
printf '  PASS  --strict exits non-zero on findings\n'

printf '\nAll rule-enforcement-map checks passed.\n'
