#!/usr/bin/env bash
set -euo pipefail

# workflow-artifact.sh — criteria seal and gate set.
#
# WHY. Target repos gitignore docs/specs/* (only baseline/ is tracked), so the
# old tamper check — a `git diff` of the spec sidecar since approval — had no
# committed version to diff against. The approval seal now also records a hash
# of the sidecar's frozen success_criteria block (id / observable /
# evidence_channel), and verify-seal reports a moved goalpost as STALE. The
# sidecar's other fields (the change manifest, amended in Phase 3.5) stay free
# to change.
#
# Also: skill_precedence_gate was never recorded by any skill yet AUTO_PROCEED
# required it, so it was dropped. init no longer creates it, the gate command
# rejects it, and an old artifact that still carries the key keeps working.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WFA="$REPO_ROOT/scripts/workflow-artifact.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; }

PROJ="$(mktemp -d -t mtk-critseal-XXXXXX)"
trap 'rm -rf "$PROJ"' EXIT
( cd "$PROJ" && git init -q . )
export CLAUDE_PROJECT_DIR="$PROJ"
WF="$PROJ/.mtk/workflows"
run() { ( cd "$PROJ" && bash "$WFA" "$@" ); }

# --- gate set -------------------------------------------------------------
UUID="$(run init BUILD --goal "criteria seal")"
python3 - "$WF/$UUID.json" <<'PY' || fail "init still creates skill_precedence_gate"
import json, sys
g = json.load(open(sys.argv[1]))["gates"]
assert "skill_precedence_gate" not in g, g
assert set(g) == {"plan_trust_gate", "phase_exit_gate", "failure_stop_gate", "memory_sync_gate"}, g
PY
run gate "$UUID" skill_precedence_gate pass >/dev/null 2>&1 && fail "gate accepted the dropped skill_precedence_gate"
ok "init creates four gates and gate rejects skill_precedence_gate"

# Legacy artifact still carrying the key: read, list, and other gates still work.
python3 - "$WF/$UUID.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["gates"]["skill_precedence_gate"] = "pass"
json.dump(d, open(p, "w"), indent=2)
PY
run read "$UUID" >/dev/null || fail "read failed on a legacy artifact"
run list >/dev/null || fail "list failed on a legacy artifact"
run gate "$UUID" plan_trust_gate pass --reason "legacy" >/dev/null || fail "gate failed on a legacy artifact"
ok "a legacy artifact carrying skill_precedence_gate keeps loading"

# --- criteria seal --------------------------------------------------------
mkdir -p "$PROJ/docs/specs" "$PROJ/docs/plans"
printf '# Spec\n' > "$PROJ/docs/specs/2026-10-12-x.md"
printf '# Plan\n' > "$PROJ/docs/plans/2026-10-12-x.md"
cat > "$PROJ/docs/specs/2026-10-12-x.json" <<'JSON'
{
  "change_manifest": [{"path": "src/a.cs", "action": "modify"}],
  "success_criteria": [
    {"id": "SC1", "description": "a", "evidence_channel": "test-run", "observable": "tests pass"},
    {"id": "SC2", "description": "b", "evidence_channel": "http-probe", "observable": "GET /health is 200"}
  ]
}
JSON
U2="$(run init BUILD --goal "seal")"
run set "$U2" results.spec_path=docs/specs/2026-10-12-x.md results.plan_path=docs/plans/2026-10-12-x.md >/dev/null
run seal "$U2" >/dev/null || fail "seal failed"
python3 - "$WF/$U2.json" <<'PY' || fail "seal did not record the success_criteria hash"
import json, sys
c = json.load(open(sys.argv[1]))["results"]["approval_seal"]["criteria"]
assert c["path"] == "docs/specs/2026-10-12-x.json" and len(c["sha256"]) == 64 and c["count"] == 2, c
PY
run verify-seal "$U2" >/dev/null || fail "fresh seal did not verify"
ok "seal records the sidecar's success_criteria hash"

# Amending the manifest (non-criteria field) or a description does not trip it.
python3 - "$PROJ/docs/specs/2026-10-12-x.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["change_manifest"].append({"path": "src/b.cs", "action": "create"})
d["success_criteria"][0]["description"] = "a, reworded"
json.dump(d, open(p, "w"), indent=2)
PY
run verify-seal "$U2" >/dev/null || fail "a manifest amendment flipped the seal STALE"
ok "a manifest amendment leaves the criteria seal intact"

# Moving a goalpost (observable) is STALE and names success_criteria.
python3 - "$PROJ/docs/specs/2026-10-12-x.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["success_criteria"][1]["observable"] = "GET /health returns anything"
json.dump(d, open(p, "w"), indent=2)
PY
rc=0; out="$(run verify-seal "$U2" 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "edited observable should be STALE (exit 1), got $rc: $out"
grep -q 'success_criteria' <<<"$out" || fail "STALE output should name success_criteria: $out"
ok "an edited success criterion is STALE"

# A deleted sidecar is STALE too, not silently skipped.
rm "$PROJ/docs/specs/2026-10-12-x.json"
rc=0; run verify-seal "$U2" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "deleted sidecar should be STALE (exit 1), got $rc"
ok "a deleted sidecar is STALE"

echo "test-workflow-artifact-criteria-seal: all checks passed"
