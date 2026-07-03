#!/usr/bin/env bash
set -euo pipefail

# setup-refresh-plan.sh — staleness plan for the /mtk-setup --refresh / --check
# loop (F1/F2). Read-only: writes nothing to the target repo, no side effects.
#
# Reports one row per generated artifact, degrading a row to `unknown` (or, for
# the path-references row, skipping it) when its helper script is missing —
# this must work from a plugin install where CWD is a target repo that never
# received a copy of scripts/*.sh. Sibling helper scripts are resolved via this
# script's own directory (SCRIPT_DIR), never via the target repo's CWD, so it
# behaves the same whether run from a local clone or a plugin cache.
#
# Rows (artifact | status | reason):
#   1. .claude/references/architecture-principles.md — delegates to
#      audit-drift-check.sh --json. drift -> stale; no stamp -> unstamped;
#      absent -> missing; else -> fresh. Helper script missing -> unknown.
#   2. .claude/references/conventions.md — same treatment as row 1.
#   3. CLAUDE.md — (a) footer `mtk-setup: vX.Y.Z` vs `.claude/mtk-version.json`
#      -> stale on mismatch; (b) dependency rescan: extract top-level
#      dependency names from package.json / *.csproj / pyproject.toml and
#      cross-reference identifier-shaped backtick tokens in CLAUDE.md +
#      .claude/rules/*.md, flagging documented names no longer declared as a
#      dependency -> stale. Missing CLAUDE.md -> missing; no stack manifest at
#      all -> unknown (heuristic, not exhaustive: false negatives on bare
#      package names with no separator are expected and accepted).
#   4. .claude/detected-tools.json — mtime older than 7 days -> stale (matches
#      the setup-bootstrap detection-cache TTL convention); absent -> missing.
#   5. AGENTS.md — first checked for generate-agents-md.sh's own
#      auto-generated marker directly (grep, no subprocess): a hand-curated
#      AGENTS.md without the marker -> unknown, and the regenerator is never
#      invoked (generate-agents-md.sh would itself refuse to overwrite it, so
#      there is nothing meaningful to diff). When the marker is present, a
#      copy of the real file seeds the temp target (so the generator's
#      `## Custom:` section harvesting sees the real content, not an empty
#      file) before regenerating into it via generate-agents-md.sh --force
#      and diffing against the real one; differs -> stale; script or
#      AGENTS.md absent -> unknown.
#   6. path-references — runs verify-references.sh; exit 3 (STALE lines) ->
#      stale with the count; script absent -> row is OMITTED (not `unknown`;
#      this is the one explicit exception to the general degradation rule).
#   7. .claude/setup-answers.json — informational only: `present` / `absent`.
#      Never affects the --check exit code or the summary counts.
#
# Usage:
#   bash scripts/setup-refresh-plan.sh [--json] [--check]
#
# Output:
#   default  — fixed-width markdown table + one summary line
#              ("N fresh, N stale, N missing, N unstamped/unknown")
#   --json   — {"generated":"<ISO8601>","artifacts":[{"artifact","status",
#              "reason"}, ...],"summary":{"fresh","stale","missing",
#              "unstamped_unknown"}} — built via python3.
#
# Exit codes:
#   0 — always, except with --check
#   1 — (--check only) at least one non-informational row is stale or missing;
#       prints `run /mtk-setup --refresh to reconcile` to stderr
#   2 — usage error, or not run inside a git repository
#
# Spec: docs/specs/2026-07-02-v718-setup-refresh.md (F2)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  awk '/^# /{f=1} f{ if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

FORMAT="markdown"
CHECK=0
for arg in "$@"; do
  case "$arg" in
    --json) FORMAT="json" ;;
    --check) CHECK=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: setup-refresh-plan: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: setup-refresh-plan: not inside a git repository" >&2
  exit 2
fi

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

HAVE_PYTHON3=0
command -v python3 >/dev/null 2>&1 && HAVE_PYTHON3=1

if [ "$FORMAT" = "json" ] && [ "$HAVE_PYTHON3" -ne 1 ]; then
  echo "ERROR: setup-refresh-plan: --json requires python3" >&2
  exit 2
fi

TMP_DIR="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked indirectly via `trap ... EXIT` below
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

ROWS_FILE="$TMP_DIR/rows.tsv"
: > "$ROWS_FILE"

# Append one row. Tabs/newlines in $3 are flattened to spaces since rows.tsv
# is tab-delimited and consumed line-by-line by both renderers below.
add_row() {
  local artifact="$1" status="$2" reason="$3"
  reason="${reason//$'\t'/ }"
  reason="${reason//$'\n'/ }"
  printf '%s\t%s\t%s\n' "$artifact" "$status" "$reason" >> "$ROWS_FILE"
}

# --- Rows 1 & 2: drift-checked docs (delegates to audit-drift-check.sh) -----
check_drift_doc() {
  local doc="$1"
  if [ ! -f "$doc" ]; then
    add_row "$doc" "missing" "file not found"
    return
  fi
  local helper="$SCRIPT_DIR/audit-drift-check.sh"
  if [ ! -f "$helper" ]; then
    add_row "$doc" "unknown" "audit-drift-check.sh not found"
    return
  fi
  local out rc=0
  out="$(bash "$helper" "$doc" --json 2>/dev/null)" || rc=$?
  if [ "$HAVE_PYTHON3" -ne 1 ]; then
    add_row "$doc" "unknown" "python3 not available to parse audit-drift-check.sh output"
    return
  fi
  local parsed status reason
  parsed="$(python3 - "$rc" "$out" <<'PY'
import json, sys
rc = int(sys.argv[1])
raw = sys.argv[2]
try:
    data = json.loads(raw)
except Exception:
    print("unknown")
    print("could not parse audit-drift-check.sh output")
    sys.exit(0)
if not data.get("stamped", False):
    print("unstamped")
    print("no audited-against stamp found")
elif data.get("reachable", True) is False:
    print("unknown")
    print("stamp sha not reachable in this clone")
else:
    drift = data.get("drift", [])
    if rc == 1 and drift:
        print("stale")
        print(f"{len(drift)} claim(s) touch changed files")
    else:
        print("fresh")
        print("no drift since last audit")
PY
)"
  status="${parsed%%$'\n'*}"
  reason="${parsed#*$'\n'}"
  add_row "$doc" "$status" "$reason"
}

check_drift_doc ".claude/references/architecture-principles.md"
check_drift_doc ".claude/references/conventions.md"

# --- Row 3: CLAUDE.md (version-drift footer + dependency rescan) -----------
check_claude_md() {
  local doc="CLAUDE.md"
  if [ ! -f "$doc" ]; then
    add_row "$doc" "missing" "file not found"
    return
  fi
  if [ "$HAVE_PYTHON3" -ne 1 ]; then
    add_row "$doc" "unknown" "python3 not available for version/dependency checks"
    return
  fi
  local parsed status reason
  parsed="$(python3 - <<'PY'
import glob
import json
import os
import re


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


claude_text = read_text("CLAUDE.md")
reasons = []

# --- (a) version drift: CLAUDE.md footer vs .claude/mtk-version.json -------
version_status = "skipped"
footer_match = re.search(r"mtk-setup:\s*v([0-9][0-9.]*)", claude_text)
version_file = ".claude/mtk-version.json"
if os.path.isfile(version_file):
    installed = ""
    try:
        installed = json.load(open(version_file, encoding="utf-8")).get("version", "")
    except (OSError, ValueError):
        installed = ""
    if footer_match and installed:
        stamped = footer_match.group(1)
        if stamped != installed:
            version_status = "stale"
            reasons.append(f"CLAUDE.md footer stamped v{stamped}, installed v{installed}")
        else:
            version_status = "fresh"
    else:
        reasons.append("CLAUDE.md has no mtk-setup footer stamp (version check skipped)")
else:
    reasons.append("no .claude/mtk-version.json (version check skipped)")

# --- (b) dependency rescan --------------------------------------------------
current_deps = set()
manifest_found = False

if os.path.isfile("package.json"):
    manifest_found = True
    try:
        data = json.load(open("package.json", encoding="utf-8"))
        for key in ("dependencies", "devDependencies"):
            current_deps.update((data.get(key) or {}).keys())
    except (OSError, ValueError):
        pass

csproj_files = []
for dirpath, dirnames, filenames in os.walk("."):
    dirnames[:] = [d for d in dirnames if d not in ("bin", "obj", "node_modules", ".git", ".venv")]
    if dirpath.count(os.sep) > 4:
        dirnames[:] = []
        continue
    csproj_files.extend(os.path.join(dirpath, fn) for fn in filenames if fn.endswith(".csproj"))

if csproj_files:
    manifest_found = True
    pkgref_re = re.compile(r'<PackageReference[^>]*Include="([^"]+)"')
    for cf in csproj_files:
        current_deps.update(pkgref_re.findall(read_text(cf)))

if os.path.isfile("pyproject.toml"):
    manifest_found = True
    text = read_text("pyproject.toml")
    m = re.search(r"dependencies\s*=\s*\[(.*?)\]", text, re.S)
    if m:
        for entry in re.findall("[\"']([^\"']+)[\"']", m.group(1)):
            name = re.split(r"[<>=!~\[;\s]", entry)[0].strip()
            if name:
                current_deps.add(name)

dep_status = "skipped"
if not manifest_found:
    reasons.append("no dependency manifest found (package.json/*.csproj/pyproject.toml)")
else:
    docs = ["CLAUDE.md"] + sorted(glob.glob(".claude/rules/*.md"))
    text_all = "\n".join(read_text(d) for d in docs)
    # Word-boundary-equivalent: backtick delimiters force a whole-token match,
    # so a short dependency name can never match as a substring of prose.
    candidates = set(re.findall(r"`([A-Za-z][A-Za-z0-9]*(?:[.-][A-Za-z0-9]+)+)`", text_all))
    bad_ext = (
        ".md", ".sh", ".py", ".json", ".cs", ".csproj", ".sln", ".ts", ".tsx",
        ".js", ".jsx", ".yml", ".yaml", ".toml", ".txt", ".lock", ".cfg",
        ".ini", ".env", ".sha256", ".index",
    )

    def is_known_artifact(tok):
        # Names that collide with an MTK-owned kebab-case artifact (skill,
        # script, rule, toolset, dotfile) are never dependency names.
        candidates_paths = (
            os.path.join(".claude", "skills", tok),
            os.path.join("scripts", tok + ".sh"),
            os.path.join("scripts", tok + ".py"),
            os.path.join(".claude", "rules", tok + ".md"),
            os.path.join(".claude", "toolsets", tok + ".yaml"),
            os.path.join(".claude", tok),
        )
        return any(os.path.exists(p) for p in candidates_paths)

    stale_deps = sorted(
        c for c in candidates
        if not c.lower().endswith(bad_ext)
        and c not in current_deps
        and not is_known_artifact(c)
    )
    if stale_deps:
        dep_status = "stale"
        reasons.append(
            "documented dependency name(s) no longer in manifest: " + ", ".join(stale_deps[:5])
        )
    else:
        dep_status = "fresh"

if version_status == "stale" or dep_status == "stale":
    status = "stale"
elif version_status == "skipped" and dep_status == "skipped":
    status = "unknown"
else:
    status = "fresh"
    if not reasons:
        reasons.append("footer version matches installed; no removed-dependency mentions found")

print(status)
print("; ".join(reasons) if reasons else "fresh")
PY
)"
  status="${parsed%%$'\n'*}"
  reason="${parsed#*$'\n'}"
  add_row "$doc" "$status" "$reason"
}

check_claude_md

# --- Row 4: .claude/detected-tools.json (7-day TTL) -------------------------
DETECTED_TOOLS=".claude/detected-tools.json"
if [ ! -f "$DETECTED_TOOLS" ]; then
  add_row "$DETECTED_TOOLS" "missing" "file not found"
elif find "$DETECTED_TOOLS" -mtime +7 -print -quit 2>/dev/null | grep -q .; then
  add_row "$DETECTED_TOOLS" "stale" "not regenerated in over 7 days"
else
  add_row "$DETECTED_TOOLS" "fresh" "regenerated within the last 7 days"
fi

# --- Row 5: AGENTS.md (regenerate to temp file, diff) -----------------------
AGENTS_FILE="AGENTS.md"
GEN_AGENTS="$SCRIPT_DIR/generate-agents-md.sh"
# Same marker substring generate-agents-md.sh checks (and embeds) for
# AGENTS.md; checked here directly so the regenerator is never invoked
# against a hand-curated file.
AGENTS_MARKER="Auto-generated by MTK"
if [ ! -f "$AGENTS_FILE" ] || [ ! -f "$GEN_AGENTS" ]; then
  add_row "$AGENTS_FILE" "unknown" "AGENTS.md or generate-agents-md.sh not found"
elif ! head -10 "$AGENTS_FILE" | grep -qF "$AGENTS_MARKER"; then
  add_row "$AGENTS_FILE" "unknown" "hand-curated (no auto-generated marker) — not compared"
else
  # Seed the temp target with the real file before regenerating into it:
  # generate-agents-md.sh harvests `## Custom:` sections from its OUTPUT
  # path, so regenerating into an empty temp file would silently drop them
  # and produce a false diff. The copy carries the marker (already verified
  # above), so --force here is defense-in-depth, not what makes the write
  # proceed. TMP_AGENTS lives under TMP_DIR (cleaned up by the EXIT trap),
  # so no fallback file the generator could theoretically produce ever lands
  # in the target repo.
  TMP_AGENTS="$TMP_DIR/AGENTS.generated.md"
  cp "$AGENTS_FILE" "$TMP_AGENTS"
  if bash "$GEN_AGENTS" --force "$TMP_AGENTS" >/dev/null 2>&1 \
      && diff -q "$AGENTS_FILE" "$TMP_AGENTS" >/dev/null 2>&1; then
    add_row "$AGENTS_FILE" "fresh" "matches freshly regenerated content"
  else
    add_row "$AGENTS_FILE" "stale" "regenerated content differs from on-disk AGENTS.md"
  fi
fi

# --- Row 6: path-references (verify-references.sh) --------------------------
VERIFY_REFS="$SCRIPT_DIR/verify-references.sh"
if [ -f "$VERIFY_REFS" ]; then
  vr_rc=0
  vr_out="$(bash "$VERIFY_REFS" CLAUDE.md .claude/rules/*.md 2>/dev/null)" || vr_rc=$?
  case "$vr_rc" in
    0)
      add_row "path-references" "fresh" "no stale references found"
      ;;
    3)
      vr_count="$(printf '%s\n' "$vr_out" | grep -c '^STALE' || true)"
      add_row "path-references" "stale" "$vr_count stale reference(s) found"
      ;;
    *)
      add_row "path-references" "unknown" "verify-references.sh exited unexpectedly (code $vr_rc)"
      ;;
  esac
fi
# else: no row — verify-references.sh absent is the one explicit "skip" case.

# --- Row 7: .claude/setup-answers.json (informational only) ----------------
SETUP_ANSWERS=".claude/setup-answers.json"
if [ -f "$SETUP_ANSWERS" ]; then
  add_row "$SETUP_ANSWERS" "present" "interview answers persisted"
else
  add_row "$SETUP_ANSWERS" "absent" "interview answers not persisted — next bootstrap will offer to capture them"
fi

# --- Render -----------------------------------------------------------------
GENERATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "$FORMAT" = "json" ]; then
  python3 - "$GENERATED" "$SETUP_ANSWERS" "$ROWS_FILE" <<'PY'
import json
import sys

generated = sys.argv[1]
informational = sys.argv[2]
rows_path = sys.argv[3]

artifacts = []
summary = {"fresh": 0, "stale": 0, "missing": 0, "unstamped_unknown": 0}
with open(rows_path, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        artifact, status, reason = line.split("\t", 2)
        artifacts.append({"artifact": artifact, "status": status, "reason": reason})
        if artifact == informational:
            continue
        if status in ("fresh", "stale", "missing"):
            summary[status] += 1
        elif status in ("unstamped", "unknown"):
            summary["unstamped_unknown"] += 1

print(json.dumps({"generated": generated, "artifacts": artifacts, "summary": summary}, indent=2))
PY
else
  w1=8
  w2=6
  w3=6
  while IFS=$'\t' read -r a s r; do
    [ "${#a}" -gt "$w1" ] && w1="${#a}"
    [ "${#s}" -gt "$w2" ] && w2="${#s}"
    [ "${#r}" -gt "$w3" ] && w3="${#r}"
  done < "$ROWS_FILE"

  print_row() { printf '| %-*s | %-*s | %-*s |\n' "$w1" "$1" "$w2" "$2" "$w3" "$3"; }
  print_sep() {
    printf '|%s|%s|%s|\n' \
      "$(printf '%0.s-' $(seq 1 $((w1 + 2))))" \
      "$(printf '%0.s-' $(seq 1 $((w2 + 2))))" \
      "$(printf '%0.s-' $(seq 1 $((w3 + 2))))"
  }

  print_row "ARTIFACT" "STATUS" "REASON"
  print_sep
  while IFS=$'\t' read -r a s r; do
    print_row "$a" "$s" "$r"
  done < "$ROWS_FILE"

  echo
  fresh=0
  stale=0
  missing=0
  unk=0
  while IFS=$'\t' read -r a s r; do
    [ "$a" = "$SETUP_ANSWERS" ] && continue
    case "$s" in
      fresh) fresh=$((fresh + 1)) ;;
      stale) stale=$((stale + 1)) ;;
      missing) missing=$((missing + 1)) ;;
      unstamped|unknown) unk=$((unk + 1)) ;;
    esac
  done < "$ROWS_FILE"
  echo "$fresh fresh, $stale stale, $missing missing, $unk unstamped/unknown"
fi

# --- --check gate -------------------------------------------------------
if [ "$CHECK" -eq 1 ]; then
  fail=0
  while IFS=$'\t' read -r a s _; do
    [ "$a" = "$SETUP_ANSWERS" ] && continue
    case "$s" in
      stale|missing) fail=1 ;;
    esac
  done < "$ROWS_FILE"
  if [ "$fail" -eq 1 ]; then
    echo "run /mtk-setup --refresh to reconcile" >&2
    exit 1
  fi
fi

exit 0
