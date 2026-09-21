#!/usr/bin/env bash
set -euo pipefail

# Test: scripts/setup-refresh-plan.sh (F2 — staleness plan for the
# /mtk-setup --refresh / --check loop). Builds a tiny git fixture repo and
# asserts the behaviors from docs/specs/2026-07-02-v718-setup-refresh.md (F2):
#   (a) an all-fresh fixture --check's exit 0
#   (b) committing a change to a file cited by a stamped doc flips that row
#       stale and --check exits 1
#   (c) --json output parses with python3 and carries the required keys
#   (d) removing a dependency from package.json that CLAUDE.md still
#       documents flips the CLAUDE.md row stale
#   (e) a hand-curated AGENTS.md with no auto-generated marker is reported
#       `unknown` (never `stale`, since generate-agents-md.sh itself refuses
#       to overwrite it) and --check still exits per the other rows
#   (f) an mtk-stamped AGENTS.md whose footer version matches
#       .claude/mtk-version.json is `fresh`
#   (g) a footer version mismatch is `stale` with a footer-drift reason, and
#       never takes the regenerate-and-diff path
#   (h) a stamped footer with no parseable version, or a missing
#       .claude/mtk-version.json, is `unknown` (never `fresh`)
#   (i) a legacy generator-marked AGENTS.md still takes the
#       regenerate-and-diff path
#   (j) row 6 (path-references) covers AGENTS.md: a dead path referenced only
#       there flips the row stale
#   (k) F004 — when AGENTS.md is the resolved constitution (CLAUDE.md is a
#       bare `@AGENTS.md` shim), row 3's dependency rescan reads AGENTS.md: a
#       dependency named only there flips the CLAUDE.md row stale when it
#       disappears from package.json
#
# The script under test is invoked via its real path in THIS repo (so its
# sibling helper scripts — audit-drift-check.sh, generate-agents-md.sh,
# verify-references.sh — resolve via its own SCRIPT_DIR) but with CWD set to
# the fixture repo, mirroring the plugin-install scenario the script must
# support (toolkit scripts live elsewhere; CWD is the target repo).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLAN="$REPO_ROOT/scripts/setup-refresh-plan.sh"

echo "=== setup-refresh-plan Test (F2) ==="
[ -f "$PLAN" ] || { echo "  FAIL  script not found: $PLAN" >&2; exit 1; }

declare -a FAILS=()

TMPDIR_FIXTURE="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_FIXTURE"; }
trap cleanup EXIT

FIXTURE="$TMPDIR_FIXTURE/repo"
mkdir -p "$FIXTURE"
cd "$FIXTURE"

git init -q
git config user.email "test@example.com"
git config user.name "Test"

# --- Commit 1: a source file the stamped doc will cite ----------------------
mkdir -p src
cat > src/app.js <<'EOF'
console.log("v1");
EOF
git add src/app.js
git commit -q -m "commit 1: seed source file"
SHA1="$(git rev-parse HEAD)"

# --- Commit 2: the generated-artifact baseline (everything fresh) ----------
mkdir -p .claude/references

cat > .claude/mtk-version.json <<'EOF'
{"version":"1.0.0"}
EOF

cat > package.json <<'EOF'
{
  "name": "fixture",
  "dependencies": {
    "widget-lib": "^1.0.0"
  }
}
EOF

cat > CLAUDE.md <<'EOF'
# Fixture Project

This project depends on `widget-lib` for widgets.

<!-- mtk-setup: v1.0.0
     generated: 2026-01-01T00:00:00Z -->
EOF

cat > .claude/references/architecture-principles.md <<EOF
---
audited-against: $SHA1
---

# Architecture Principles

See \`src/app.js\` for the entry point.
EOF

cat > .claude/references/conventions.md <<EOF
---
audited-against: $SHA1
---

# Conventions

See \`docs/other.md\` for style notes (never modified by this fixture).
EOF

echo '{}' > .claude/detected-tools.json

git add -A
git commit -q -m "commit 2: baseline generated artifacts"

# --- (a) baseline: --check exits 0 on an all-fresh fixture ------------------
echo ""; echo "--- (a) all-fresh baseline: --check exits 0 ---"
if check_out_a="$(bash "$PLAN" --check 2>&1)"; then
  check_rc_a=0
else
  check_rc_a=$?
fi
if [ "$check_rc_a" -eq 0 ]; then
  echo "  PASS  baseline --check exited 0"
else
  FAILS+=("(a) expected --check exit 0 on fresh baseline, got $check_rc_a. Output: $check_out_a")
fi

# --- (b) commit a change to a file cited by architecture-principles.md -----
cat > src/app.js <<'EOF'
console.log("v2 -- behavior changed");
EOF
git add src/app.js
git commit -q -m "commit 3: change the cited source file"

echo ""; echo "--- (b) drift in a cited file flips the doc stale, --check exits 1 ---"
if check_out_b="$(bash "$PLAN" --check 2>&1)"; then
  check_rc_b=0
else
  check_rc_b=$?
fi
if [ "$check_rc_b" -eq 1 ]; then
  echo "  PASS  --check exited 1 after drift"
else
  FAILS+=("(b) expected --check exit 1 after drift, got $check_rc_b. Output: $check_out_b")
fi

json_b="$(bash "$PLAN" --json 2>/dev/null)"
status_b="$(printf '%s' "$json_b" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for a in data["artifacts"]:
    if a["artifact"] == ".claude/references/architecture-principles.md":
        print(a["status"])
        break
')"
if [ "$status_b" = "stale" ]; then
  echo "  PASS  architecture-principles.md row marked stale"
else
  FAILS+=("(b) expected architecture-principles.md status=stale, got '$status_b'")
fi

# --- (c) --json output parses and carries the required keys ----------------
echo ""; echo "--- (c) --json parses and has required keys ---"
if printf '%s' "$json_b" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert {"generated", "artifacts", "summary"} <= set(data.keys())
assert isinstance(data["artifacts"], list) and len(data["artifacts"]) > 0
for a in data["artifacts"]:
    assert {"artifact", "status", "reason"} <= set(a.keys())
assert {"fresh", "stale", "missing", "unstamped_unknown"} <= set(data["summary"].keys())
' 2>/dev/null; then
  echo "  PASS  --json output parses with the required keys"
else
  FAILS+=("(c) --json output failed to parse or was missing required keys: $json_b")
fi

# --- (d) removing a documented dependency flips CLAUDE.md's row stale ------
cat > package.json <<'EOF'
{
  "name": "fixture",
  "dependencies": {}
}
EOF
git add package.json
git commit -q -m "commit 4: remove widget-lib, still documented in CLAUDE.md"

echo ""; echo "--- (d) removed-but-documented dependency flips CLAUDE.md stale ---"
json_d="$(bash "$PLAN" --json 2>/dev/null)"
status_d="$(printf '%s' "$json_d" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for a in data["artifacts"]:
    if a["artifact"] == "CLAUDE.md":
        print(a["status"])
        break
')"
if [ "$status_d" = "stale" ]; then
  echo "  PASS  CLAUDE.md row marked stale after dependency removal"
else
  FAILS+=("(d) expected CLAUDE.md status=stale after removing widget-lib, got '$status_d'")
fi

# --- (e) hand-curated AGENTS.md (no auto-generated marker) is `unknown` ----
cat > AGENTS.md <<'EOF'
# AGENTS.md

Hand-curated routing notes for this repo. Not generated by MTK — do not
overwrite.
EOF
# -f: some developer machines carry a global gitignore excluding AGENTS.md
# (it's a generated artifact in most repos); this fixture needs it tracked.
git add -f AGENTS.md
git commit -q -m "commit 5: add a hand-curated, marker-less AGENTS.md"

echo ""; echo "--- (e) hand-curated marker-less AGENTS.md is 'unknown', not 'stale' ---"
json_e="$(bash "$PLAN" --json 2>/dev/null)"
status_e="$(printf '%s' "$json_e" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for a in data["artifacts"]:
    if a["artifact"] == "AGENTS.md":
        print(a["status"])
        break
')"
if [ "$status_e" = "unknown" ]; then
  echo "  PASS  AGENTS.md row marked unknown for hand-curated marker-less file"
else
  FAILS+=("(e) expected AGENTS.md status=unknown for hand-curated file, got '$status_e'")
fi

echo ""; echo "--- (e) --check still exits per the other rows (unaffected by AGENTS.md=unknown) ---"
if check_out_e="$(bash "$PLAN" --check 2>&1)"; then
  check_rc_e=0
else
  check_rc_e=$?
fi
if [ "$check_rc_e" -eq 1 ]; then
  echo "  PASS  --check still exited 1 (driven by the still-stale rows from (b)/(d))"
else
  FAILS+=("(e) expected --check exit 1 (other rows still stale), got $check_rc_e. Output: $check_out_e")
fi

# --- Row 5, canonical-constitution shapes ----------------------------------
# AGENTS.md is now the canonical constitution: an `<!-- mtk-setup` footer means
# the row is classified by FOOTER VERSION DRIFT against .claude/mtk-version.json
# and the regenerator is never invoked. Only a legacy generator-marked file
# still takes the regenerate-and-diff path; a hand-curated one stays `unknown`
# (case (e) above).

row_field() { # $1 = artifact, $2 = field (status|reason)
  bash "$PLAN" --json 2>/dev/null | python3 -c '
import json, sys
artifact, field = sys.argv[1], sys.argv[2]
data = json.load(sys.stdin)
for a in data["artifacts"]:
    if a["artifact"] == artifact:
        print(a[field])
        break
' "$1" "$2"
}

echo ""; echo "--- (f) mtk-stamped AGENTS.md, footer version == mtk-version.json -> fresh ---"
cat > AGENTS.md <<'EOF'
# AGENTS.md

Canonical constitution for this fixture.

<!-- mtk-setup: v1.0.0
     generated: 2026-01-01T00:00:00Z -->
EOF
status_f="$(row_field AGENTS.md status)"
reason_f="$(row_field AGENTS.md reason)"
if [ "$status_f" = "fresh" ] && [ "${reason_f#*footer version matches}" != "$reason_f" ]; then
  echo "  PASS  matching footer version reads fresh"
else
  FAILS+=("(f) expected AGENTS.md fresh/footer-version-matches, got '$status_f' / '$reason_f'")
fi

echo ""; echo "--- (g) mtk-stamped AGENTS.md, footer version drift -> stale with a footer reason ---"
cat > AGENTS.md <<'EOF'
# AGENTS.md

Canonical constitution for this fixture.

<!-- mtk-setup: v0.9.0
     generated: 2026-01-01T00:00:00Z -->
EOF
status_g="$(row_field AGENTS.md status)"
reason_g="$(row_field AGENTS.md reason)"
case "$status_g:$reason_g" in
  stale:*"footer stamped v0.9.0, installed v1.0.0"*)
    echo "  PASS  footer drift reads stale and names both versions" ;;
  *)
    FAILS+=("(g) expected AGENTS.md stale with a footer-drift reason, got '$status_g' / '$reason_g'") ;;
esac
case "$reason_g" in
  *regenerated*) FAILS+=("(g) footer-drift row must not take the regenerate-and-diff path: '$reason_g'") ;;
  *) : ;;
esac

echo ""; echo "--- (h) stamped footer with no version, and missing mtk-version.json -> unknown ---"
cat > AGENTS.md <<'EOF'
# AGENTS.md

Canonical constitution for this fixture.

<!-- mtk-setup
     generated: 2026-01-01T00:00:00Z -->
EOF
status_h1="$(row_field AGENTS.md status)"
if [ "$status_h1" = "unknown" ]; then
  echo "  PASS  stamped footer without a parseable version reads unknown (not fresh)"
else
  FAILS+=("(h) expected AGENTS.md unknown for a version-less footer, got '$status_h1'")
fi

mv .claude/mtk-version.json .claude/mtk-version.json.bak
cat > AGENTS.md <<'EOF'
# AGENTS.md

Canonical constitution for this fixture.

<!-- mtk-setup: v1.0.0
     generated: 2026-01-01T00:00:00Z -->
EOF
status_h2="$(row_field AGENTS.md status)"
mv .claude/mtk-version.json.bak .claude/mtk-version.json
if [ "$status_h2" = "unknown" ]; then
  echo "  PASS  missing .claude/mtk-version.json reads unknown (not fresh)"
else
  FAILS+=("(h) expected AGENTS.md unknown with no mtk-version.json, got '$status_h2'")
fi

echo ""; echo "--- (i) legacy generator-marked AGENTS.md still takes the regenerate-and-diff path ---"
cat > AGENTS.md <<'EOF'
# AGENTS.md

Auto-generated by MTK — do not edit by hand.

Legacy generator output for this fixture.
EOF
status_i="$(row_field AGENTS.md status)"
reason_i="$(row_field AGENTS.md reason)"
case "$reason_i" in
  *"regenerated"*) echo "  PASS  generator-marked AGENTS.md compared against regenerated content ($status_i)" ;;
  *) FAILS+=("(i) expected the regenerate-and-diff reason for a generator-marked AGENTS.md, got '$status_i' / '$reason_i'") ;;
esac

echo ""; echo "--- (j) row 6 (path-references) covers AGENTS.md ---"
cat > AGENTS.md <<'EOF'
# AGENTS.md

Canonical constitution for this fixture. See `src/app.js` for the entry point.

<!-- mtk-setup: v1.0.0
     generated: 2026-01-01T00:00:00Z -->
EOF
status_j_clean="$(row_field path-references status)"
cat > AGENTS.md <<'EOF'
# AGENTS.md

Canonical constitution for this fixture. See `src/ghost/removed.js` for the
entry point (this path no longer exists).

<!-- mtk-setup: v1.0.0
     generated: 2026-01-01T00:00:00Z -->
EOF
status_j_stale="$(row_field path-references status)"
if [ "$status_j_clean" = "fresh" ] && [ "$status_j_stale" = "stale" ]; then
  echo "  PASS  a stale path referenced only in AGENTS.md flips the path-references row"
else
  FAILS+=("(j) expected path-references fresh->stale when AGENTS.md gains a dead path, got '$status_j_clean' -> '$status_j_stale'")
fi

# --- (k) F004: dependency named only in AGENTS.md flips row 3 (CLAUDE.md) --
# Make CLAUDE.md a bare shim so constitution_file() resolves to AGENTS.md,
# then document a dependency only in AGENTS.md and remove it from the
# manifest — row 3's dependency rescan must read the resolved constitution
# file, not CLAUDE.md alone (which would find no dependency names at all).
echo ""; echo "--- (k) dependency named only in AGENTS.md flips row 3 stale when removed ---"
cat > CLAUDE.md <<'EOF'
# Fixture Project

@AGENTS.md
EOF
cat > AGENTS.md <<'EOF'
# AGENTS.md

Canonical constitution for this fixture. This project depends on
`agents-only-lib` for widgets.

<!-- mtk-setup: v1.0.0
     generated: 2026-01-01T00:00:00Z -->
EOF
cat > package.json <<'EOF'
{
  "name": "fixture",
  "dependencies": {
    "agents-only-lib": "^1.0.0"
  }
}
EOF
status_k_present="$(row_field CLAUDE.md status)"

cat > package.json <<'EOF'
{
  "name": "fixture",
  "dependencies": {}
}
EOF
status_k_removed="$(row_field CLAUDE.md status)"
reason_k_removed="$(row_field CLAUDE.md reason)"
if [ "$status_k_present" = "fresh" ] && [ "$status_k_removed" = "stale" ] \
   && [ "${reason_k_removed#*agents-only-lib}" != "$reason_k_removed" ]; then
  echo "  PASS  a dependency named only in AGENTS.md flips row 3 (CLAUDE.md) stale when removed"
else
  FAILS+=("(k) expected CLAUDE.md fresh->stale naming agents-only-lib when the AGENTS.md-only dependency is removed, got '$status_k_present' -> '$status_k_removed' / '$reason_k_removed'")
fi

echo ""
if [ ${#FAILS[@]} -gt 0 ]; then
  printf '  FAIL  %s\n' "${FAILS[@]}" >&2
  exit 1
fi
echo "========================================"
echo "TEST PASSED — all F2 setup-refresh-plan assertions green"
