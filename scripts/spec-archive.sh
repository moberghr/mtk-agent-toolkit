#!/usr/bin/env bash
set -euo pipefail

# spec-archive.sh — Sync a feature spec (delta) back into its area baseline and
# append an audit record (archive-merges-back model).
#
# Run ONLY after spec-drift-detection returns a clean PASS. See
# .claude/references/delta-spec-model.md for the model.
#
# Usage:
#   bash scripts/spec-archive.sh <spec.json> [--verdict PASS] [--at <ISO8601>]
#
#   --verdict   drift verdict to record (default PASS). Refuses non-PASS.
#   --at        timestamp to stamp (default: `date -u`). Lets callers pin time.
#
# Idempotent: re-archiving the same slug for the same area is a no-op.

# Resolve the TARGET repo root — never this script's own location. Baseline
# artifacts (docs/specs/baseline/*, CODE_INDEX.md) must land in the project being
# archived, so when MTK runs from a separate checkout the output can't leak into
# the toolkit clone. Mirrors workflow-artifact.sh / learnings.sh.
ROOT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT_DIR"

command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 2; }

SPEC_JSON="${1:-}"
[ -n "$SPEC_JSON" ] || { echo "Usage: spec-archive.sh <spec.json> [--verdict PASS] [--at <ISO8601>]" >&2; exit 2; }
[ -f "$SPEC_JSON" ] || { echo "ERROR: spec sidecar not found: $SPEC_JSON" >&2; exit 2; }
shift

VERDICT="PASS"
STAMP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --verdict) VERDICT="${2:-}"; shift 2 ;;
    --at)      STAMP="${2:-}"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$STAMP" ] || STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "$VERDICT" != "PASS" ]; then
  echo "REFUSED: drift verdict is '$VERDICT', not PASS. Fix drift before archiving." >&2
  exit 1
fi

AREA="$(jq -r '.baseline_area // empty' "$SPEC_JSON")"
SLUG="$(jq -r '.slug // empty' "$SPEC_JSON")"
DATE="$(jq -r '.date // empty' "$SPEC_JSON")"
[ -n "$AREA" ] || { echo "ERROR: spec has no baseline_area — cannot archive. Add it to the sidecar." >&2; exit 1; }
[ -n "$SLUG" ] || { echo "ERROR: spec has no slug." >&2; exit 1; }

# Baseline lives under the artifact root that owns this spec — for a spec inside
# a subtree that owns its docs/specs, the baseline belongs there too, not at the
# repo root. Resolved from the spec's own path so archiving is location-correct
# regardless of the CWD the command ran from.
_RAR="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)/resolve-artifact-root.sh"
[ -f "$_RAR" ] || _RAR="${CLAUDE_PLUGIN_ROOT:-.}/scripts/resolve-artifact-root.sh"
if [ -f "$_RAR" ]; then
  ARTIFACT_ROOT="$(bash "$_RAR" "$SPEC_JSON" 2>/dev/null || printf '%s' "$ROOT_DIR")"
else
  ARTIFACT_ROOT="$ROOT_DIR"
fi
BASE_DIR="${ARTIFACT_ROOT:-$ROOT_DIR}/docs/specs/baseline"
BASE_JSON="$BASE_DIR/$AREA.json"
BASE_MD="$BASE_DIR/$AREA.md"
AUDIT="$BASE_DIR/$AREA.audit.jsonl"
mkdir -p "$BASE_DIR"

# Idempotency: already archived this slug? Match exact slug values in the audit
# trail with jq (not grep) so a slug containing regex/substring metachars cannot
# falsely match a different slug and silently drop this archive.
if [ -f "$AUDIT" ] && jq -e --arg s "$SLUG" 'select(.slug == $s)' "$AUDIT" >/dev/null 2>&1; then
  echo "NO-OP: '$SLUG' already archived to baseline '$AREA'."
  exit 0
fi

# Sidecar shape pre-validation: catch a malformed spec with a clear message
# before jq's merge turns it into a degenerate baseline.
if ! jq -e '
    ((.change_manifest // []) | type == "array")
    and ((.public_contracts // []) | type == "array")
    and (((.delta.removes) // []) | type == "array")
  ' "$SPEC_JSON" >/dev/null 2>&1; then
  echo "REFUSED: spec sidecar is malformed — change_manifest, public_contracts, and delta.removes must be arrays when present." >&2
  exit 2
fi

# Seed an empty baseline if absent.
if [ ! -f "$BASE_JSON" ]; then
  echo "{\"area\":\"$AREA\",\"contracts\":{},\"files\":{},\"history\":[]}" | jq . > "$BASE_JSON"
fi

# ── Merge guards (fail-safe in every direction) ─────────────────────────────
# The archive promise is "never deletes from the baseline by inference". These
# guards make that promise CHECKED rather than assumed-by-construction, so a
# future merge refactor or a degenerate sidecar cannot silently break it.

# Guard 1 — unmatched removes. A delta.removes entry that matches nothing in
# the baseline is almost always a typo (wrong case, stale signature): the
# thing the spec meant to remove would survive forever, silently. Refuse, and
# suggest near-misses via case/whitespace-folded comparison.
UNMATCHED="$(jq -rn --slurpfile old "$BASE_JSON" --slurpfile spec "$SPEC_JSON" '
  def fold: ascii_downcase | gsub("[[:space:]]+"; "");
  ((($old[0].contracts // {}) | keys) + (($old[0].files // {}) | keys)) as $ok
  | ((($spec[0].delta.removes) // []) - $ok)[]
  | . as $miss
  | ($ok | map(select(fold == ($miss | fold))) | first // "") as $near
  | if $near != "" then "\($miss)\t(did you mean: \($near)?)" else "\($miss)\t" end
')"
if [ -n "$UNMATCHED" ]; then
  echo "REFUSED: delta.removes entries match nothing in baseline '$AREA' — a remove that matches nothing removes nothing, forever:" >&2
  printf '%s\n' "$UNMATCHED" | while IFS="$(printf '\t')" read -r miss near; do
    echo "  - $miss ${near}" >&2
  done
  echo "Fix the spec's delta.removes (exact key match required), then re-archive. Baseline untouched." >&2
  exit 2
fi

# Same-directory temp file so the final rename is atomic (a /tmp mktemp makes
# mv a cross-device copy, which can be observed half-written).
tmp="$(mktemp "$BASE_DIR/.$AREA.json.tmp.XXXXXX")"
trap 'rm -f "$tmp" "${tmp_md:-}"' EXIT

# Merge: fold public_contracts and change_manifest into the baseline maps,
# keyed by signature / path. Then apply explicit delta.removes.
jq \
  --arg slug "$SLUG" \
  --arg date "$DATE" \
  --arg verdict "$VERDICT" \
  --arg at "$STAMP" \
  --slurpfile spec "$SPEC_JSON" \
'
  ($spec[0]) as $s
  | .contracts as $c0
  | .files as $f0
  # contracts keyed by signature
  | .contracts = (reduce ($s.public_contracts // [])[] as $pc ($c0;
      .[$pc.signature] = { kind: ($pc.kind // "?"), change: ($pc.change // "?"),
                           source_slug: $slug, date: $date }))
  # files keyed by path
  | .files = (reduce ($s.change_manifest // [])[] as $fm ($f0;
      .[$fm.path] = { action: ($fm.action // "?"), purpose: ($fm.purpose // ""),
                      source_slug: $slug }))
  # explicit removes drop keys from both maps
  | .contracts = (reduce (($s.delta.removes) // [])[] as $r (.contracts; del(.[$r])))
  | .files     = (reduce (($s.delta.removes) // [])[] as $r (.files;     del(.[$r])))
  | .history += [ { slug: $slug, date: $date, verdict: $verdict, archived_at: $at } ]
' "$BASE_JSON" > "$tmp"

# Guard 2 — re-validate the merged result before anything is replaced.
jq empty "$tmp" 2>/dev/null || {
  echo "REFUSED: merged baseline is not valid JSON — baseline untouched." >&2
  exit 2
}

# Guard 3 — loss accounting. Every key that disappeared from the baseline must
# be exactly accounted for by an explicit delta.removes entry; anything else is
# silent content loss and refuses the merge, naming the lost keys.
LOST="$(jq -rn --slurpfile old "$BASE_JSON" --slurpfile new "$tmp" --slurpfile spec "$SPEC_JSON" '
  ((($old[0].contracts // {}) | keys) + (($old[0].files // {}) | keys)) as $ok
  | ((($new[0].contracts // {}) | keys) + (($new[0].files // {}) | keys)) as $nk
  | ((($spec[0].delta.removes) // [])) as $rm
  | (($ok - $nk) - $rm)[]
')"
if [ -n "$LOST" ]; then
  echo "REFUSED: merge would silently drop baseline content not listed in delta.removes — baseline untouched:" >&2
  printf '%s\n' "$LOST" | while IFS= read -r k; do echo "  - $k" >&2; done
  exit 2
fi

# Regenerate the human-readable baseline view — to a temp file first, so the
# JSON, the MD, and the audit record land all-or-nothing after every guard.
tmp_md="$(mktemp "$BASE_DIR/.$AREA.md.tmp.XXXXXX")"
{
  echo "# Baseline — $AREA"
  echo
  echo "> GENERATED by \`scripts/spec-archive.sh\` — do not edit by hand."
  echo "> Edit the feature spec and re-archive to change this."
  echo
  echo "## Public contracts"
  echo
  echo "| Signature | Kind | Last change | Source slug |"
  echo "|---|---|---|---|"
  jq -r '.contracts | to_entries[] | "| \(.key) | \(.value.kind) | \(.value.change) | \(.value.source_slug) |"' "$tmp" | sort
  echo
  echo "## Files"
  echo
  echo "| Path | Action | Source slug | Purpose |"
  echo "|---|---|---|---|"
  jq -r '.files | to_entries[] | "| \(.key) | \(.value.action) | \(.value.source_slug) | \(.value.purpose) |"' "$tmp" | sort
  echo
  echo "## Archive history"
  echo
  jq -r '.history[] | "- \(.date) · \(.slug) · drift \(.verdict) · archived \(.archived_at)"' "$tmp"
} > "$tmp_md"

# ── Commit point: every guard passed — replace atomically, then audit ────────
mv "$tmp" "$BASE_JSON"
mv "$tmp_md" "$BASE_MD"
trap - EXIT

# Append audit record (compact one-liner).
adds="$(jq -c '[(.change_manifest // [])[].path] + [(.public_contracts // [])[].signature]' "$SPEC_JSON")"
removes="$(jq -c '(.delta.removes) // []' "$SPEC_JSON")"
printf '{"slug":"%s","date":"%s","verdict":"%s","archived_at":"%s","adds":%s,"removes":%s}\n' \
  "$SLUG" "$DATE" "$VERDICT" "$STAMP" "$adds" "$removes" >> "$AUDIT"

# Fold newly shipped public contracts into the repo's capability index, if one
# exists — completed deltas become living documentation, not just an audit
# trail. Append-only (shrink-guard exempt per S3.16); idempotent via slug marker.
CODE_INDEX="CODE_INDEX.md"
if [ -f "$CODE_INDEX" ] && ! grep -qF "spec $SLUG" "$CODE_INDEX" 2>/dev/null; then
  NEW_CONTRACTS="$(jq -r '(.public_contracts // [])[] | select(.change == "new") | .signature + "\t" + (.kind // "?")' "$SPEC_JSON")"
  if [ -n "$NEW_CONTRACTS" ]; then
    FIRST_PATH="$(jq -r '(.change_manifest // [])[0].path // "?"' "$SPEC_JSON")"
    SECTION="## Recently Shipped (auto-generated)"
    {
      if ! grep -qF "$SECTION" "$CODE_INDEX"; then
        echo ""
        echo "$SECTION"
        echo ""
        echo "> Appended by \`scripts/spec-archive.sh\` at archive time — newly shipped public contracts."
        echo "> Fold rows into the matching domain section on the next index refresh."
        echo ""
        echo "| Capability | Entry point | Notes |"
        echo "|---|---|---|"
      fi
      while IFS="$(printf '\t')" read -r sig kind; do
        [ -n "$sig" ] || continue
        printf '| %s (%s) | `%s` | shipped %s · spec %s (auto) |\n' "$sig" "$kind" "$FIRST_PATH" "$DATE" "$SLUG"
      done <<EOF_CONTRACTS
$NEW_CONTRACTS
EOF_CONTRACTS
    } >> "$CODE_INDEX"
  fi
fi

# Baseline growth advisory (never blocks): a living baseline that outgrows a
# comfortable context load defeats its purpose as the cheap always-loadable
# view. Thresholds are advisory; token estimate is chars/4, a floor.
MAX_LINES="${MTK_BASELINE_MAX_LINES:-800}"
MAX_TOKENS="${MTK_BASELINE_MAX_TOKENS:-40000}"
md_lines="$(wc -l < "$BASE_MD" | tr -d ' ')"
md_tokens="$(( $(wc -c < "$BASE_MD" | tr -d ' ') / 4 ))"
if [ "$md_lines" -gt "$MAX_LINES" ] || [ "$md_tokens" -gt "$MAX_TOKENS" ]; then
  echo "ADVISORY: baseline '$AREA' is ${md_lines} lines / ~${md_tokens} est. tokens (budget ${MAX_LINES} lines / ${MAX_TOKENS} tokens)." >&2
  echo "  Consider partitioning the area into narrower baseline_area values — a baseline too big to load cheaply stops being read. (Tune: MTK_BASELINE_MAX_LINES / MTK_BASELINE_MAX_TOKENS.)" >&2
fi

echo "Archived '$SLUG' into baseline '$AREA':"
echo "  $BASE_JSON"
echo "  $BASE_MD"
echo "  $AUDIT (+1 record)"
if [ -f "$CODE_INDEX" ]; then
  echo "  $CODE_INDEX (capability index updated for new public contracts)"
fi
