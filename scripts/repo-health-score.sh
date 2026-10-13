#!/usr/bin/env bash
# repo-health-score.sh — Check a repo against 9 named AI-readiness assets.
#
# Output: markdown by default, JSON with --json.
# Assets and rubric live in .claude/references/repo-health-assets.md.
#
# Each asset returns one of: pass / partial / fail / na. There is no aggregate
# score; the output lists the assets that need action. Assets 5 and 6 are `na`
# outside the toolkit checkout.

set -euo pipefail

OUTPUT_FORMAT="markdown"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) OUTPUT_FORMAT="json"; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
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

# 1. Instructions file present and non-empty. Which file is the constitution is
# resolved by scripts/resolve-constitution.sh (AGENTS.md when it exists, is not
# generator-marked, and CLAUDE.md is absent/the same file/a shim). The resolver
# answers "which file", not "is there one", so an answer that does not exist on
# disk becomes the empty string — this asset scores `fail` for that repo.
_RC="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/resolve-constitution.sh"
[[ -f "$_RC" ]] || _RC="${CLAUDE_PLUGIN_ROOT:-.}/scripts/resolve-constitution.sh"
INSTR_FILE=""
if [[ -f "$_RC" ]]; then
  INSTR_FILE="$(bash "$_RC" 2>/dev/null || true)"
elif [[ -f AGENTS.md ]]; then
  INSTR_FILE="AGENTS.md"
elif [[ -f CLAUDE.md ]]; then
  INSTR_FILE="CLAUDE.md"
fi
[[ -n "$INSTR_FILE" ]] && [[ -f "$INSTR_FILE" ]] || INSTR_FILE=""

if [[ -n "$INSTR_FILE" ]] && [[ -s "$INSTR_FILE" ]]; then
  record "1. Instructions file present" "AI Context" "pass" "$(wc -l < "$INSTR_FILE" | tr -d ' ') lines"
elif [[ -n "$INSTR_FILE" ]]; then
  record "1. Instructions file present" "AI Context" "partial" "file exists but is empty"
else
  record "1. Instructions file present" "AI Context" "fail" "missing"
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

# --- Toolkit bucket (MTK repo only) -----------------------------------------
# Assets 5 and 6 describe the toolkit's own release hygiene. Outside the toolkit
# checkout they are `na` and carry no weight: a target repo has no manifest or
# validator to keep in sync.
MANIFEST=.claude/manifest.json
PLUGIN=.claude-plugin/plugin.json
if [[ -f "$MANIFEST" ]] && [[ -f "$PLUGIN" ]] && [[ -f scripts/validate-toolkit.sh ]]; then
  IN_TOOLKIT=1
else
  IN_TOOLKIT=0
fi

# 5. manifest.json, plugin.json and the marketplace entry carry one version (C0.1)
if [[ "$IN_TOOLKIT" -eq 1 ]]; then
  MV=$(python3 -c "import json,sys; sys.stdout.reconfigure(newline='\n'); print(json.load(open('$MANIFEST'))['version'])" 2>/dev/null || echo "?")
  PV=$(python3 -c "import json,sys; sys.stdout.reconfigure(newline='\n'); print(json.load(open('$PLUGIN'))['version'])" 2>/dev/null || echo "?")
  MKT=.claude-plugin/marketplace.json
  KV="$MV"
  if [[ -f "$MKT" ]]; then
    KV=$(python3 -c "import json,sys; sys.stdout.reconfigure(newline='\n'); d=json.load(open('$MKT')); print(next((p.get('version','?') for p in d.get('plugins',[]) if p.get('name')=='mtk'), '?'))" 2>/dev/null || echo "?")
  fi
  if [[ "$MV" == "$PV" ]] && [[ "$MV" == "$KV" ]] && [[ "$MV" != "?" ]]; then
    record "5. Manifest versions in sync" "Toolkit" "pass" "v$MV"
  else
    record "5. Manifest versions in sync" "Toolkit" "fail" "manifest=$MV plugin=$PV marketplace=$KV"
  fi
else
  record "5. Manifest versions in sync" "Toolkit" "na" "outside the toolkit"
fi

# 6. validate-toolkit.sh exits 0
if [[ "$IN_TOOLKIT" -eq 0 ]]; then
  record "6. Toolkit validator passes" "Toolkit" "na" "outside the toolkit"
elif bash scripts/validate-toolkit.sh >/dev/null 2>&1; then
  record "6. Toolkit validator passes" "Toolkit" "pass" "validate-toolkit.sh OK"
else
  record "6. Toolkit validator passes" "Toolkit" "fail" "validate-toolkit.sh failed — run it for the failing check"
fi

# --- Onboarding bucket (3 assets) -------------------------------------------

# 7. README.md exists and is non-empty
if [[ -s README.md ]]; then
  record "7. README present" "Onboarding" "pass" "$(wc -l < README.md | tr -d ' ') lines"
elif [[ -f README.md ]]; then
  record "7. README present" "Onboarding" "partial" "exists but empty"
else
  record "7. README present" "Onboarding" "fail" "missing"
fi

# 8. Build & test commands documented somewhere accessible
HAS_COMMANDS=0
DOC_FOUND=""
# The resolved constitution first: post-inversion that is AGENTS.md, and a
# CLAUDE.md-only search scored every inverted repo "fail".
for f in ${INSTR_FILE:+"$INSTR_FILE"} AGENTS.md CLAUDE.md README.md .claude/skills/tech-stack-*/SKILL.md; do
  [[ -f "$f" ]] || continue
  if grep -qE '(dotnet build|dotnet test|npm test|npm run build|pytest|cargo test|cargo build|go test|go build|bash scripts/[a-zA-Z-]+\.sh)' "$f"; then
    HAS_COMMANDS=1
    DOC_FOUND="$f"
    break
  fi
done
if [[ "$HAS_COMMANDS" -eq 1 ]]; then
  record "8. Build/test commands documented" "Onboarding" "pass" "found in $DOC_FOUND"
else
  record "8. Build/test commands documented" "Onboarding" "fail" "no build/test commands in AGENTS.md/CLAUDE.md/README/tech-stack"
fi

# 9. .gitignore excludes .claude/settings.local.json (and analytics.json if present)
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
    record "9. Sensitive files gitignored" "Onboarding" "pass" "settings.local + analytics covered"
  else
    record "9. Sensitive files gitignored" "Onboarding" "fail" "missing: $MISS"
  fi
else
  record "9. Sensitive files gitignored" "Onboarding" "fail" ".gitignore missing"
fi

# --- Action list -------------------------------------------------------------
# No medal and no pass count: an aggregate rewarded MTK paperwork over fixing the
# one asset that matters. The output is the per-asset table plus the list of
# assets that need action (partial or fail).
ACTION=()
for r in "${RESULTS[@]}"; do
  STATUS="${r#*|}"; STATUS="${STATUS#*|}"; STATUS="${STATUS%%|*}"
  case "$STATUS" in
    partial|fail) ACTION+=("${r%%|*}") ;;
  esac
done

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
  python3 - "${#ACTION[@]}" "${ACTION[@]+"${ACTION[@]}"}" "${RESULTS[@]}" <<'PYEND'
import json, sys
n_action = int(sys.argv[1])
action, rows = sys.argv[2:2 + n_action], sys.argv[2 + n_action:]
assets = []
for r in rows:
    name, bucket, status, note = r.split("|", 3)
    assets.append({"name": name, "bucket": bucket, "status": status, "note": note})
print(json.dumps({"assets": assets, "action_needed": action}, indent=2))
PYEND
  exit 0
fi

echo "## Repo health scorecard"
echo ""
if [[ "${#ACTION[@]}" -eq 0 ]]; then
  echo "**Needs action:** none"
else
  echo "**Needs action:** $(IFS=';'; printf '%s' "${ACTION[*]}" | sed 's/;/, /g')"
fi
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
  # Status word alongside the icon (not icon-only): a machine reader greeping
  # the markdown for "<asset name>.*pass" needs the literal word on the same
  # line, which the icon alone never provides.
  echo "- $ICON **$NAME** ($STATUS) — $NOTE"
done

echo ""
echo "_Legend: 🟩 pass · 🟨 partial · ⬜ fail · · n/a_"
