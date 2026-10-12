#!/usr/bin/env bash
set -euo pipefail
# audit-drift-check.sh — Compare a stamped MTK audit doc against current HEAD.
#
# Reads the `audited-against: <sha>` stamp from a generated doc, computes
# `git diff --name-only <sha>..HEAD`, intersects with file paths cited in the
# doc, and surfaces any claims that touch changed files.
#
# Output: markdown by default, JSON with --json.
# Exit codes:
#   0 — no drift (or doc has no stamp; warn-only)
#   1 — drift detected (≥1 claim touches a changed file)
#   2 — usage error / missing doc
#
# Usage:
#   bash scripts/audit-drift-check.sh .claude/references/architecture-principles.md
#   bash scripts/audit-drift-check.sh CLAUDE.md --json
#
# Spec: docs/specs/2026-05-25-grounded-audit.md (U8)

INPUT="${1:-}"
FORMAT="markdown"
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    *) echo "WARN: unknown arg: $1" >&2; shift ;;
  esac
done

if [[ -z "$INPUT" || ! -f "$INPUT" ]]; then
  echo "ERROR: pass a stamped doc path (got: '${INPUT}')" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

# Extract stamp — looks for `audited-against: <sha>` anywhere in the file
# (frontmatter for principles/conventions, footer comment for CLAUDE.md).
STAMP=$(grep -oE 'audited-against:[[:space:]]*[0-9a-f]{7,40}' "$INPUT" 2>/dev/null \
        | head -1 | awk '{print $2}' || true)

if [[ -z "$STAMP" ]]; then
  if [[ "$FORMAT" == "json" ]]; then
    echo '{"input":"'"$INPUT"'","stamped":false,"drift":[]}'
  else
    echo "audit-drift: no \`audited-against\` stamp found in $INPUT — skipping drift check"
  fi
  exit 0
fi

# Verify the SHA exists in this clone.
if ! git cat-file -e "${STAMP}^{commit}" 2>/dev/null; then
  if [[ "$FORMAT" == "json" ]]; then
    echo '{"input":"'"$INPUT"'","stamped":true,"sha":"'"$STAMP"'","reachable":false,"drift":[]}'
  else
    echo "audit-drift: stamp $STAMP not reachable in this clone — fetch or re-audit"
  fi
  exit 0
fi

# Files changed since the audit.
CHANGED=$(git diff --name-only "$STAMP"..HEAD 2>/dev/null || true)
if [[ -z "$CHANGED" ]]; then
  if [[ "$FORMAT" == "json" ]]; then
    echo '{"input":"'"$INPUT"'","stamped":true,"sha":"'"$STAMP"'","drift":[]}'
  else
    echo "audit-drift: clean — no files changed since $STAMP"
  fi
  exit 0
fi

# Cited paths — backticked tokens that look like file paths (contain `/` or `.`).
CITED=$(grep -oE '`[^`]+`' "$INPUT" \
        | sed 's/^`//;s/`$//' \
        | grep -E '/|\.[a-z]+$' \
        | sort -u || true)

# Intersect changed × cited.
DRIFT=()
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  while IFS= read -r cited; do
    [[ -z "$cited" ]] && continue
    case "$path" in
      *"$cited"*|"$cited") DRIFT+=("$path|$cited") ;;
    esac
    # also handle the reverse — cited is a glob/dir like `src/Api/Controllers/*.cs`
    case "$cited" in
      *\**)
        cited_dir="${cited%%/\**}"
        case "$path" in "$cited_dir"/*) DRIFT+=("$path|$cited") ;; esac
        ;;
    esac
  done <<< "$CITED"
done <<< "$CHANGED"

# Deduplicate (portable to bash 3.2 / macOS — no mapfile).
if [[ ${#DRIFT[@]} -gt 0 ]]; then
  DEDUP=$(printf '%s\n' "${DRIFT[@]}" | awk 'NF' | sort -u)
  DRIFT=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && DRIFT+=("$entry")
  done <<< "$DEDUP"
fi

if [[ ${#DRIFT[@]} -eq 0 ]]; then
  if [[ "$FORMAT" == "json" ]]; then
    echo '{"input":"'"$INPUT"'","stamped":true,"sha":"'"$STAMP"'","drift":[]}'
  else
    echo "audit-drift: $(echo "$CHANGED" | wc -l | tr -d ' ') file(s) changed since $STAMP, but none are cited in $INPUT"
  fi
  exit 0
fi

if [[ "$FORMAT" == "json" ]]; then
  python3 - <<PY
import json
drift = []
for line in """$(printf '%s\n' "${DRIFT[@]}")""".strip().splitlines():
    path, cited = line.split("|", 1)
    drift.append({"changed_path": path, "cited_anchor": cited})
print(json.dumps({"input": "$INPUT", "stamped": True, "sha": "$STAMP", "drift": drift}, indent=2))
PY
else
  echo "audit-drift: ${#DRIFT[@]} cited path(s) changed since $STAMP — claims may be stale"
  echo
  echo "| changed file | cited anchor |"
  echo "|---|---|"
  for entry in "${DRIFT[@]}"; do
    path="${entry%%|*}"
    cited="${entry##*|}"
    echo "| \`$path\` | \`$cited\` |"
  done
fi

exit 1
