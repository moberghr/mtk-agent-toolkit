#!/usr/bin/env bash
set -euo pipefail

# lesson-anchors.sh: stale cited paths/symbols in lesson files are located
# deterministically; external example paths are skipped, never warned about
# (a checker that flags other repos' files trains people to ignore it);
# WARN-only by default, --strict exits 1.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKER="$REPO_ROOT/scripts/lesson-anchors.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
git -C "$WORK" init -q
cd "$WORK"

mkdir -p hooks/lib scripts tasks
printf '#!/usr/bin/env bash\nmy_real_function() { :; }\n' > hooks/lib/real.sh
printf '#!/usr/bin/env bash\n: moved here\n' > scripts/moved-note.sh
git add -A >/dev/null 2>&1 && git -C "$WORK" commit -qm fixture

cat > tasks/lessons.md <<'EOF'
# Lessons

## 2026-08-01 — good anchors stay quiet
See `hooks/lib/real.sh` and the symbol `hooks/lib/real.sh:my_real_function`.
Line anchors like `hooks/lib/real.sh:2` check only the file.

## 2026-08-02 — stale path
The fix lives in `hooks/lib/renamed.sh` (moved since).

## 2026-08-02b — moved file gets a rename suggestion
See `hooks/moved-note.sh` (now under scripts/).

## 2026-08-03 — stale symbol
Call `hooks/lib/real.sh:gone_function` before saving.

## 2026-08-04 — external examples are not anchors
Borrowed from `src/hashgate/gate.py` and `https://github.com/x/y`;
env form `$CLAUDE_PROJECT_DIR/hooks` and glob `hooks/*.sh` are ignored too.
EOF

out="$(CLAUDE_PROJECT_DIR="$WORK" bash "$CHECKER" tasks/lessons.md)"
rc=$?
[ "$rc" -eq 0 ] || fail "default posture is WARN-only — must exit 0 (got $rc)"

case "$out" in *'STALE-PATH `hooks/lib/renamed.sh`'*) : ;; *) fail "stale path not reported. Got: $out" ;; esac
case "$out" in *'lesson: 2026-08-02 — stale path'*) : ;; *) fail "nearest heading missing on stale path. Got: $out" ;; esac
printf '  PASS  stale path reported with lesson heading\n'

case "$out" in *'STALE-PATH `hooks/moved-note.sh`'*'did you mean: scripts/moved-note.sh?'*) : ;; *) fail "moved file must get a same-basename rename suggestion. Got: $out" ;; esac
printf '  PASS  moved file gets a rename suggestion\n'

case "$out" in *'STALE-SYMBOL `gone_function`'*) : ;; *) fail "stale symbol not reported. Got: $out" ;; esac
printf '  PASS  stale symbol reported\n'

case "$out" in *'real.sh:my_real_function'*'STALE'*) fail "live symbol wrongly flagged. Got: $out" ;; *) : ;; esac
case "$out" in *'STALE-PATH `hooks/lib/real.sh`'*) fail "live path wrongly flagged. Got: $out" ;; *) : ;; esac
printf '  PASS  live anchors stay quiet\n'

case "$out" in *'src/hashgate'*) fail "external example path must be skipped, not reported. Got: $out" ;; *) : ;; esac
case "$out" in *'skipped'*) : ;; *) fail "summary must disclose skipped external tokens. Got: $out" ;; esac
printf '  PASS  external examples skipped and disclosed\n'

rc=0
CLAUDE_PROJECT_DIR="$WORK" bash "$CHECKER" --strict tasks/lessons.md >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "--strict must exit 1 when stale anchors exist (got $rc)"
printf '  PASS  --strict exits non-zero on stale anchors\n'

sed -i.bak 's|hooks/lib/renamed.sh|hooks/lib/real.sh|; s|gone_function|my_real_function|; s|hooks/moved-note.sh|scripts/moved-note.sh|' tasks/lessons.md
rc=0
CLAUDE_PROJECT_DIR="$WORK" bash "$CHECKER" --strict tasks/lessons.md >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "clean file must pass --strict (got $rc)"
printf '  PASS  clean file passes --strict\n'

printf '\nAll lesson-anchor checks passed.\n'
