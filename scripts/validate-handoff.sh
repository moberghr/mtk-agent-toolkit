#!/usr/bin/env bash
set -euo pipefail
# Deterministic spec-drift check against a handoff JSON artifact.
# Usage: bash scripts/validate-handoff.sh <path-to-handoff.json> [<git-base-ref>]
#        bash scripts/validate-handoff.sh <path-to-handoff.json> --fields-only
# Default base ref: main. Override for feature branches off develop etc.
# --fields-only: skip git-drift checks; validate schema fields only (evidence_channel, etc.).
#
# Emits a markdown-table drift report to stdout, follows the review-finding
# schema convention (source: "drift"). Exit 1 if any critical drift found.

HANDOFF="${1:-}"
BASE_REF="${2:-main}"
FIELDS_ONLY=0
if [ "${2:-}" = "--fields-only" ]; then
  FIELDS_ONLY=1
  BASE_REF="(skipped)"
fi

# Auto-detect fixture files (fixture_type present and != null) — skip git drift for test fixtures.
if [ "$FIELDS_ONLY" -eq 0 ]; then
  _fixture_type="$(python3 -c "
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
    ft = doc.get('fixture_type', '')
    print(ft)
except: print('')
" "$HANDOFF" 2>/dev/null || true)"
  if [ -n "${_fixture_type:-}" ]; then
    FIELDS_ONLY=1
    BASE_REF="(fixture:${_fixture_type} — git drift skipped)"
  fi
fi

[ -n "$HANDOFF" ] || { printf 'Usage: %s <handoff.json> [<base-ref>|--fields-only]\n' "$0" >&2; exit 2; }
[ -f "$HANDOFF" ] || { printf 'ERROR: not found: %s\n' "$HANDOFF" >&2; exit 2; }

# Minimal JSON field extraction — no jq dependency (S3.3).
# For well-formed JSON emitted by our own skills this is sufficient.
extract_array() {
  local file="$1"
  local key="$2"
  # Extract "key": [...] (single-line or multi-line) — returns array items one per line.
  awk -v k="\"$key\"" '
    $0 ~ k { found=1 }
    found {
      buf = buf $0 "\n"
      depth += gsub(/\[/, "[")
      depth -= gsub(/\]/, "]")
      if (depth == 0 && $0 ~ /\]/) { print buf; exit }
    }
  ' "$file" | grep -oE '"[^"]+"[[:space:]]*:[[:space:]]*"[^"]+"' | grep '"path"' | sed -E 's/.*"path":[[:space:]]*"([^"]+)".*/\1/'
}

declared_files=""
actual_files=""
extra_files=""
missing_files=""
sensitive_hit=""

if [ "$FIELDS_ONLY" -eq 0 ]; then
  declared_files="$(extract_array "$HANDOFF" "change_manifest" | sort -u)"

  # Actual touched files from git.
  actual_files="$(git diff --name-only "${BASE_REF}"...HEAD 2>/dev/null | sort -u || true)"
  if [ -z "$actual_files" ]; then
    actual_files="$(git diff --name-only HEAD 2>/dev/null | sort -u || true)"
  fi

  # Compute deltas.
  extra_files="$(comm -23 <(printf '%s\n' "$actual_files") <(printf '%s\n' "$declared_files") | grep -v '^$' || true)"
  missing_files="$(comm -13 <(printf '%s\n' "$actual_files") <(printf '%s\n' "$declared_files") | grep -v '^$' || true)"

  # Security-impact sanity: if security_impact is "none" but the diff touches known-sensitive paths, flag it.
  security_impact="$(grep -E '"security_impact"' "$HANDOFF" | sed -E 's/.*"security_impact":[[:space:]]*"([^"]+)".*/\1/' | head -1)"
  if [ "$security_impact" = "none" ] && [ -n "$actual_files" ]; then
    sensitive_hit="$(printf '%s\n' "$actual_files" | grep -iE '(auth|secret|credential|payment|audit|iam|oauth|token|pii)' || true)"
  fi
fi

# evidence_channel validation: any evidence_channel value present must be from the approved taxonomy.
VALID_CHANNELS="test-run build-output http-probe cli-stdout db-state-diff browser log-capture script-output"
bad_channels=""
bad_channels="$(python3 - "$HANDOFF" "$VALID_CHANNELS" <<'PY'
import json, sys
path = sys.argv[1]
valid = set(sys.argv[2].split())
try:
    with open(path) as f:
        doc = json.load(f)
except Exception as e:
    print(f"ERROR: could not parse JSON: {e}", file=sys.stderr)
    sys.exit(2)
criteria = doc.get("success_criteria", [])
bad = []
for c in criteria:
    ch = c.get("evidence_channel")
    if ch is not None and ch not in valid:
        bad.append(f"  criterion {c.get('id','?')}: invalid evidence_channel '{ch}'")
print("\n".join(bad))
PY
)"

critical=0

printf '# Spec-Drift Report\n\n'
printf -- '- handoff: `%s`\n' "$HANDOFF"
printf -- '- base ref: `%s`\n\n' "$BASE_REF"

if [ -n "$extra_files" ]; then
  printf '## CRITICAL: files touched but NOT in change_manifest\n\n'
  printf '%s\n' "$extra_files" | sed 's/^/- `/; s/$/`/'
  printf '\n'
  critical=$((critical + 1))
fi

if [ -n "$missing_files" ]; then
  printf '## CRITICAL: files declared but NOT touched\n\n'
  printf '%s\n' "$missing_files" | sed 's/^/- `/; s/$/`/'
  printf '\n'
  critical=$((critical + 1))
fi

if [ -n "$sensitive_hit" ]; then
  printf '## CRITICAL: security_impact="none" but sensitive paths touched\n\n'
  printf '%s\n' "$sensitive_hit" | sed 's/^/- `/; s/$/`/'
  printf '\n'
  critical=$((critical + 1))
fi

if [ -n "$bad_channels" ]; then
  printf '## CRITICAL: invalid evidence_channel value(s) — must be one of: %s\n\n' "$VALID_CHANNELS"
  printf '%s\n' "$bad_channels"
  printf '\n'
  critical=$((critical + 1))
fi

if [ "$critical" -eq 0 ]; then
  printf '## PASS — no file-level or security-impact drift detected.\n\n'
  printf 'Note: contract-level drift (public_contracts) still requires manual verification.\n'
  exit 0
fi

printf '## Verdict: NEEDS_CHANGES (%d critical drift findings)\n' "$critical"
exit 1
