#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: scripts/run-evals.sh [options]

Options:
  --skill <name>         Run evals for one skill (dir name under evals/)
  --eval <path>          Run a single eval file
  --list                 List all evals, grouped by skill (default if no args)
  --run-id <string>      Override the timestamp used for the results directory
  -h, --help             Show this help

Environment:
  EVAL_EXECUTOR          If set, a command that receives the prompt on stdin
                         and returns the agent output on stdout. Leave unset
                         for manual execution.
  EVAL_GRADER            If set, a command that receives the grader payload
                         on stdin and returns a verdict (PASS / FAIL /
                         PARTIAL) plus rationale. Leave unset for manual
                         grading.

Without EVAL_EXECUTOR / EVAL_GRADER the runner is read-only: it prints each
scenario's setup and prompt so an engineer, or a separate claude session,
can execute explicitly. This avoids surprise API spend.
EOF
}

MODE="list"
SKILL=""
EVAL_FILE=""
RUN_ID="$(date +%Y-%m-%d-%H%M%S)"

while [ $# -gt 0 ]; do
  case "$1" in
    --skill)    MODE="skill"; SKILL="${2:-}"; shift 2 ;;
    --eval)     MODE="scenario";  EVAL_FILE="${2:-}"; shift 2 ;;
    --list)     MODE="list"; shift ;;
    --run-id)   RUN_ID="${2:-}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          printf 'Unknown arg: %s\n' "$1" >&2; usage; exit 1 ;;
  esac
done

RESULTS_DIR="evals/results/${RUN_ID}"

list_scenarios() {
  local filter_skill="${1:-}"
  local found=0
  for skill_dir in evals/*/; do
    [ -d "$skill_dir" ] || continue
    local name
    name="$(basename "$skill_dir")"
    [ "$name" = "results" ] && continue
    [ -n "$filter_skill" ] && [ "$name" != "$filter_skill" ] && continue
    printf '\n== %s ==\n' "$name"
    for scenario_file in "$skill_dir"eval-*.md; do
      [ -f "$scenario_file" ] || continue
      local title category
      title="$(grep -m1 '^# ' "$scenario_file" | sed 's/^# *//')"
      category="$(grep -m1 '^category:' "$scenario_file" | sed 's/^category: *//')"
      printf '  [%s] %s\n      %s\n' "${category:-?}" "$scenario_file" "${title:-<no title>}"
      found=1
    done
  done
  [ "$found" = 1 ] || printf '(no evals found)\n'
}

run_scenario() {
  local scenario_path="$1"
  [ -f "$scenario_path" ] || { printf 'ERROR: eval not found: %s\n' "$scenario_path" >&2; return 1; }
  local skill scenario_name
  skill="$(basename "$(dirname "$scenario_path")")"
  scenario_name="$(basename "$scenario_path" .md)"
  local result_dir="$RESULTS_DIR/$skill"
  mkdir -p "$result_dir"

  printf '\n--- RUN %s/%s ---\n' "$skill" "$scenario_name"

  if [ -z "${EVAL_EXECUTOR:-}" ]; then
    printf 'Manual mode. Read the eval file and run the prompt yourself.\n'
    printf 'File: %s\n' "$scenario_path"
    printf 'Record the output in: %s/%s.output.md\n' "$result_dir" "$scenario_name"
    printf 'Then grade with: %s/grader.md (see file for prompt)\n' "evals/$skill"
    printf 'Record the verdict in: %s/%s.verdict.md\n' "$result_dir" "$scenario_name"
    return 0
  fi

  # Automated path — extract prompt block and invoke executor.
  local prompt_file="$result_dir/$scenario_name.prompt.txt"
  awk '/^```prompt$/{flag=1; next} /^```$/{flag=0} flag' "$scenario_path" > "$prompt_file"
  if [ ! -s "$prompt_file" ]; then
    printf 'ERROR: scenario has no prompt block: %s\n' "$scenario_path" >&2
    return 1
  fi

  local out_file="$result_dir/$scenario_name.output.md"
  "$EVAL_EXECUTOR" < "$prompt_file" > "$out_file"

  if [ -n "${EVAL_GRADER:-}" ] && [ -f "evals/$skill/grader.md" ]; then
    local grade_input="$result_dir/$scenario_name.grade.input"
    {
      cat "evals/$skill/grader.md"
      printf '\n---\nEVAL FILE:\n'
      cat "$scenario_path"
      printf '\n---\nACTUAL OUTPUT:\n'
      cat "$out_file"
    } > "$grade_input"
    "$EVAL_GRADER" < "$grade_input" > "$result_dir/$scenario_name.verdict.md"
  fi

  printf 'Done. Output: %s\n' "$out_file"
}

case "$MODE" in
  list)
    list_scenarios
    printf '\nRun one skill:      bash %s --skill <name>\n' "$0"
    printf 'Run one scenario:   bash %s --eval <path>\n' "$0"
    printf 'Automate via env:   EVAL_EXECUTOR=... EVAL_GRADER=... %s --skill <name>\n' "$0"
    ;;
  skill)
    [ -n "$SKILL" ] || { printf 'ERROR: --skill requires a name\n' >&2; exit 1; }
    [ -d "evals/$SKILL" ] || { printf 'ERROR: no such skill: %s\n' "$SKILL" >&2; exit 1; }
    for scenario_file in "evals/$SKILL"/eval-*.md; do
      [ -f "$scenario_file" ] || continue
      run_scenario "$scenario_file"
    done
    ;;
  scenario)
    [ -n "$EVAL_FILE" ] || { printf 'ERROR: --eval requires a path\n' >&2; exit 1; }
    run_scenario "$EVAL_FILE"
    ;;
esac
