#!/usr/bin/env bash
# repo-health-score.sh — Score a repo against 12 named AI-readiness assets
# (bounded checklist + medal).
#
# Output: markdown by default, JSON with --json.
# Assets, rubric, and medal thresholds live in
# .claude/references/repo-health-assets.md.
#
# Each asset returns one of: pass / partial / fail / na.
# Medal is computed against the count of `pass` over (12 - na).

set -euo pipefail

OUTPUT_FORMAT="markdown"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) OUTPUT_FORMAT="json"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "WARN: unknown arg: $1" >&2; shift ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

# Each call records a result: name | bucket | status | note
RESULTS=()

record() {
  RESULTS+=("$1|$2|$3|$4")
}

# --- AI Context bucket (4 assets) -------------------------------------------

# 1. CLAUDE.md present and non-empty
if [[ -s CLAUDE.md ]]; then
  record "1. CLAUDE.md present" "AI Context" "pass" "$(wc -l < CLAUDE.md | tr -d ' ') lines"
elif [[ -f CLAUDE.md ]]; then
  record "1. CLAUDE.md present" "AI Context" "partial" "file exists but is empty"
else
  record "1. CLAUDE.md present" "AI Context" "fail" "missing"
fi

# 2. architecture-principles.md exists with >=5 tagged principles
if [[ -f .claude/references/architecture-principles.md ]]; then
  TAG_COUNT=$(grep -cE '\[(EXTRACTED|INFERRED:[0-9.]+|AMBIGUOUS|MINED:[a-z]+)\]' .claude/references/architecture-principles.md 2>/dev/null || echo 0)
  TAG_COUNT=$(echo "$TAG_COUNT" | tr -d ' ')
  if [[ "$TAG_COUNT" -ge 5 ]]; then
    record "2. Architecture principles tagged" "AI Context" "pass" "$TAG_COUNT tagged principles"
  elif [[ "$TAG_COUNT" -ge 1 ]]; then
    record "2. Architecture principles tagged" "AI Context" "partial" "only $TAG_COUNT tagged principles"
  else
    record "2. Architecture principles tagged" "AI Context" "fail" "no tagged principles"
  fi
else
  record "2. Architecture principles tagged" "AI Context" "fail" "file missing — run /mtk-setup --audit"
fi

# 3. Tech stack resolves and matches a known tech-stack-* skill.
# Scored on whether the stack RESOLVES, not on whether the root file exists: a
# polyglot repo may legitimately pin per-subtree (`<subtree>/.claude/tech-stack`)
# or by glob (`.claude/tech-stack.map`) with no root scalar at all, and the old
# root-file-only test scored that correct setup as "missing".
_RTS="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/resolve-tech-stack.sh"
[[ -f "$_RTS" ]] || _RTS="${CLAUDE_PLUGIN_ROOT:-.}/scripts/resolve-tech-stack.sh"
STACK=""
STACK_SRC="root .claude/tech-stack"
if [[ -f "$_RTS" ]]; then
  STACK=$(bash "$_RTS" "$PWD" 2>/dev/null || true)
  STACK_SRC=$(bash "$_RTS" --explain "$PWD" 2>&1 >/dev/null | sed 's/.*(via //; s/)$//' || true)
elif [[ -f .claude/tech-stack ]]; then
  STACK=$(head -1 .claude/tech-stack | tr -d '[:space:]')
fi

if [[ -n "$STACK" ]] && [[ -d ".claude/skills/tech-stack-$STACK" ]]; then
  record "3. Tech stack pinned" "AI Context" "pass" "stack=$STACK (via ${STACK_SRC:-unknown})"
elif [[ -n "$STACK" ]]; then
  record "3. Tech stack pinned" "AI Context" "partial" "stack=$STACK (no matching skill)"
elif [[ -d .claude/skills ]]; then
  # Treat as n/a only when no .claude/skills directory at all (non-MTK repo).
  record "3. Tech stack pinned" "AI Context" "fail" "no stack resolves (root, subproject, or tech-stack.map)"
else
  record "3. Tech stack pinned" "AI Context" "na" "non-MTK repo"
fi

# 4. tasks/lessons.md exists with >=1 entry (## heading)
if [[ -f tasks/lessons.md ]]; then
  LESSON_COUNT=$(grep -c '^## ' tasks/lessons.md 2>/dev/null || echo 0)
  LESSON_COUNT=$(echo "$LESSON_COUNT" | tr -d ' ')
  if [[ "$LESSON_COUNT" -ge 1 ]]; then
    record "4. Lessons captured" "AI Context" "pass" "$LESSON_COUNT lesson(s)"
  else
    record "4. Lessons captured" "AI Context" "partial" "file exists but no '## ' entries"
  fi
else
  record "4. Lessons captured" "AI Context" "fail" "tasks/lessons.md missing"
fi

# --- Dev Workflow bucket (4 assets) -----------------------------------------

# Helper: count files under a dir modified within the last 90 days
recent_count() {
  local dir="$1"
  [[ -d "$dir" ]] || { echo 0; return; }
  find "$dir" -maxdepth 2 -name '*.md' -type f -mtime -90 2>/dev/null | wc -l | tr -d ' '
}

# 5. docs/specs/ with >=1 spec in last 90 days.
# Scored against the RESOLVED artifact root: a repo whose subtree owns its specs
# was previously scored "docs/specs/ missing" while holding dozens of them.
_RAR="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)/resolve-artifact-root.sh"
[[ -f "$_RAR" ]] || _RAR="${CLAUDE_PLUGIN_ROOT:-.}/scripts/resolve-artifact-root.sh"
if [[ -f "$_RAR" ]]; then
  SPEC_DIR="$(bash "$_RAR" "$PWD" 2>/dev/null || printf '.')/docs/specs"
else
  SPEC_DIR="docs/specs"
fi
if [[ -d "$SPEC_DIR" ]]; then
  RECENT=$(recent_count "$SPEC_DIR")
  TOTAL=$(find "$SPEC_DIR" -maxdepth 2 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$RECENT" -ge 1 ]]; then
    record "5. Recent specs" "Dev Workflow" "pass" "$RECENT recent (of $TOTAL total)"
  elif [[ "$TOTAL" -ge 1 ]]; then
    record "5. Recent specs" "Dev Workflow" "partial" "no specs in last 90 days ($TOTAL older)"
  else
    record "5. Recent specs" "Dev Workflow" "fail" "docs/specs/ empty"
  fi
else
  record "5. Recent specs" "Dev Workflow" "fail" "docs/specs/ missing"
fi

# 6. docs/plans/ with >=1 plan in last 90 days
if [[ -d docs/plans ]]; then
  RECENT=$(recent_count docs/plans)
  TOTAL=$(find docs/plans -maxdepth 2 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$RECENT" -ge 1 ]]; then
    record "6. Recent plans" "Dev Workflow" "pass" "$RECENT recent (of $TOTAL total)"
  elif [[ "$TOTAL" -ge 1 ]]; then
    record "6. Recent plans" "Dev Workflow" "partial" "no plans in last 90 days ($TOTAL older)"
  else
    record "6. Recent plans" "Dev Workflow" "fail" "docs/plans/ empty"
  fi
else
  record "6. Recent plans" "Dev Workflow" "fail" "docs/plans/ missing"
fi

# 7. manifest.json and plugin.json versions match (when both present)
MANIFEST=.claude/manifest.json
PLUGIN=.claude-plugin/plugin.json
if [[ -f "$MANIFEST" ]] && [[ -f "$PLUGIN" ]]; then
  MV=$(python3 -c "import json; print(json.load(open('$MANIFEST'))['version'])" 2>/dev/null || echo "?")
  PV=$(python3 -c "import json; print(json.load(open('$PLUGIN'))['version'])" 2>/dev/null || echo "?")
  if [[ "$MV" == "$PV" ]] && [[ "$MV" != "?" ]]; then
    record "7. Manifest versions in sync" "Dev Workflow" "pass" "v$MV"
  else
    record "7. Manifest versions in sync" "Dev Workflow" "fail" "manifest=$MV plugin=$PV"
  fi
else
  record "7. Manifest versions in sync" "Dev Workflow" "na" "no manifest/plugin files"
fi

# 8. validate-toolkit.sh exits 0 (MTK repos only)
if [[ -x scripts/validate-toolkit.sh ]]; then
  if bash scripts/validate-toolkit.sh >/dev/null 2>&1; then
    record "8. Toolkit validator passes" "Dev Workflow" "pass" "validate-toolkit.sh OK"
  else
    record "8. Toolkit validator passes" "Dev Workflow" "fail" "validate-toolkit.sh failed"
  fi
elif [[ -f scripts/validate-toolkit.sh ]]; then
  record "8. Toolkit validator passes" "Dev Workflow" "partial" "exists but not executable"
else
  record "8. Toolkit validator passes" "Dev Workflow" "na" "non-MTK repo"
fi

# --- Onboarding bucket (4 assets) -------------------------------------------

# 9. README.md exists and is non-empty
if [[ -s README.md ]]; then
  record "9. README present" "Onboarding" "pass" "$(wc -l < README.md | tr -d ' ') lines"
elif [[ -f README.md ]]; then
  record "9. README present" "Onboarding" "partial" "exists but empty"
else
  record "9. README present" "Onboarding" "fail" "missing"
fi

# 10. Build & test commands documented somewhere accessible
HAS_COMMANDS=0
DOC_FOUND=""
for f in CLAUDE.md README.md .claude/skills/tech-stack-*/SKILL.md; do
  [[ -f "$f" ]] || continue
  if grep -qE '(dotnet build|dotnet test|npm test|npm run build|pytest|cargo test|cargo build|go test|go build|bash scripts/[a-zA-Z-]+\.sh)' "$f"; then
    HAS_COMMANDS=1
    DOC_FOUND="$f"
    break
  fi
done
if [[ "$HAS_COMMANDS" -eq 1 ]]; then
  record "10. Build/test commands documented" "Onboarding" "pass" "found in $DOC_FOUND"
else
  record "10. Build/test commands documented" "Onboarding" "fail" "no build/test commands in CLAUDE.md/README/tech-stack"
fi

# 11. .claude/rules/ with >=2 rule files
if [[ -d .claude/rules ]]; then
  RULE_COUNT=$(find .claude/rules -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$RULE_COUNT" -ge 2 ]]; then
    record "11. Rules documented" "Onboarding" "pass" "$RULE_COUNT rule file(s)"
  elif [[ "$RULE_COUNT" -ge 1 ]]; then
    record "11. Rules documented" "Onboarding" "partial" "only $RULE_COUNT rule file"
  else
    record "11. Rules documented" "Onboarding" "fail" ".claude/rules/ empty"
  fi
else
  record "11. Rules documented" "Onboarding" "na" "no .claude/rules dir"
fi

# 12. .gitignore excludes .claude/settings.local.json (and analytics.json if present)
if [[ -f .gitignore ]]; then
  GITIGNORE_OK=1
  MISS=""
  if ! grep -qE '(^|/)\.claude/settings\.local\.json' .gitignore; then
    GITIGNORE_OK=0
    MISS="settings.local.json"
  fi
  if [[ -f .claude/analytics.json ]] && ! grep -qE '(^|/)\.claude/analytics\.json' .gitignore; then
    GITIGNORE_OK=0
    MISS="${MISS:+$MISS, }analytics.json"
  fi
  if [[ "$GITIGNORE_OK" -eq 1 ]]; then
    record "12. Sensitive files gitignored" "Onboarding" "pass" "settings.local + analytics covered"
  else
    record "12. Sensitive files gitignored" "Onboarding" "fail" "missing: $MISS"
  fi
else
  record "12. Sensitive files gitignored" "Onboarding" "fail" ".gitignore missing"
fi

# --- Scoring -----------------------------------------------------------------

PASS=0; PARTIAL=0; FAIL=0; NA=0
for r in "${RESULTS[@]}"; do
  STATUS="${r#*|}"; STATUS="${STATUS#*|}"; STATUS="${STATUS%%|*}"
  case "$STATUS" in
    pass) PASS=$((PASS+1)) ;;
    partial) PARTIAL=$((PARTIAL+1)) ;;
    fail) FAIL=$((FAIL+1)) ;;
    na) NA=$((NA+1)) ;;
  esac
done

DENOM=$((12 - NA))
if [[ "$PASS" -ge 10 ]]; then MEDAL="🏆 platinum"
elif [[ "$PASS" -ge 8 ]]; then MEDAL="🥇 gold"
elif [[ "$PASS" -ge 6 ]]; then MEDAL="🥈 silver"
elif [[ "$PASS" -ge 4 ]]; then MEDAL="🥉 bronze"
else MEDAL="(no medal)"
fi

icon_for() {
  case "$1" in
    pass) echo "🟩" ;;
    partial) echo "🟨" ;;
    fail) echo "⬜" ;;
    na) echo "·" ;;
  esac
}

# --- Render ------------------------------------------------------------------

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  python3 - "$PASS" "$PARTIAL" "$FAIL" "$NA" "$DENOM" "$MEDAL" "${RESULTS[@]}" <<'PYEND'
import json, sys
pass_n, part_n, fail_n, na_n, denom, medal, *rows = sys.argv[1:]
assets = []
for r in rows:
    name, bucket, status, note = r.split("|", 3)
    assets.append({"name": name, "bucket": bucket, "status": status, "note": note})
print(json.dumps({
    "medal": medal,
    "pass": int(pass_n),
    "partial": int(part_n),
    "fail": int(fail_n),
    "na": int(na_n),
    "denominator": int(denom),
    "assets": assets,
}, indent=2))
PYEND
  exit 0
fi

echo "## Repo health scorecard"
echo ""
echo "**Medal:** $MEDAL — $PASS pass / $PARTIAL partial / $FAIL fail (of $DENOM scoring assets; $NA n/a)"
echo ""

LAST_BUCKET=""
for r in "${RESULTS[@]}"; do
  NAME="${r%%|*}"
  REST="${r#*|}"
  BUCKET="${REST%%|*}"
  REST="${REST#*|}"
  STATUS="${REST%%|*}"
  NOTE="${REST#*|}"
  if [[ "$BUCKET" != "$LAST_BUCKET" ]]; then
    echo ""
    echo "### $BUCKET"
    echo ""
    LAST_BUCKET="$BUCKET"
  fi
  ICON=$(icon_for "$STATUS")
  echo "- $ICON **$NAME** — $NOTE"
done

echo ""
echo "_Legend: 🟩 pass · 🟨 partial · ⬜ fail · · n/a_"
