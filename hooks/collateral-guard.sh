#!/usr/bin/env bash
set -euo pipefail
# collateral-guard.sh — flag churn in a diff that is not the change you made.
#
# The failure this catches has one shape and three faces: the intended change is
# small, the commit is huge, and the excess is machine-generated or whitespace.
#   - one `npm install` rewrites 39,000 lines of a lockfile into a feature commit
#   - a screenshot regeneration rewrites 78 of 84 images, mostly font rasterisation
#   - a 60-line edit to the one CRLF file in the repo produces a 2,013-line diff
#
# All three are caught by reading a diffstat, which is exactly the step that gets
# skipped under time pressure. Existing coverage does not reach them: the drift
# check inspects lockfiles for *undeclared dependencies* (a different question),
# and the churn thresholds count net lines to trigger a review without asking
# whether the churn is yours.
#
# Findings:
#   CG001 whitespace/EOL-only churn      — raw diff large, `-w` diff ~empty
#   CG002 generated artifact not declared — lockfile/snapshot/asset outside the manifest
#   CG003 asset-set rewrite               — most of a binary asset directory rewritten
#   CG004 structured-data reformat        — big JSON diff, tiny semantic change
#
# CG004 is the fourth face of the same shape, and the one CG001 cannot see: a
# tool that re-serializes a JSON file (a different indent, sorted keys, or
# ensure_ascii turning every em-dash into \u2014) produces genuinely different
# LINES, so `git diff -w` agrees with `git diff` and the whitespace check stays
# quiet. Comparing the two sides *parsed and canonicalised* is what separates a
# 60-line real edit from 300 lines of re-serialization.
#
# Exit codes:
#   0 — no collateral churn found
#   1 — collateral churn found (advisory: the caller decides)
#   2 — usage error or not a git repo
#
# Usage:
#   bash hooks/collateral-guard.sh                              # staged changes
#   bash hooks/collateral-guard.sh --head --human
#   bash hooks/collateral-guard.sh --range main...HEAD --manifest docs/specs/foo.json
#
# Spec: docs/plans/2026-08-20-field-run-dogfooding-improvements.md (P1.3)

DIFF_SOURCE="cached"
DIFF_RANGE=""
OUTPUT="json"
MANIFEST=""
WS_MIN_LINES="${MTK_COLLATERAL_WS_MIN:-50}"      # raw changed lines before whitespace churn is worth a word
WS_RATIO="${MTK_COLLATERAL_WS_RATIO:-5}"          # -w lines as % of raw lines, at or below which it is "whitespace-only"
GEN_MIN_LINES="${MTK_COLLATERAL_GEN_MIN:-200}"    # generated-file churn below this is noise, not a finding
ASSET_PCT="${MTK_COLLATERAL_ASSET_PCT:-50}"       # % of a binary asset dir rewritten before it is a finding
ASSET_MIN_FILES="${MTK_COLLATERAL_ASSET_MIN:-5}"  # smallest asset dir worth measuring a fraction of
FMT_MIN_LINES="${MTK_COLLATERAL_FMT_MIN:-100}"    # raw changed lines before a reformat is worth a word
FMT_RATIO="${MTK_COLLATERAL_FMT_RATIO:-25}"       # semantic lines as % of raw, at or below which it is a reformat

usage() {
  cat <<'EOF'
Usage: bash hooks/collateral-guard.sh [--cached|--head|--range <expr>] [--manifest <sidecar.json>] [--human]

Flags churn that is not the change you made: whitespace/EOL-only rewrites,
generated artifacts (lockfiles, snapshots, assets) absent from the change
manifest, and asset directories rewritten wholesale.

--cached            Staged changes (default)
--head              Working tree vs HEAD
--range <expr>      A git range, e.g. main...HEAD
--manifest <path>   Spec sidecar; declared change_manifest paths are exempt from CG002
--human             Human-readable output instead of JSON

Thresholds (env): MTK_COLLATERAL_WS_MIN, MTK_COLLATERAL_WS_RATIO,
MTK_COLLATERAL_GEN_MIN, MTK_COLLATERAL_ASSET_PCT, MTK_COLLATERAL_ASSET_MIN,
MTK_COLLATERAL_FMT_MIN, MTK_COLLATERAL_FMT_RATIO.

Exit 0 = clean, 1 = collateral found, 2 = usage error.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cached) DIFF_SOURCE="cached"; shift ;;
    --head)   DIFF_SOURCE="head"; shift ;;
    --range)  DIFF_SOURCE="range"; DIFF_RANGE="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    --manifest) MANIFEST="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    --human)  OUTPUT="human"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$DIFF_SOURCE" = "range" ] && [ -z "$DIFF_RANGE" ]; then
  printf 'collateral-guard: --range requires a range expression\n' >&2; exit 2
fi
git rev-parse --git-dir >/dev/null 2>&1 || {
  printf 'collateral-guard: not inside a git repository\n' >&2; exit 2; }

case "$DIFF_SOURCE" in
  cached) DIFF_ARGS=(--cached) ;;
  range)  DIFF_ARGS=("$DIFF_RANGE") ;;
  *)      DIFF_ARGS=(HEAD) ;;
esac

# The revision the diff is measured *from*, so CG004 can parse both sides.
# `A...B` compares against the merge base, matching git's own semantics.
case "$DIFF_SOURCE" in
  range)
    case "$DIFF_RANGE" in
      *...*) BASE_REV="$(git merge-base "${DIFF_RANGE%%...*}" "${DIFF_RANGE##*...}" 2>/dev/null || printf '%s' "${DIFF_RANGE%%...*}")" ;;
      *..*)  BASE_REV="${DIFF_RANGE%%..*}" ;;
      *)     BASE_REV="$DIFF_RANGE" ;;
    esac ;;
  *) BASE_REV="HEAD" ;;
esac

RAW="$(mktemp)"; WS="$(mktemp)"; DECLARED="$(mktemp)"
trap 'rm -f "$RAW" "$WS" "$DECLARED"' EXIT

git diff "${DIFF_ARGS[@]}" --numstat --no-color    > "$RAW" 2>/dev/null || true
git diff "${DIFF_ARGS[@]}" --numstat --no-color -w > "$WS"   2>/dev/null || true

# Declared paths (change_manifest) are the caller's intent — exempt from CG002.
: > "$DECLARED"
if [ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] && command -v python3 >/dev/null 2>&1; then
  python3 - "$MANIFEST" > "$DECLARED" <<'PY' || true
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for key in ("change_manifest", "test_manifest"):
    for entry in doc.get(key) or []:
        if isinstance(entry, dict) and entry.get("path"):
            print(str(entry["path"]).strip())
        elif isinstance(entry, str):
            print(entry.strip())
PY
fi

is_declared() {
  [ -s "$DECLARED" ] || return 1
  grep -qxF "$1" "$DECLARED"
}

# Paths that are produced by a tool rather than typed by a person.
is_generated() {
  case "$1" in
    */package-lock.json|package-lock.json) return 0 ;;
    */pnpm-lock.yaml|pnpm-lock.yaml|*/yarn.lock|yarn.lock) return 0 ;;
    */packages.lock.json|packages.lock.json) return 0 ;;
    */Cargo.lock|Cargo.lock|*/poetry.lock|poetry.lock|*/uv.lock|uv.lock) return 0 ;;
    */composer.lock|composer.lock|*/Gemfile.lock|Gemfile.lock|*/go.sum|go.sum) return 0 ;;
    */__snapshots__/*|*.snap) return 0 ;;
    *-snapshots/*|*/snapshots/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_binary_asset() {
  case "$1" in
    *.png|*.jpg|*.jpeg|*.gif|*.webp|*.avif|*.pdf|*.ico) return 0 ;;
    *) return 1 ;;
  esac
}

ws_lines_for() {
  # `-w` changed lines for a path; empty when the path is absent from the -w diff
  # (i.e. the whole change was whitespace).
  local p="$1" a d
  while IFS=$'\t' read -r a d f; do
    if [ "$f" = "$p" ]; then
      case "$a$d" in *-*) printf 'binary'; return ;; esac
      printf '%s' "$(( a + d ))"; return
    fi
  done < "$WS"
  printf '0'
}

# Changed lines between the two sides *parsed and canonicalised* — the semantic
# delta. Prints "skip" when either side is missing or unparseable, so a brand-new
# or malformed file is never reported as a reformat.
semantic_json_delta() {
  local path="$1" old sem
  old="$(mktemp)"
  if ! git show "$BASE_REV:$path" > "$old" 2>/dev/null; then rm -f "$old"; printf 'skip'; return; fi
  if [ ! -f "$path" ]; then rm -f "$old"; printf 'skip'; return; fi
  sem="$(python3 - "$old" "$path" <<'PY'
import json, sys, difflib
try:
    a = json.load(open(sys.argv[1]))
    b = json.load(open(sys.argv[2]))
except Exception:
    print("skip"); sys.exit(0)
def canon(d):
    return json.dumps(d, indent=2, sort_keys=True, ensure_ascii=False).splitlines()
print(sum(1 for l in difflib.unified_diff(canon(a), canon(b), n=0)
          if l[:1] in "+-" and l[:3] not in ("+++", "---")))
PY
)" || sem="skip"
  rm -f "$old"
  printf '%s' "${sem:-skip}"
}

findings=(); idx=0; crit=0; warn=0
total_lines=0; collateral_lines=0
declare -a asset_dirs=(); declare -a asset_counts=()

add_finding() {
  local rule="$1" sev="$2" path="$3" rationale="$4" fix="$5"
  idx=$((idx + 1))
  local fid; fid="$(printf 'CGF%03d' "$idx")"
  esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  findings+=("{\"id\":\"$fid\",\"severity\":\"$sev\",\"confidence\":100,\"source\":\"linter\",\"rule\":\"$rule\",\"file\":\"$(esc "$path")\",\"rationale\":\"$(esc "$rationale")\",\"suggested_fix\":\"$(esc "$fix")\"}")
  case "$sev" in critical) crit=$((crit + 1)) ;; *) warn=$((warn + 1)) ;; esac
}

restore_cmd() {
  case "$DIFF_SOURCE" in
    cached) printf 'git restore --staged --worktree -- %s' "$1" ;;
    *)      printf 'git restore -- %s' "$1" ;;
  esac
}

while IFS=$'\t' read -r added deleted path; do
  [ -n "${path:-}" ] || continue
  # Asset files are tallied per directory for CG003 and never line-counted.
  # Key on the extension, not on git's binary verdict: a small or text-ish
  # asset still reports numeric counts, and an asset-set rewrite is about how
  # many files moved, not how many lines did.
  if is_binary_asset "$path" || [ "$added" = "-" ] || [ "$deleted" = "-" ]; then
    if is_binary_asset "$path"; then
      d="$(dirname "$path")"
      found=0; i=0
      for existing in ${asset_dirs[@]+"${asset_dirs[@]}"}; do
        if [ "$existing" = "$d" ]; then
          asset_counts[$i]=$(( ${asset_counts[$i]} + 1 )); found=1; break
        fi
        i=$((i + 1))
      done
      [ "$found" = 0 ] && { asset_dirs+=("$d"); asset_counts+=(1); }
    fi
    continue
  fi

  raw=$(( added + deleted ))
  total_lines=$(( total_lines + raw ))
  wsl="$(ws_lines_for "$path")"
  [ "$wsl" = "binary" ] && continue

  # CG001 — whitespace / line-ending churn masquerading as a real change.
  if [ "$raw" -ge "$WS_MIN_LINES" ]; then
    ratio=$(( wsl * 100 / raw ))
    if [ "$ratio" -le "$WS_RATIO" ]; then
      collateral_lines=$(( collateral_lines + raw - wsl ))
      add_finding CG001 warning "$path" \
        "$raw changed lines, but only $wsl survive \`git diff -w\` (${ratio}%) — the rest is whitespace or line-ending churn, most likely a whole-file rewrite normalising CRLF" \
        "Re-apply the real edit without rewriting the file, or commit the normalisation on its own with a .gitattributes entry. Inspect with: git diff -w --stat -- $path"
    fi
  fi

  # CG004 — a structured file re-serialized around a small real change.
  if [ "$raw" -ge "$FMT_MIN_LINES" ] && command -v python3 >/dev/null 2>&1; then
    case "$path" in
      *.json)
        sem="$(semantic_json_delta "$path")"
        if [ "$sem" != "skip" ] && printf '%s' "$sem" | grep -qE '^[0-9]+$'; then
          sem_ratio=$(( sem * 100 / raw ))
          if [ "$sem_ratio" -le "$FMT_RATIO" ]; then
            collateral_lines=$(( collateral_lines + raw - sem ))
            add_finding CG004 warning "$path" \
              "$raw changed lines, but only $sem differ once both sides are parsed and canonicalised (${sem_ratio}%) — the file was re-serialized (indent, key order, or non-ASCII escaping) around a much smaller real edit" \
              "Re-apply the edit as text rather than round-tripping the file through a serializer. See the real change with: git diff $BASE_REV -- $path"
          fi
        fi
        ;;
    esac
  fi

  # CG002 — a generated artifact riding along undeclared.
  if is_generated "$path" && [ "$raw" -ge "$GEN_MIN_LINES" ] && ! is_declared "$path"; then
    collateral_lines=$(( collateral_lines + raw ))
    add_finding CG002 warning "$path" \
      "$raw changed lines in a generated file that is not in the change manifest — a tool run (install, snapshot, codegen) rode along with this change" \
      "Revert it unless the change is intentional, then declare it in the manifest: $(restore_cmd "$path")"
  fi
done < "$RAW"

# CG003 — most of an asset directory rewritten.
i=0
for d in ${asset_dirs[@]+"${asset_dirs[@]}"}; do
  n="${asset_counts[$i]}"; i=$((i + 1))
  tracked="$(git ls-files -- "$d" 2>/dev/null | grep -c -E '\.(png|jpg|jpeg|gif|webp|avif|pdf|ico)$' || true)"
  [ -n "$tracked" ] || tracked=0
  [ "$tracked" -ge "$ASSET_MIN_FILES" ] || continue
  pct=$(( n * 100 / tracked ))
  if [ "$pct" -ge "$ASSET_PCT" ]; then
    add_finding CG003 warning "$d" \
      "$n of $tracked binary assets in $d were rewritten (${pct}%) — a wholesale regeneration, where a real change usually touches a handful" \
      "Keep only the assets this change actually needed and revert the rest: $(restore_cmd "$d")"
  fi
done

verdict="PASS"
if [ "$crit" -gt 0 ]; then
  verdict="NEEDS_CHANGES"
elif [ "$warn" -gt 0 ]; then
  verdict="REVIEW"
fi

if [ "$OUTPUT" = "human" ]; then
  printf 'Collateral guard: %s  (findings=%d; %d of %d changed text lines look like collateral)\n' \
    "$verdict" "$(( crit + warn ))" "$collateral_lines" "$total_lines"
  for f in ${findings[@]+"${findings[@]}"}; do printf '%s\n' "$f"; done
else
  joined=""; first=1
  for f in ${findings[@]+"${findings[@]}"}; do
    if [ "$first" = 1 ]; then joined="$f"; first=0; else joined="$joined,$f"; fi
  done
  printf '{"source":"linter","check":"collateral-guard","verdict":"%s","summary":{"critical":%d,"warning":%d,"collateral_lines":%d,"total_lines":%d},"findings":[%s]}\n' \
    "$verdict" "$crit" "$warn" "$collateral_lines" "$total_lines" "$joined"
fi

[ "$(( crit + warn ))" -eq 0 ] && exit 0
exit 1
