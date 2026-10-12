#!/usr/bin/env bash
set -euo pipefail

# poison-lint.sh — deterministic, no-LLM supply-chain scan of the context-entering
# artifacts MTK SHIPS (skills, agents, plugin hook config) for prompt-injection and
# tool-poisoning patterns. MTK is a skill *publisher*; a poisoned first-party skill,
# or external text laundered into a shipped file by lesson-mining/promote-lesson, is a
# real supply-chain risk. Pattern bank borrowed from the `assay` scanner's poison floor
# (see docs/competitive-analysis-2026-07.md, P0#5).
#
# SCOPE (runtime-loaded, model-visible surface only):
#   .claude/skills/*/SKILL.md   .claude/agents/*.md   hooks/hooks.json
# Deliberately NOT scanned: tests/ and .claude/references/ (they carry injection
# strings as *examples* by design), and scripts/ (this file itself holds the patterns
# as literals). Scanning those would be all false positives.
#
# SEVERITY:
#   FAIL (exit 3) — hard red flags that must be ZERO in a clean first-party toolkit:
#     P-INJECT   instruction-override phrases ("ignore previous instructions", "you are
#                now", "from now on", "new instructions:", "disregard all rules")
#     P-ROLE     injected role/system framing (<system>/<admin> tags, "## SYSTEM",
#                "[[ SYSTEM ]]") in a skill/agent body
#     P-UNICODE  hidden/bidi Unicode (zero-width, RTL/LTR override, Unicode tag chars)
#     P-CRED     credential-path exfiltration directives (read/send ~/.ssh, ~/.aws, …)
#   WARN (exit 0) — advisory, higher false-positive, never fails the build:
#     P-BROAD    over-broad skill description ("any/all/every task", "always use",
#                "for everything", "whenever possible", "unconditionally")
#     P-GRANT    a skill whose description calls itself read-only/analysis yet grants a
#                mutating/egress tool (Bash/Write/Edit/WebFetch) in allowed-tools
#
# Usage:
#   bash scripts/poison-lint.sh            # scan, print findings, exit 3 on any FAIL
#   bash scripts/poison-lint.sh --quiet    # only print findings + summary line
#   bash scripts/poison-lint.sh --warn-only # never exit non-zero (report only)
#
# A single line may opt out of ONE rule with a trailing marker when the pattern is
# genuinely intentional (e.g. a skill that must document an override phrase):
#   ... some line ...   # poison-lint:allow P-INJECT
#
# Exit codes:
#   0 — no FAIL findings (WARN may be present)
#   3 — one or more FAIL findings
#   2 — usage error

QUIET=0
WARN_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1 ;;
    --warn-only) WARN_ONLY=1 ;;
    -h|--help) awk '/^# /{sub(/^# ?/,"");print} !/^#/{exit}' "$0"; exit 0 ;;
    *) echo "poison-lint: unknown flag '$1'" >&2; exit 2 ;;
  esac
  shift
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

fail_count=0
warn_count=0

# Emit a finding. $1=rule $2=severity(FAIL|WARN) $3=file $4=line $5=message
emit() {
  local rule="$1" sev="$2" file="$3" line="$4" msg="$5"
  if [ "$sev" = FAIL ]; then fail_count=$((fail_count+1)); else warn_count=$((warn_count+1)); fi
  printf '%s  %-9s %s:%s  %s\n' "$sev" "$rule" "$file" "$line" "$msg"
}

# True if the given file:line carries an opt-out marker for $rule.
allowed() {
  local file="$1" line="$2" rule="$3"
  sed -n "${line}p" "$file" 2>/dev/null | grep -qF "poison-lint:allow ${rule}"
}

# grep -nE over a file for a pattern, emitting a finding per hit (respecting opt-out).
scan_regex() {
  local rule="$1" sev="$2" pat="$3" msg="$4"; shift 4
  local file
  for file in "$@"; do
    [ -f "$file" ] || continue
    while IFS=: read -r ln _; do
      [ -n "$ln" ] || continue
      allowed "$file" "$ln" "$rule" && continue
      emit "$rule" "$sev" "$file" "$ln" "$msg"
    done < <(grep -niE "$pat" "$file" 2>/dev/null || true)
  done
}

# Collect the runtime-loaded surface.
# NOTE: `mapfile` is a bash 4+ builtin and macOS ships bash 3.2, where it silently
# failed the whole lint (S3.3 requires the toolkit to run on a stock macOS box).
# read-loop append is the portable equivalent.
collect_into() {
  # collect_into <array-name> <find-args...>
  local _arr="$1"; shift
  local _line
  eval "$_arr=()"
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    eval "$_arr+=(\"\$_line\")"
  done < <(find "$@" -type f 2>/dev/null | sort || true)
}

collect_into SKILLS .claude/skills -name SKILL.md
collect_into AGENTS .claude/agents -name '*.md'
# Rule files became a runtime-loaded surface when hooks/rule-trigger.sh started
# injecting them into context on a matched tool call. Before that they were only
# read when the model chose to; now they arrive unprompted, which puts them in the
# same trust tier as skills and agents. Scan them.
collect_into RULES .claude/rules -name '*.md'
HOOKCFG=()
[ -f hooks/hooks.json ] && HOOKCFG=(hooks/hooks.json)
# `${A[@]+"${A[@]}"}` keeps an empty array from tripping `set -u` on bash 3.2.
BODY_FILES=(
  ${SKILLS[@]+"${SKILLS[@]}"}
  ${AGENTS[@]+"${AGENTS[@]}"}
  ${RULES[@]+"${RULES[@]}"}
  ${HOOKCFG[@]+"${HOOKCFG[@]}"}
)

# --- P-INJECT: instruction-override phrases -------------------------------------
scan_regex P-INJECT FAIL \
  '(ignore|disregard|forget|override|bypass)[[:space:]]+(all[[:space:]]+)?(the[[:space:]]+)?(previous|prior|above|earlier|preceding|all)[[:space:]]+(instructions|prompts|rules|context|guidance)|you[[:space:]]+are[[:space:]]+now[[:space:]]+|from[[:space:]]+now[[:space:]]+on[,:]|new[[:space:]]+instructions[[:space:]]*:|do[[:space:]]+not[[:space:]]+follow[[:space:]]+(the[[:space:]]+)?(previous|prior|system)' \
  'instruction-override phrase in a shipped context artifact' \
  "${BODY_FILES[@]}"

# --- P-ROLE: injected role / system framing -------------------------------------
scan_regex P-ROLE FAIL \
  '<(system|admin|assistant|user)>|^[[:space:]]*(#{1,6}[[:space:]]*|\[\[[[:space:]]*)(SYSTEM|ADMIN)[[:space:]]*(\]\])?[[:space:]]*$|\bSYSTEM[[:space:]]+OVERRIDE\b' \
  'injected role/system framing in a shipped context artifact' \
  "${BODY_FILES[@]}"

# --- P-CRED: credential-path exfiltration directives ----------------------------
# FAIL on either (a) an egress verb near ANY credential/secret path, or (b) any
# access verb near a HIGH-sensitivity path (private keys, ~/.ssh, ~/.aws). Merely
# *reading* a .env in stack guidance is normal and is not flagged — only sending it,
# or touching a private key, is. This keeps tool-permission listings like
# `Read(**/.env.production)` (a deny recommendation) out of the FAIL set.
scan_regex P-CRED FAIL \
  '(send|upload|post|exfiltrate|reveal|curl|wget|base64|scp)[^\n]{0,40}(~/\.ssh|~/\.aws|~/\.gnupg|~/\.kube|~/\.docker|\.config/gcloud|id_rsa|\.pem\b|credentials|\.env\b)|(read|cat|open|access|load|print|dump)[^\n]{0,40}(~/\.ssh|~/\.aws|~/\.gnupg|~/\.kube|id_rsa|\.pem\b)' \
  'credential-path exfiltration directive in a shipped context artifact' \
  "${BODY_FILES[@]}"

# --- P-UNICODE: hidden / bidi Unicode (byte-level, locale-independent) ----------
# Zero-width: U+200B/C/D (E2 80 8B/8C/8D), U+2060 (E2 81 A0), U+FEFF (EF BB BF).
# Bidi override: U+202D/E (E2 80 AD/AE). Unicode tag chars: U+E00xx (F3 A0 80-81 ..).
for f in "${BODY_FILES[@]}"; do
  [ -f "$f" ] || continue
  while IFS=: read -r ln _; do
    [ -n "$ln" ] || continue
    allowed "$f" "$ln" P-UNICODE && continue
    emit P-UNICODE FAIL "$f" "$ln" 'hidden or bidirectional Unicode control character'
  done < <(LC_ALL=C grep -naE $'\xe2\x80\x8b|\xe2\x80\x8c|\xe2\x80\x8d|\xe2\x81\xa0|\xef\xbb\xbf|\xe2\x80\xad|\xe2\x80\xae|\xf3\xa0[\x80\x81]' "$f" 2>/dev/null | cut -d: -f1 || true)
done

# --- P-BROAD (WARN): over-broad skill descriptions ------------------------------
# Only the `description:` frontmatter line of each skill.
for f in "${SKILLS[@]}"; do
  [ -f "$f" ] || continue
  desc_ln=$(grep -niE '^description:' "$f" | head -1 | cut -d: -f1 || true)
  [ -n "${desc_ln:-}" ] || continue
  allowed "$f" "$desc_ln" P-BROAD && continue
  if sed -n "${desc_ln}p" "$f" | grep -qiE '\balways[[:space:]]+(use|activate|apply|run)\b|\bfor[[:space:]]+everything\b|\bwhenever[[:space:]]+possible\b|\bunconditionally\b|\bon[[:space:]]+every[[:space:]]+(prompt|task|request|message|turn)\b|\bany[[:space:]]+and[[:space:]]+all\b'; then
    emit P-BROAD WARN "$f" "$desc_ln" 'over-broad auto-activation language in skill description'
  fi
done

# --- P-GRANT (WARN): read-only-claiming skill granting a mutating/egress tool ---
for f in "${SKILLS[@]}"; do
  [ -f "$f" ] || continue
  fm="$(awk 'NR==1&&$0!="---"{exit} /^---[[:space:]]*$/{c++; if(c==2)exit; next} c==1{print}' "$f")"
  desc="$(printf '%s\n' "$fm" | awk -F: '/^description:/{sub(/^[^:]*:[[:space:]]*/,"");print;exit}')"
  allowed_tools="$(printf '%s\n' "$fm" | awk -F: '/^allowed-tools:/{sub(/^[^:]*:[[:space:]]*/,"");print;exit}')"
  [ -n "$allowed_tools" ] || continue
  if printf '%s' "$desc" | grep -qiE 'read-only|read only' \
     && printf '%s' "$allowed_tools" | grep -qiE '\b(Bash|Write|Edit|MultiEdit|NotebookEdit|WebFetch|WebSearch)\b'; then
    ln=$(grep -niE '^allowed-tools:' "$f" | head -1 | cut -d: -f1 || echo 1)
    emit P-GRANT WARN "$f" "$ln" 'skill describes itself as read-only/analysis yet grants a mutating or egress tool'
  fi
done

# --- Summary --------------------------------------------------------------------
total_scanned=$(( ${#BODY_FILES[@]} ))
if [ "$QUIET" -eq 0 ] || [ "$fail_count" -gt 0 ] || [ "$warn_count" -gt 0 ]; then
  printf 'poison-lint: scanned %d artifacts — %d FAIL, %d WARN\n' "$total_scanned" "$fail_count" "$warn_count"
fi

if [ "$WARN_ONLY" -eq 1 ]; then exit 0; fi
[ "$fail_count" -eq 0 ] || exit 3
exit 0
