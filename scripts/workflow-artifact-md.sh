#!/usr/bin/env bash

set -euo pipefail

# workflow-artifact-md.sh — assemble a single browsable markdown rollup for a
# workflow run from the human-facing outputs recorded on its artifact.
#
# Usage:
#   scripts/workflow-artifact-md.sh <uuid>
#
# Reads .mtk/workflows/<uuid>.json, then concatenates — with section headers —
# whichever recorded source docs currently exist on disk:
#   results.spec_path         -> ## Spec
#   results.plan_path         -> ## Plan
#   results.todo_path         -> ## Tasks
#   results.handoff_path      -> ## Handoff
#   results.health_report_path-> ## Health report
#
# Output: .mtk/workflows/<uuid>.artifact.md (overwritten in place each run).
# Prints the output path to stdout. Missing source paths are skipped, not
# errors, so the rollup always reflects exactly what exists at assembly time.
# This file is the source the `Artifact` tool publishes; see
# .claude/references/artifact-publishing.md for the full procedure.

ROOT_DIR="$(pwd)"
WF_DIR="${ROOT_DIR}/.mtk/workflows"

fail() { printf 'workflow-artifact-md: %s\n' "$1" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 is required (accepted baseline; see S3.3)"

uuid="${1:-}"
[ -n "$uuid" ] || fail "usage: workflow-artifact-md.sh <uuid>"
artifact="${WF_DIR}/${uuid}.json"
[ -f "$artifact" ] || fail "no workflow artifact for $uuid (expected ${artifact#$ROOT_DIR/})"

out="${WF_DIR}/${uuid}.artifact.md"

python3 - "$artifact" "$ROOT_DIR" "$out" <<'PY'
import json, os, sys

artifact, root, out = sys.argv[1], sys.argv[2], sys.argv[3]
with open(artifact) as f:
    doc = json.load(f)

results = doc.get("results", {}) or {}
goal = (doc.get("intent", {}) or {}).get("goal") or doc.get("workflow_uuid", "workflow")

# (results key, section heading) in the order they should appear in the rollup.
sections = [
    ("spec_path", "Spec"),
    ("plan_path", "Plan"),
    ("todo_path", "Tasks"),
    ("handoff_path", "Handoff"),
    ("health_report_path", "Health report"),
]

parts = [f"# Workflow: {goal}\n"]
parts.append(
    f"> Rollup for `{doc.get('workflow_uuid','')}` "
    f"(status: {doc.get('status','?')}, phase: {doc.get('phase_cursor','?')}). "
    "Assembled from on-disk workflow outputs — disk is the source of truth.\n"
)

included = 0
for key, heading in sections:
    rel = results.get(key)
    if not rel:
        continue
    path = rel if os.path.isabs(rel) else os.path.join(root, rel)
    if not os.path.isfile(path):
        continue
    with open(path, encoding="utf-8", errors="replace") as f:
        body = f.read().rstrip("\n")
    parts.append(f"## {heading}\n")
    parts.append(f"_Source: `{rel}`_\n")
    parts.append(body + "\n")
    included += 1

if included == 0:
    parts.append(
        "## (no outputs yet)\n\n"
        "No recorded source document exists on disk yet. Re-run after a "
        "workflow output (spec, plan, handoff, or health report) is written.\n"
    )

os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w", encoding="utf-8") as f:
    f.write("\n".join(parts).rstrip("\n") + "\n")

print(f"assembled {included} section(s)", file=sys.stderr)
PY

printf '%s\n' "${out#$ROOT_DIR/}"
