#!/usr/bin/env bash
set -euo pipefail
# manifest-preflight.sh — validate a spec sidecar's change_manifest DESTINATIONS
# against the repo, before the Phase 2.5 seal.
#
# Phase 0.7 reconciliation already checks *cited anchors* — existing code the
# change attaches to. Nobody checked the other half: the destinations the
# manifest proposes to create or modify, and the conventions those paths imply.
# A manifest can name a directory that does not exist, a file that lives
# somewhere else, or a filename shape no sibling uses, and none of that surfaces
# until Phase 3.5 records it as drift — after an implementer has already built
# against the wrong path.
#
# Checks, per change_manifest entry:
#   MP001 modify/delete target missing                     (critical)
#   MP002 modify/delete target missing but basename exists elsewhere (critical)
#   MP003 create target already exists                     (warning)
#   MP004 create into a directory that does not exist       (warning)
#         + pattern probe: does the idiom the path presumes exist anywhere?
#   MP005 filename breaks the sibling naming convention     (warning)
#   MP006 sibling companion-file convention not honored     (warning)
#
# MP004's pattern probe is the check that catches a manifest presuming a pattern
# the codebase does not use at all (e.g. a Configurations/ directory in a
# solution that configures every entity inline).
#
# Exit codes:
#   0 — clean (no findings)
#   1 — findings emitted (critical or warning)
#   2 — usage error, unreadable sidecar, or not a git repo
#
# Usage:
#   bash scripts/manifest-preflight.sh docs/specs/2026-08-20-foo.json
#   bash scripts/manifest-preflight.sh --human docs/specs/2026-08-20-foo.json
#
# Spec: docs/plans/2026-08-20-field-run-dogfooding-improvements.md (P1.1)

OUTPUT="json"
SIDECAR=""
MIN_SIBLINGS=3
CONVENTION_RATIO=60   # percent of siblings that must share a shape for it to be a convention

usage() {
  cat <<'EOF'
Usage: bash scripts/manifest-preflight.sh [--human] [--min-siblings N] <spec-sidecar.json>

Validates every change_manifest destination in the sidecar against the repo:
missing modify targets, relocated files, creates into non-existent directories
(with a pattern probe), and sibling naming/companion conventions.

--human           Human-readable output instead of JSON
--min-siblings N  Minimum sibling count before a naming convention is inferred (default 3)

Exit 0 = clean, 1 = findings, 2 = usage/input error.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --human) OUTPUT="human"; shift ;;
    --min-siblings) MIN_SIBLINGS="${2:-3}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    -h|--help) usage; exit 0 ;;
    -*) printf 'Unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    *) SIDECAR="$1"; shift ;;
  esac
done

[ -n "$SIDECAR" ] || { printf 'manifest-preflight: no sidecar given\n' >&2; usage >&2; exit 2; }
[ -f "$SIDECAR" ] || { printf 'manifest-preflight: no such file: %s\n' "$SIDECAR" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || {
  printf 'manifest-preflight: python3 is required to parse the sidecar\n' >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || {
  printf 'manifest-preflight: not inside a git repository\n' >&2; exit 2; }

REPO_ROOT="$(git rev-parse --show-toplevel)"

# --- Read the manifest as TSV: path <TAB> action -------------------------------
# A malformed sidecar is an input error, not a silent pass.
ENTRIES="$(python3 - "$SIDECAR" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        doc = json.load(fh)
except Exception as exc:                      # unreadable/invalid -> exit 2 below
    print("__ERROR__\t%s" % exc)
    sys.exit(0)
cm = doc.get("change_manifest")
if not isinstance(cm, list):
    print("__ERROR__\tchange_manifest missing or not an array")
    sys.exit(0)
for entry in cm:
    if not isinstance(entry, dict):
        continue
    path = str(entry.get("path", "")).strip()
    action = str(entry.get("action", "")).strip().lower()
    if path:
        print("%s\t%s" % (path, action))
PY
)"

case "$ENTRIES" in
  __ERROR__*)
    printf 'manifest-preflight: %s\n' "${ENTRIES#__ERROR__$'\t'}" >&2
    exit 2 ;;
esac

# --- Repo file index (tracked files, once) ------------------------------------
FILE_INDEX="$(mktemp)"; DIR_INDEX="$(mktemp)"
trap 'rm -f "$FILE_INDEX" "$DIR_INDEX"' EXIT
( cd "$REPO_ROOT" && git ls-files ) > "$FILE_INDEX"
# Every directory that holds at least one tracked file.
sed 's:/[^/]*$::' "$FILE_INDEX" | sort -u > "$DIR_INDEX"

findings=()
crit=0; warn=0
idx=0

add_finding() {
  # add_finding <rule> <severity> <path> <rationale> <fix>
  local rule="$1" sev="$2" path="$3" rationale="$4" fix="$5"
  idx=$((idx + 1))
  local fid; fid="$(printf 'MPF%03d' "$idx")"
  esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  findings+=("{\"id\":\"$fid\",\"severity\":\"$sev\",\"confidence\":100,\"source\":\"linter\",\"rule\":\"$rule\",\"file\":\"$(esc "$path")\",\"rationale\":\"$(esc "$rationale")\",\"suggested_fix\":\"$(esc "$fix")\"}")
  case "$sev" in
    critical) crit=$((crit + 1)) ;;
    *)        warn=$((warn + 1)) ;;
  esac
}

# Count tracked files whose name ends with the given suffix. Kept as a suffix
# count rather than a general glob matcher: the only question asked here is
# "does any file of this shape exist?", and grep answers it without piping into
# an early-exiting consumer (S3.17).
count_suffix() {
  local suffix="$1" n
  n="$(grep -c -E "$(printf '%s' "$suffix" | sed 's/[][\.^$*+?(){}|]/\\&/g')$" "$FILE_INDEX" || true)"
  [ -n "$n" ] || n=0
  printf '%s' "$n"
}

# The trailing token of a basename — the idiom the filename presumes.
# PascalCase: LifecycleTemplateConfiguration -> Configuration
# kebab/snake: app-sidebar -> sidebar
suffix_token() {
  local stem="$1" tok
  case "$stem" in
    *-*) tok="${stem##*-}" ;;
    *_*) tok="${stem##*_}" ;;
    *)   tok="$(printf '%s' "$stem" | sed -E 's/.*([A-Z][a-z0-9]+)$/\1/')" ;;
  esac
  printf '%s' "$tok"
}

while IFS=$'\t' read -r path action; do
  [ -n "$path" ] || continue
  abs="$REPO_ROOT/$path"
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  stem="${base%.*}"
  ext=""
  case "$base" in *.*) ext=".${base##*.}" ;; esac

  case "$action" in
    modify|delete)
      if [ ! -e "$abs" ]; then
        # Does the basename live somewhere else? That is a relocation, not a gap.
        elsewhere="$(grep -E "(^|/)$(printf '%s' "$base" | sed 's/[][\.^$*+?(){}|]/\\&/g')$" "$FILE_INDEX" || true)"
        if [ -n "$elsewhere" ]; then
          first="$(printf '%s' "$elsewhere" | sed -n '1p')"
          add_finding MP002 critical "$path" \
            "change_manifest says action=$action but the path does not exist; a file named $base is tracked at $first" \
            "Repoint this entry at the real path (e.g. $first) before sealing, or change the action to create."
        else
          add_finding MP001 critical "$path" \
            "change_manifest says action=$action but the path does not exist, and no file named $base is tracked anywhere in the repo" \
            "Find the file that actually holds this behavior and repoint the entry, or change the action to create."
        fi
      fi
      ;;
    create)
      if [ -e "$abs" ]; then
        add_finding MP003 warning "$path" \
          "change_manifest says action=create but the path already exists" \
          "Change the action to modify so the drift check compares against the right baseline."
      elif [ ! -d "$REPO_ROOT/$dir" ]; then
        # A brand-new directory. Probe whether the idiom the path presumes
        # exists anywhere — a manifest presuming a pattern the codebase does not
        # use is the expensive failure this rule exists to catch.
        dirbase="$(basename "$dir")"
        dir_hits="$(grep -c -E "(^|/)$(printf '%s' "$dirbase" | sed 's/[][\.^$*+?(){}|]/\\&/g')(/|$)" "$DIR_INDEX" || true)"
        [ -n "$dir_hits" ] || dir_hits=0
        tok="$(suffix_token "$stem")"
        tok_hits=0
        if [ -n "$tok" ] && [ -n "$ext" ]; then
          tok_hits="$(count_suffix "${tok}${ext}")"
        fi
        if [ "$dir_hits" -eq 0 ] && [ "$tok_hits" -eq 0 ]; then
          add_finding MP004 warning "$path" \
            "creates into a directory that does not exist ($dir), no directory named $dirbase exists anywhere, and no tracked file matches *${tok}${ext} — the pattern this path presumes may not be used in this codebase at all" \
            "Read how the codebase does this today before sealing. If the pattern genuinely is absent, either follow the existing convention or record the new pattern as a deliberate decision in the spec."
        else
          add_finding MP004 warning "$path" \
            "creates into a directory that does not exist ($dir); $dir_hits directory(ies) named $dirbase and $tok_hits file(s) matching *${tok}${ext} exist elsewhere" \
            "Confirm the destination against the existing convention — a sibling location may already be the right home."
        fi
      else
        # Parent exists: check its naming conventions against the proposed name.
        sibs="$(grep -E "^$(printf '%s' "$dir" | sed 's/[][\.^$*+?(){}|]/\\&/g')/[^/]*$(printf '%s' "$ext" | sed 's/[][\.^$*+?(){}|]/\\&/g')$" "$FILE_INDEX" || true)"
        sib_count=0
        [ -n "$sibs" ] && sib_count="$(printf '%s\n' "$sibs" | grep -c . || true)"
        if [ "$sib_count" -ge "$MIN_SIBLINGS" ]; then
          # Numeric/timestamp prefix convention.
          prefixed="$(printf '%s\n' "$sibs" | grep -c -E "/[0-9]{6,}[_-]" || true)"
          [ -n "$prefixed" ] || prefixed=0
          pct=$(( prefixed * 100 / sib_count ))
          if [ "$pct" -ge "$CONVENTION_RATIO" ] && ! printf '%s' "$base" | grep -qE '^[0-9]{6,}[_-]'; then
            add_finding MP005 warning "$path" \
              "$prefixed of $sib_count files in $dir carry a numeric/timestamp prefix; the proposed name $base does not" \
              "Generate the name with the tool that owns this directory (e.g. the migration generator) rather than hand-writing it into the manifest."
          fi
          # Companion-file convention (e.g. EF migration .Designer.cs).
          designer="$(printf '%s\n' "$sibs" | grep -c -E "\.Designer${ext//./\\.}$" || true)"
          [ -n "$designer" ] || designer=0
          # An entry that IS a companion needs no companion of its own.
          if [ "$designer" -gt 0 ] && ! printf '%s' "$stem" | grep -qE '\.Designer$'; then
            want="$dir/$stem.Designer$ext"
            if ! printf '%s\n' "$ENTRIES" | grep -qF "$want"; then
              add_finding MP006 warning "$path" \
                "$dir holds $designer .Designer$ext companion file(s); the manifest declares no companion for $base" \
                "Add $want to the change_manifest, or confirm the generator does not emit one for this entry."
            fi
          fi
        fi
      fi
      ;;
    *)
      add_finding MP001 critical "$path" \
        "change_manifest entry has action='$action' — not one of create/modify/delete" \
        "Fix the action so the drift check and this pre-flight can reason about the entry."
      ;;
  esac
done <<< "$ENTRIES"

verdict="PASS"
[ "$crit" -gt 0 ] && verdict="NEEDS_CHANGES"
[ "$crit" -eq 0 ] && [ "$warn" -gt 0 ] && verdict="REVIEW"

if [ "$OUTPUT" = "human" ]; then
  printf 'Manifest pre-flight: %s  (critical=%d warning=%d)\n' "$verdict" "$crit" "$warn"
  for f in ${findings[@]+"${findings[@]}"}; do printf '%s\n' "$f"; done
else
  joined=""; first=1
  for f in ${findings[@]+"${findings[@]}"}; do
    if [ "$first" = 1 ]; then joined="$f"; first=0; else joined="$joined,$f"; fi
  done
  printf '{"source":"linter","check":"manifest-preflight","verdict":"%s","summary":{"critical":%d,"warning":%d},"findings":[%s]}\n' \
    "$verdict" "$crit" "$warn" "$joined"
fi

[ "$crit" -eq 0 ] && [ "$warn" -eq 0 ] && exit 0
exit 1
