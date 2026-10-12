#!/usr/bin/env bash
set -euo pipefail

# aggregate.sh — Run N iterations of run-eval and report pass-rate + variance.
#
# Usage:
#   bash scripts/skill-eval/aggregate.sh --skill <name> [--iterations N]
#                                         [--prompts <file>]
#
# Output:
#   evals/results/<skill>/aggregate-<UTC-timestamp>.json
#   stdout summary table

usage() {
  cat <<'EOF'
Usage: aggregate.sh --skill <name> [--iterations N] [--prompts <file>]

Required:
  --skill <name>      Skill directory under .claude/skills/<name>

Optional:
  --iterations N      Number of repeated runs (default: 3)
  --prompts <file>    JSONL prompts (default: evals/<skill>/prompts.jsonl)

Reports per-prompt pass-rate and standard deviation across iterations.
EOF
}

SKILL=""
ITERATIONS=3
PROMPTS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --skill)      SKILL="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --prompts)    PROMPTS="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$SKILL" ]; then
  echo "ERROR: --skill is required" >&2
  usage >&2
  exit 2
fi

PROMPTS="${PROMPTS:-evals/${SKILL}/prompts.jsonl}"
OUT_DIR="evals/results/${SKILL}"
mkdir -p "$OUT_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
AGG_FILE="${OUT_DIR}/aggregate-${TS}.json"

echo ">> Running $ITERATIONS iterations for skill: $SKILL"
RUN_FILES=()
for i in $(seq 1 "$ITERATIONS"); do
  echo ">> Iteration $i/$ITERATIONS"
  bash scripts/skill-eval/run-eval.sh --skill "$SKILL" --prompts "$PROMPTS"
  # Pick the latest result file by mtime
  LATEST=$(ls -t "$OUT_DIR"/2*.json 2>/dev/null | head -1)
  RUN_FILES+=("$LATEST")
done

# Aggregate per-prompt pass-rate across runs
# Build: { id => [grades...] }
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# Concat all runs into one stream of {id, grade}
jq -s '[.[][] | {id: .id, grade: .grade}]' "${RUN_FILES[@]}" > "$TMP"

# Compute per-prompt counts
SUMMARY=$(jq '
  group_by(.id)
  | map({
      id: .[0].id,
      runs: length,
      passes: map(select(.grade == "pass")) | length,
      fails:  map(select(.grade == "fail")) | length,
      partial:map(select(.grade == "partial")) | length,
      errors: map(select(.grade == "error" or .grade == "ungraded")) | length
    })
  | map(. + {pass_rate: (if .runs == 0 then 0 else (.passes / .runs) end)})
' "$TMP")

# Overall pass-rate (mean of per-prompt rates)
OVERALL=$(echo "$SUMMARY" | jq '
  if length == 0 then 0
  else (map(.pass_rate) | add / length) end')

# Std dev of per-prompt pass-rates (population std dev)
STDDEV=$(echo "$SUMMARY" | jq --argjson mean "$OVERALL" '
  if length == 0 then 0
  else
    (map(.pass_rate - $mean | . * .) | add / length | sqrt)
  end')

jq -n \
  --arg skill "$SKILL" \
  --argjson iterations "$ITERATIONS" \
  --argjson overall_pass_rate "$OVERALL" \
  --argjson std_dev "$STDDEV" \
  --argjson per_prompt "$SUMMARY" \
  '{skill:$skill, iterations:$iterations,
    overall_pass_rate:$overall_pass_rate, std_dev:$std_dev,
    per_prompt:$per_prompt}' > "$AGG_FILE"

# Pretty stdout summary
printf '\n=== Skill eval summary: %s ===\n' "$SKILL"
printf 'Iterations: %s\n' "$ITERATIONS"
printf 'Overall pass-rate: %.1f%% (σ=%.2f)\n' \
  "$(echo "$OVERALL * 100" | bc -l)" \
  "$STDDEV" 2>/dev/null || \
  printf 'Overall pass-rate: %s (stddev: %s)\n' "$OVERALL" "$STDDEV"
printf '\nPer-prompt:\n'
echo "$SUMMARY" | jq -r '.[] | "  \(.id): \((.pass_rate * 100) | floor)%   (passes:\(.passes) fails:\(.fails) partial:\(.partial) errors:\(.errors))"'
printf '\nFull report: %s\n' "$AGG_FILE"
