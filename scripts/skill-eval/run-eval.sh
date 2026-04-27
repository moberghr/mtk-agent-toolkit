#!/usr/bin/env bash
set -euo pipefail

# run-eval.sh — Run eval prompts for a single MTK skill and write graded results.
#
# Usage:
#   bash scripts/skill-eval/run-eval.sh --skill <name> [--prompts <file>] [--out <dir>]
#
# Reads `evals/<skill>/prompts.jsonl` (one JSON object per line) by default.
# For each prompt, invokes a fresh `claude` CLI subprocess in non-interactive
# mode, captures the response, then invokes a grader sub-agent (also via
# `claude`) to score the response against the prompt's `assertion` field.
#
# Writes a per-run JSON file to `evals/results/<skill>/<UTC-timestamp>.json`.
#
# Requirements:
#   - `claude` CLI on PATH (Claude Code's non-interactive mode)
#   - `jq` for JSON manipulation
#   - The skill must exist at `.claude/skills/<skill>/SKILL.md`
#
# Exits 0 on completed run regardless of pass-rate; exits non-zero only on
# infrastructure failure (missing tool, missing skill, malformed JSONL).

usage() {
  cat <<'EOF'
Usage: run-eval.sh --skill <name> [--prompts <file>] [--out <dir>]

Required:
  --skill <name>     Skill directory under .claude/skills/<name>

Optional:
  --prompts <file>   JSONL prompt file (default: evals/<skill>/prompts.jsonl)
  --out <dir>        Output directory (default: evals/results/<skill>)
  --grader <model>   Grader model (default: haiku — fast + cheap)
  --no-grade         Skip the grader pass; output raw responses only
  -h | --help        Show this help

Output:
  evals/results/<skill>/<UTC-timestamp>.json — array of result rows
EOF
}

SKILL=""
PROMPTS=""
OUT_DIR=""
GRADER_MODEL="haiku"
SKIP_GRADE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --skill)    SKILL="$2"; shift 2 ;;
    --prompts)  PROMPTS="$2"; shift 2 ;;
    --out)      OUT_DIR="$2"; shift 2 ;;
    --grader)   GRADER_MODEL="$2"; shift 2 ;;
    --no-grade) SKIP_GRADE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$SKILL" ]; then
  echo "ERROR: --skill is required" >&2
  usage >&2
  exit 2
fi

# Defaults derived from --skill
PROMPTS="${PROMPTS:-evals/${SKILL}/prompts.jsonl}"
OUT_DIR="${OUT_DIR:-evals/results/${SKILL}}"

# Preflight
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found on PATH" >&2; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "ERROR: claude CLI not found on PATH" >&2; exit 1; }

if [ ! -f ".claude/skills/${SKILL}/SKILL.md" ]; then
  echo "ERROR: skill not found at .claude/skills/${SKILL}/SKILL.md" >&2
  exit 1
fi
if [ ! -f "$PROMPTS" ]; then
  echo "ERROR: prompt file not found: $PROMPTS" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="${OUT_DIR}/${TS}.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

GRADER_PROMPT="$(cat scripts/skill-eval/grader-prompt.md)"

# JSON array under construction
echo '[]' > "$OUT_FILE"

LINE_NO=0
while IFS= read -r line || [ -n "$line" ]; do
  LINE_NO=$((LINE_NO + 1))
  # Skip blank / comment lines
  case "$line" in
    ''|'#'*) continue ;;
  esac

  # Validate the line is JSON
  if ! echo "$line" | jq -e . >/dev/null 2>&1; then
    echo "ERROR: ${PROMPTS}:${LINE_NO} is not valid JSON" >&2
    exit 1
  fi

  ID=$(echo "$line" | jq -r '.id // "p"+(env.LINE_NO|tostring)')
  PROMPT=$(echo "$line" | jq -r '.prompt')
  ASSERTION=$(echo "$line" | jq -r '.assertion // ""')
  EXPECTED=$(echo "$line" | jq -r '.expected_grade // "pass"')

  echo ">> [${LINE_NO}] ${ID}" >&2

  RESPONSE_FILE="${TMP_DIR}/${ID}.response.txt"
  START_MS=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || date +%s)

  # Invoke claude non-interactively with the skill loaded.
  # The harness wrapper instructs claude to follow the skill, then process the prompt.
  WRAPPED_PROMPT="Load and follow .claude/skills/${SKILL}/SKILL.md. Apply it to this input:\n\n${PROMPT}"
  if ! echo "$WRAPPED_PROMPT" | claude --print > "$RESPONSE_FILE" 2>/dev/null; then
    # Capture the failure but keep going — record an error entry
    echo "(claude invocation failed)" > "$RESPONSE_FILE"
  fi

  END_MS=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || date +%s)
  LATENCY_MS=$((END_MS - START_MS))

  RESPONSE=$(jq -Rs . < "$RESPONSE_FILE")

  # Grade unless --no-grade
  if [ "$SKIP_GRADE" -eq 1 ] || [ -z "$ASSERTION" ]; then
    GRADE='"ungraded"'
    RATIONALE='""'
  else
    GRADER_INPUT=$(printf '%s\n\n--- ASSERTION ---\n%s\n\n--- RESPONSE ---\n%s\n' \
      "$GRADER_PROMPT" "$ASSERTION" "$(cat "$RESPONSE_FILE")")
    GRADER_OUT="${TMP_DIR}/${ID}.grade.txt"
    if echo "$GRADER_INPUT" | claude --print --model "$GRADER_MODEL" > "$GRADER_OUT" 2>/dev/null; then
      # Grader is instructed to emit a final-line JSON object
      GRADE_LINE=$(grep -E '^\{' "$GRADER_OUT" | tail -1 || echo '{}')
      GRADE=$(echo "$GRADE_LINE" | jq -r '.grade // "error"' | jq -R .)
      RATIONALE=$(echo "$GRADE_LINE" | jq -r '.rationale // ""' | jq -R .)
    else
      GRADE='"error"'
      RATIONALE='"grader invocation failed"'
    fi
  fi

  ROW=$(jq -n \
    --arg id "$ID" \
    --arg prompt "$PROMPT" \
    --argjson response "$RESPONSE" \
    --arg assertion "$ASSERTION" \
    --arg expected "$EXPECTED" \
    --argjson grade "$GRADE" \
    --argjson rationale "$RATIONALE" \
    --argjson latency "$LATENCY_MS" \
    '{id:$id, prompt:$prompt, response:$response, assertion:$assertion,
      expected_grade:$expected, grade:$grade, rationale:$rationale,
      latency_ms:$latency}')

  # Append to result array
  jq --argjson row "$ROW" '. += [$row]' "$OUT_FILE" > "${OUT_FILE}.tmp" && mv "${OUT_FILE}.tmp" "$OUT_FILE"
done < "$PROMPTS"

echo "OK — ${LINE_NO} prompts processed"
echo "    results: ${OUT_FILE}"
