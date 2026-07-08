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
# Note: agents pin aliases (model: opus|sonnet|haiku), not version IDs. On the
# Anthropic API an alias resolves to the latest in its family (opus -> Opus 4.8).
# On Bedrock/Vertex/Foundry the same alias may resolve to an OLDER version; pin
# ANTHROPIC_DEFAULT_OPUS_MODEL / _SONNET_MODEL / _HAIKU_MODEL to a full ID there.
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
  record PASS components "no deprecated model IDs" "checked ${#DEPRECATED_MODELS[@]} known-deprecated IDs; aliases resolve to latest on Anthropic API — pin ANTHROPIC_DEFAULT_*_MODEL on Bedrock/Vertex"
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

# Release checksum manifest (optional) — installed bytes match the release.
if [ -f checksums.sha256 ] && [ -f scripts/generate-checksums.sh ]; then
  CHECKSUM_LINE="$(bash scripts/generate-checksums.sh --verify --quiet 2>/dev/null | grep '^checksums:' | tail -1 || true)"
  if printf '%s' "$CHECKSUM_LINE" | grep -q ' 0 mismatched, 0 missing'; then
    record PASS integrity "release checksums verified" "$CHECKSUM_LINE"
  else
    record WARN integrity "release checksum drift" "${CHECKSUM_LINE:-verification failed} — expected with local changes; on a clean install this means the bytes are not the released bytes"
  fi
else
  record PASS integrity "release checksum manifest absent" "generate at release: bash scripts/generate-checksums.sh"
fi

# Release signature (optional, advisory knob) — proves WHO published, not just that
# bytes are unmodified. Absence of the whole feature is never a hard FAIL (opt-in
# supply-chain hardening), but once a public key IS configured, a missing .sig is a
# WARN (a stripped signature must not silently downgrade to "not configured"), and
# tool problems (no openssl, LibreSSL without Ed25519 support, unreadable key) are
# reported as "uncheckable" — only a genuine verify failure is a tamper FAIL.
if [ -n "${MTK_RELEASE_PUBLIC_KEY:-}" ] || [ -f checksums.sha256.sig ]; then
  if [ -z "${MTK_RELEASE_PUBLIC_KEY:-}" ]; then
    record PASS integrity "release signing not configured" "checksums.sha256.sig present — set MTK_RELEASE_PUBLIC_KEY to verify it"
  elif [ ! -f checksums.sha256.sig ]; then
    record WARN integrity "release signature missing" "MTK_RELEASE_PUBLIC_KEY is set but checksums.sha256.sig is absent — unsigned release or stripped signature"
  elif [ ! -f checksums.sha256 ]; then
    record WARN integrity "release signature uncheckable" "checksums.sha256.sig present but checksums.sha256 is missing"
  elif [ ! -r "$MTK_RELEASE_PUBLIC_KEY" ]; then
    record WARN integrity "release signature uncheckable" "MTK_RELEASE_PUBLIC_KEY does not point at a readable file: $MTK_RELEASE_PUBLIC_KEY"
  elif ! command -v openssl >/dev/null 2>&1; then
    record WARN integrity "release signature uncheckable" "checksums.sha256.sig present but openssl not found"
  elif ! openssl pkeyutl -help 2>&1 | grep -q -- '-rawin'; then
    record WARN integrity "release signature uncheckable" "openssl lacks pkeyutl -rawin (stock macOS LibreSSL) — install OpenSSL 3+ to verify Ed25519 signatures"
  elif openssl pkeyutl -verify -pubin -inkey "$MTK_RELEASE_PUBLIC_KEY" -rawin -in checksums.sha256 -sigfile checksums.sha256.sig >/dev/null 2>&1; then
    record PASS integrity "release signature verified" "checksums.sha256 signed by MTK_RELEASE_PUBLIC_KEY"
  else
    record FAIL integrity "release signature invalid" "checksums.sha256.sig does not verify against MTK_RELEASE_PUBLIC_KEY — bytes may be tampered or key mismatched"
  fi
else
  record PASS integrity "release signing not configured" "set MTK_RELEASE_PUBLIC_KEY and ship checksums.sha256.sig to enable"
fi

# Run validate-toolkit as one composite check
if bash scripts/validate-toolkit.sh >/dev/null 2>&1; then
  record PASS integrity "validate-toolkit passes"
else
  record FAIL integrity "validate-toolkit fails" "run: bash scripts/validate-toolkit.sh"
fi

# ──────────────────────────────────────────────
# LESSONS
# ──────────────────────────────────────────────
# Executable lesson-contract well-formedness (v7.25). Optional feature — a lesson
# with no contract fields is fine, and malformed contracts are WARN (never FAIL),
# so the check never blocks a repo that doesn't use contracts. See
# .claude/references/learnings-schema.md → Executable lesson contract.
LEARN_FILE=".mtk/learnings.jsonl"
if [ -f "$LEARN_FILE" ] && command -v python3 >/dev/null 2>&1; then
  LINT_OUT="$(python3 - "$LEARN_FILE" <<'PY'
import json, sys
checked = 0
issues = []
with open(sys.argv[1]) as f:
    for n, line in enumerate(f, 1):
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            issues.append("line %d: unparseable JSON in learnings store (corrupt entry)" % n)
            continue
        if not any(k in e for k in ("confidence", "output_contract",
                                    "prefinal_verification_checklist", "source_evidence_refs")):
            continue
        checked += 1
        lid = e.get("id", "line%d" % n)
        c = e.get("confidence")
        if c is not None and c not in ("low", "medium", "high"):
            issues.append("%s: confidence '%s' not in low|medium|high" % (lid, c))
        if "output_contract" in e and not isinstance(e["output_contract"], dict):
            issues.append("%s: output_contract is not an object" % lid)
        cl = e.get("prefinal_verification_checklist")
        if cl is not None:
            if not isinstance(cl, list):
                issues.append("%s: prefinal_verification_checklist is not an array" % lid)
            else:
                for i, item in enumerate(cl):
                    if not isinstance(item, dict) or "check_id" not in item:
                        issues.append("%s: checklist[%d] missing check_id" % (lid, i))
                    elif "blocking" in item and not isinstance(item["blocking"], bool):
                        issues.append("%s: checklist[%d].blocking must be true/false" % (lid, i))
        if "source_evidence_refs" in e and not isinstance(e["source_evidence_refs"], list):
            issues.append("%s: source_evidence_refs is not an array" % lid)
print(checked)
for it in issues:
    print("ISSUE " + it)
PY
)"
  CONTRACT_COUNT="$(printf '%s\n' "$LINT_OUT" | sed -n '1p')"
  MALFORMED="$(printf '%s\n' "$LINT_OUT" | grep -c '^ISSUE ' || true)"
  if [ "${MALFORMED:-0}" != "0" ]; then
    # Surface every issue (malformed contract field OR unparseable store line),
    # even when there are zero valid contracts — a corrupt store must not read green.
    while IFS= read -r il; do
      case "$il" in "ISSUE "*) record WARN lessons "lesson store issue" "${il#ISSUE }" ;; esac
    done < <(printf '%s\n' "$LINT_OUT")
  elif [ "${CONTRACT_COUNT:-0}" = "0" ]; then
    record PASS lessons "no executable lesson contracts to lint"
  else
    record PASS lessons "lesson contracts well-formed" "${CONTRACT_COUNT} contract(s)"
  fi
else
  record PASS lessons "no local learnings store" ".mtk/learnings.jsonl absent — nothing to lint"
fi

# ──────────────────────────────────────────────
# CONTEXT
# ──────────────────────────────────────────────
# Always-on context cost: what loads into every session before the first prompt
# (CLAUDE.md + the rules wake-up layer + alwaysApply references + MCP tool schemas).
# Report-only — surfaces the baseline so teams can keep it lean. These checks must
# stay PASS on a clean repo (pressure-test S1); the numbers live in the detail string.
ctx_lines=0
ctx_bytes=0
add_ctx_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  local l b
  l="$(wc -l < "$f" | tr -d '[:space:]')"
  b="$(wc -c < "$f" | tr -d '[:space:]')"
  ctx_lines=$((ctx_lines + l))
  ctx_bytes=$((ctx_bytes + b))
}

add_ctx_file "CLAUDE.md"
add_ctx_file ".claude/rules/INDEX.md"

# alwaysApply=true references — the only refs that load unconditionally. Read the
# generated TSV index (tab-separated: path, alwaysApply, description, globs).
ALWAYSON_REFS=0
if [ -f ".claude/references.index" ]; then
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if [ -f "$ref" ]; then
      add_ctx_file "$ref"
      ALWAYSON_REFS=$((ALWAYSON_REFS + 1))
    fi
  done < <(awk -F'\t' '/^#/{next} $2=="true"{print $1}' .claude/references.index)
fi

if [ "$ctx_bytes" -gt 0 ]; then
  # ~13 tokens/line proxy, consistent with the context-engineering skill.
  ctx_tokens=$((ctx_lines * 13))
  record PASS context "always-on context baseline" \
    "~${ctx_tokens} tokens (${ctx_lines} lines / ${ctx_bytes} bytes): CLAUDE.md + rules/INDEX.md + ${ALWAYSON_REFS} alwaysApply ref(s)"
else
  record PASS context "always-on context baseline" \
    "no always-on files found (CLAUDE.md / rules/INDEX.md absent — likely the source repo)"
fi

# MCP schema overhead — every connected server loads its full tool schema at
# session start (~10-20k tokens each). Count servers declared in this repo's
# .mcp.json (no jq per S3.3; each server entry carries a "type" key).
if [ -f ".mcp.json" ]; then
  MCP_COUNT="$(grep -c '"type"' .mcp.json 2>/dev/null || printf '0')"
  record PASS context "MCP schema baseline" \
    "${MCP_COUNT} server(s) in .mcp.json — each adds ~10-20k tokens of tool schema per session"
else
  record PASS context "MCP schema baseline" "no .mcp.json — no MCP schema baseline"
fi

# Tool-search deferral — defers MCP tool schemas until first use instead of
# loading them all upfront. Advisory either way (never WARN — it is opt-in).
if grep -q 'ENABLE_TOOL_SEARCH' .claude/settings.json 2>/dev/null; then
  record PASS context "tool-search deferral enabled" \
    "ENABLE_TOOL_SEARCH set — MCP tool schemas load on demand"
else
  record PASS context "tool-search deferral not set" \
    "ENABLE_TOOL_SEARCH unset — consider enabling if you connect many MCP servers (defers schema loading)"
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
