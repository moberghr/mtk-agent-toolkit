#!/usr/bin/env bash
set -euo pipefail
# Deterministic spec-drift check against a handoff JSON artifact.
# Usage: bash scripts/validate-handoff.sh <path-to-handoff.json> [<git-base-ref>]
#        bash scripts/validate-handoff.sh <path-to-handoff.json> --fields-only
# --fields-only: skip git-drift checks; validate schema fields only (evidence_channel, etc.).
#
# Base ref resolution (first hit wins):
#   1. the <git-base-ref> argument
#   2. $MTK_BASE_REF
#   3. a top-level "base_ref" string in the handoff JSON
#   4. the branch this one was forked from, when git can tell — the nearest
#      local branch (other than HEAD) whose tip is an ancestor of HEAD; this is
#      what makes a stacked branch diff against its parent instead of main
#   5. the remote default branch (origin/HEAD), else `main`
# A hard-coded `main` default made every stacked branch report its parent's
# files as undeclared drift (2026-09 field run).
#
# "Actually touched" is the union of committed (<base>...HEAD), uncommitted
# tracked (HEAD), and untracked-but-not-ignored files — a brand-new file that
# has not been `git add`ed is still a file the run touched.
#
# Manifest entries ending in `/` are directory entries: they cover every actual
# file beneath them, and count as touched when any such file exists.
#
# Emits a markdown-table drift report to stdout, follows the review-finding
# schema convention (source: "drift"). Exit 1 if any critical drift found.

HANDOFF="${1:-}"
BASE_REF="${2:-}"
FIELDS_ONLY=0
if [ "${2:-}" = "--fields-only" ]; then
  FIELDS_ONLY=1
  BASE_REF="(skipped)"
fi

# Nearest local branch (not the current one) whose tip is an ancestor of HEAD,
# i.e. the branch this one was most plausibly stacked on. Prints nothing when
# no candidate exists (fresh repo, detached HEAD with no other refs).
detect_parent_branch() {
  local cur cand best="" best_dist=-1 dist
  cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    [ "$cand" = "$cur" ] && continue
    git merge-base --is-ancestor "$cand" HEAD 2>/dev/null || continue
    # Distance from the candidate tip to HEAD; the smallest is the closest parent.
    dist="$(git rev-list --count "${cand}..HEAD" 2>/dev/null || echo 999999)"
    if [ "$best_dist" -lt 0 ] || [ "$dist" -lt "$best_dist" ]; then
      best="$cand"; best_dist="$dist"
    fi
  done < <(git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)
  # A parent whose tip *is* HEAD (distance 0) means nothing was committed here yet;
  # still the right base — the diff is then just the working tree.
  [ -n "$best" ] && printf '%s' "$best"
}

resolve_base_ref() {
  local from_json remote_head
  if [ -n "${MTK_BASE_REF:-}" ]; then printf '%s' "$MTK_BASE_REF"; return; fi
  from_json="$(grep -E '^[[:space:]]*"base_ref"[[:space:]]*:' "$HANDOFF" 2>/dev/null \
    | sed -E 's/.*"base_ref"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' | head -1 || true)"
  if [ -n "$from_json" ]; then printf '%s' "$from_json"; return; fi
  from_json="$(detect_parent_branch || true)"
  if [ -n "$from_json" ]; then printf '%s' "$from_json"; return; fi
  remote_head="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$remote_head" ]; then printf '%s' "$remote_head"; return; fi
  printf 'main'
}

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

if [ "$FIELDS_ONLY" -eq 0 ] && [ -z "$BASE_REF" ]; then
  BASE_REF="$(resolve_base_ref)"
fi

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

  # Actual touched files from git: committed since base, uncommitted tracked,
  # and untracked-but-not-ignored. All three, always — a mid-run check that has
  # both commits and uncommitted work used to see only the commits.
  actual_files="$( {
      git diff --name-only "${BASE_REF}"...HEAD 2>/dev/null || true
      git diff --name-only HEAD 2>/dev/null || true
      git ls-files --others --exclude-standard 2>/dev/null || true
    } | grep -v '^$' \
      | grep -v -E '(^|/)docs/(specs|plans)/|^tasks/|^\.mtk/' \
      | sort -u || true)"
  # The exclusions mirror hooks/scope-guard.sh: spec/plan sidecars, todo/lessons,
  # and .mtk/ workflow state are written by the workflow itself, outside the
  # change_manifest by design — they are never drift. Without this, the very
  # sidecar being validated shows up as an undeclared file once untracked
  # files are counted.

  # Compute deltas, honoring directory entries (trailing `/`) in the manifest.
  covered() {  # $1 = actual file; true when some declared entry covers it
    local d
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      case "$d" in
        */) case "$1" in "$d"*) return 0 ;; esac ;;
        *)  [ "$1" = "$d" ] && return 0 ;;
      esac
    done <<< "$declared_files"
    return 1
  }
  touched() {  # $1 = declared entry; true when some actual file satisfies it
    local a
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      case "$1" in
        */) case "$a" in "$1"*) return 0 ;; esac ;;
        *)  [ "$a" = "$1" ] && return 0 ;;
      esac
    done <<< "$actual_files"
    return 1
  }
  extra_files=""
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    covered "$a" || extra_files="${extra_files}${a}"$'\n'
  done <<< "$actual_files"
  missing_files=""
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    touched "$d" || missing_files="${missing_files}${d}"$'\n'
  done <<< "$declared_files"
  extra_files="${extra_files%$'\n'}"
  missing_files="${missing_files%$'\n'}"

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
