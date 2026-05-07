#!/usr/bin/env bash
# mtk doctor — health check across MTK installation.
# Reports PASS/WARN/FAIL across categories. Exits 0 unless --strict and any WARN/FAIL,
# or any FAIL otherwise.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# Args
JSON=0
FIX=0
STRICT=0
for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    --fix) FIX=1 ;;
    --strict) STRICT=1 ;;
    -h|--help)
      cat <<USAGE
Usage: mtk-doctor [--json] [--fix] [--strict]

  --json    Machine-readable output for CI dashboards
  --fix     Auto-fix safe items (gitignore additions, chmod +x). Never fixes FAILs.
  --strict  Exit non-zero on WARN as well as FAIL
USAGE
      exit 0
      ;;
    *) printf 'Unknown flag: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# Deprecated model IDs — update when Anthropic deprecates more.
DEPRECATED_MODELS=(
  "claude-3-opus"
  "claude-3-sonnet"
  "claude-3-haiku"
  "claude-2"
  "claude-instant"
)

# Result aggregation
RESULTS=()       # tab-separated: status\tcategory\tname\tdetail
PASS=0; WARN=0; FAIL=0

record() {
  local status="$1" cat="$2" name="$3" detail="${4:-}"
  RESULTS+=("$(printf '%s\t%s\t%s\t%s' "$status" "$cat" "$name" "$detail")")
  case "$status" in
    PASS) PASS=$((PASS + 1)) ;;
    WARN) WARN=$((WARN + 1)) ;;
    FAIL) FAIL=$((FAIL + 1)) ;;
  esac
}

# ──────────────────────────────────────────────
# CORE FILES
# ──────────────────────────────────────────────
# Resolve manifest location: target-repo installs no longer ship .claude/manifest.json,
# so fall back to the plugin root if a project-local copy is absent.
if [ -f ".claude/manifest.json" ]; then
  DOCTOR_MANIFEST=".claude/manifest.json"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/.claude/manifest.json" ]; then
  DOCTOR_MANIFEST="${CLAUDE_PLUGIN_ROOT}/.claude/manifest.json"
else
  DOCTOR_MANIFEST=""
fi

for f in .claude-plugin/plugin.json README.md AGENTS.md scripts/validate-toolkit.sh; do
  if [ -f "$f" ]; then
    record PASS core "$f present"
  else
    record FAIL core "$f missing" "required by toolkit baseline"
  fi
done

if [ -n "$DOCTOR_MANIFEST" ]; then
  record PASS core "manifest.json located" "$DOCTOR_MANIFEST"
else
  record FAIL core "manifest.json missing" "set CLAUDE_PLUGIN_ROOT or run from a plugin clone"
fi

# Target-repo provenance file (single source of truth for installed version).
if [ -f ".claude/mtk-version.json" ]; then
  record PASS core ".claude/mtk-version.json present"
fi

# CLAUDE.md may not exist in the source repo (it's a target-repo artifact),
# but if it exists, check the line budget.
if [ -f CLAUDE.md ]; then
  CLAUDE_LINES="$(wc -l < CLAUDE.md | tr -d '[:space:]')"
  if [ "$CLAUDE_LINES" -le 200 ]; then
    record PASS core "CLAUDE.md within 200-line budget" "${CLAUDE_LINES} lines"
  else
    record WARN core "CLAUDE.md exceeds 200-line budget" "${CLAUDE_LINES} lines — consider splitting into .claude/rules/"
  fi
fi

# ──────────────────────────────────────────────
# COMPONENTS
# ──────────────────────────────────────────────
# Manifest version sync
MANIFEST_VERSION=""
if [ -n "$DOCTOR_MANIFEST" ]; then
  MANIFEST_VERSION="$(grep -o '"version": *"[^"]*"' "$DOCTOR_MANIFEST" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')"
fi
PLUGIN_VERSION="$(grep -o '"version": *"[^"]*"' .claude-plugin/plugin.json | head -1 | sed 's/.*"\([^"]*\)".*/\1/')"
if [ "$MANIFEST_VERSION" = "$PLUGIN_VERSION" ] && [ -n "$MANIFEST_VERSION" ]; then
  record PASS components "version sync" "$MANIFEST_VERSION"
else
  record FAIL components "version mismatch" "manifest=${MANIFEST_VERSION:-?} plugin=${PLUGIN_VERSION:-?}"
fi

# Skill count vs disk
SKILL_DIRS=$(find .claude/skills -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')
record PASS components "skills on disk" "${SKILL_DIRS} directories"

# Skill name matches directory (S1.12 / C0.3)
SKILL_NAME_MISMATCHES=()
while IFS= read -r skill_md; do
  dir_name="$(basename "$(dirname "$skill_md")")"
  fm_name="$(grep -m1 '^name:' "$skill_md" 2>/dev/null | sed 's/^name:[[:space:]]*//')"
  if [ -n "$fm_name" ] && [ "$fm_name" != "$dir_name" ]; then
    SKILL_NAME_MISMATCHES+=("$dir_name vs name: $fm_name")
  fi
done < <(find .claude/skills -name SKILL.md -mindepth 2 -maxdepth 3)

if [ "${#SKILL_NAME_MISMATCHES[@]}" -eq 0 ]; then
  record PASS components "skill name/dir match" "all skills consistent"
else
  for m in "${SKILL_NAME_MISMATCHES[@]}"; do
    record FAIL components "skill name mismatch" "$m"
  done
fi

# Deprecated models in agent frontmatter
DEPRECATED_HITS=()
while IFS= read -r agent_md; do
  for model in "${DEPRECATED_MODELS[@]}"; do
    if grep -q "^model: *${model}" "$agent_md" 2>/dev/null; then
      DEPRECATED_HITS+=("$agent_md → $model")
    fi
  done
done < <(find .claude/agents -name '*.md' -type f 2>/dev/null)

if [ "${#DEPRECATED_HITS[@]}" -eq 0 ]; then
  record PASS components "no deprecated model IDs" "checked ${#DEPRECATED_MODELS[@]} known-deprecated IDs"
else
  for h in "${DEPRECATED_HITS[@]}"; do
    record FAIL components "deprecated model" "$h"
  done
fi

# ──────────────────────────────────────────────
# HOOKS
# ──────────────────────────────────────────────
# All registered hook scripts in .claude/settings.json must exist and be executable.
KNOWN_EVENTS="SessionStart PreToolUse PostToolUse PreCompact PostCompact UserPromptSubmit Stop SessionEnd Notification InstructionsLoaded SubagentStart SubagentStop TaskCompleted"

while IFS= read -r line; do
  cmd="$(printf '%s' "$line" | sed 's/^.*"command": *"//; s/".*$//')"
  # Strip $ARGUMENTS and similar suffixes
  script="$(printf '%s' "$cmd" | awk '{print $1}')"
  [ -z "$script" ] && continue
  case "$script" in /*) ;; *) script="$ROOT_DIR/$script" ;; esac
  if [ ! -f "$script" ]; then
    record FAIL hooks "registered hook missing" "$cmd"
  elif [ ! -x "$script" ]; then
    if [ "$FIX" -eq 1 ]; then
      chmod +x "$script" && record PASS hooks "hook fixed (chmod +x)" "$cmd"
    else
      record WARN hooks "hook not executable" "$cmd — run with --fix"
    fi
  fi
done < <(grep -E '"command": *"hooks/' .claude/settings.json 2>/dev/null || true)

# Check that hook event names are valid
while IFS= read -r event; do
  if ! printf ' %s ' "$KNOWN_EVENTS" | grep -q " $event "; then
    record WARN hooks "unknown hook event" "$event"
  fi
done < <(grep -oE '"(SessionStart|PreToolUse|PostToolUse|PreCompact|PostCompact|UserPromptSubmit|Stop|SessionEnd|Notification|InstructionsLoaded|SubagentStart|SubagentStop|TaskCompleted|[A-Z][a-zA-Z]+)":' .claude/settings.json 2>/dev/null \
        | sed 's/[":]//g' | sort -u)

record PASS hooks "settings.json hook block validated"

# All shell scripts in hooks/ must have set -euo pipefail (S3.1)
PIPEFAIL_MISSING=()
while IFS= read -r sh; do
  if ! head -15 "$sh" | grep -q 'set -euo pipefail'; then
    PIPEFAIL_MISSING+=("$sh")
  fi
done < <(find hooks/ -type f -name '*.sh' 2>/dev/null)

if [ "${#PIPEFAIL_MISSING[@]}" -eq 0 ]; then
  record PASS hooks "all hooks use 'set -euo pipefail'"
else
  for s in "${PIPEFAIL_MISSING[@]}"; do
    record FAIL hooks "missing pipefail" "$s — violates S3.1"
  done
fi

# ──────────────────────────────────────────────
# INTEGRITY
# ──────────────────────────────────────────────
# Manifest paths exist on disk (sample check — full check is in validate-toolkit.sh)
MISSING_PATHS=()
while IFS= read -r src; do
  [ -e "$src" ] || MISSING_PATHS+=("$src")
done < <(grep -oE '"source": *"[^"]+"' "${DOCTOR_MANIFEST:-/dev/null}" | sed 's/.*"\([^"]*\)".*/\1/' | sort -u | head -50)

if [ "${#MISSING_PATHS[@]}" -eq 0 ]; then
  record PASS integrity "manifest paths present (sample of 50)"
else
  for p in "${MISSING_PATHS[@]}"; do
    record FAIL integrity "manifest path missing" "$p"
  done
fi

# .gitignore coverage
GITIGNORE_MISSING=()
GITIGNORE_REQUIRED=(
  ".claude/settings.local.json"
  ".claude/observability/"
)
for entry in "${GITIGNORE_REQUIRED[@]}"; do
  if ! grep -qF "$entry" .gitignore 2>/dev/null; then
    GITIGNORE_MISSING+=("$entry")
  fi
done

if [ "${#GITIGNORE_MISSING[@]}" -eq 0 ]; then
  record PASS integrity ".gitignore covers expected paths"
else
  for g in "${GITIGNORE_MISSING[@]}"; do
    if [ "$FIX" -eq 1 ]; then
      printf '%s\n' "$g" >> .gitignore
      record PASS integrity ".gitignore fixed" "added $g"
    else
      record WARN integrity ".gitignore missing entry" "$g — run with --fix"
    fi
  done
fi

# Analytics freshness
if [ -f .claude/analytics.json ]; then
  if find .claude/analytics.json -mtime +30 -print -quit 2>/dev/null | grep -q .; then
    record WARN integrity "analytics.json stale" "older than 30 days — toolkit may be unused"
  else
    record PASS integrity "analytics.json fresh"
  fi
else
  record PASS integrity "analytics.json absent" "first session will create"
fi

# Run validate-toolkit as one composite check
if bash scripts/validate-toolkit.sh >/dev/null 2>&1; then
  record PASS integrity "validate-toolkit passes"
else
  record FAIL integrity "validate-toolkit fails" "run: bash scripts/validate-toolkit.sh"
fi

# ──────────────────────────────────────────────
# OUTPUT
# ──────────────────────────────────────────────
if [ "$JSON" -eq 1 ]; then
  printf '{"summary":{"pass":%d,"warn":%d,"fail":%d},"checks":[' "$PASS" "$WARN" "$FAIL"
  first=1
  for line in "${RESULTS[@]}"; do
    status="$(printf '%s' "$line" | cut -f1)"
    cat="$(printf '%s' "$line" | cut -f2)"
    name="$(printf '%s' "$line" | cut -f3)"
    detail="$(printf '%s' "$line" | cut -f4)"
    [ "$first" -eq 0 ] && printf ','
    first=0
    # Escape quotes/backslashes for JSON
    name_esc="${name//\\/\\\\}"; name_esc="${name_esc//\"/\\\"}"
    detail_esc="${detail//\\/\\\\}"; detail_esc="${detail_esc//\"/\\\"}"
    printf '{"status":"%s","category":"%s","name":"%s","detail":"%s"}' \
      "$status" "$cat" "$name_esc" "$detail_esc"
  done
  printf ']}\n'
else
  current_cat=""
  for line in "${RESULTS[@]}"; do
    status="$(printf '%s' "$line" | cut -f1)"
    cat="$(printf '%s' "$line" | cut -f2)"
    name="$(printf '%s' "$line" | cut -f3)"
    detail="$(printf '%s' "$line" | cut -f4)"
    if [ "$cat" != "$current_cat" ]; then
      printf '\n%s\n' "$(printf '%s' "$cat" | tr '[:lower:]' '[:upper:]')"
      current_cat="$cat"
    fi
    case "$status" in
      PASS) sym='✓' ;;
      WARN) sym='⚠' ;;
      FAIL) sym='✗' ;;
    esac
    if [ -n "$detail" ]; then
      printf '  %s %s — %s\n' "$sym" "$name" "$detail"
    else
      printf '  %s %s\n' "$sym" "$name"
    fi
  done
  printf '\nSummary: %d PASS, %d WARN, %d FAIL\n' "$PASS" "$WARN" "$FAIL"
fi

# Exit code
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
if [ "$STRICT" -eq 1 ] && [ "$WARN" -gt 0 ]; then
  exit 1
fi
exit 0
