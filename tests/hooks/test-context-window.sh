#!/usr/bin/env bash
set -euo pipefail

# context-budget.sh sizes its thresholds from the model's real context window,
# with the mapping scripts/mtk-doctor.sh uses (Claude Code model-config docs):
# Fable 5.x, Opus 4.7+, Sonnet 5+ and Haiku 5.5 are 1M by default; Opus/Sonnet
# 4.6 only as their [1m] variant; Haiku 4.5 and Opus/Sonnet 4.5 are 200k;
# CLAUDE_CODE_DISABLE_1M_CONTEXT=1 forces 200k; an unknown model is assumed 1M.
# A fixed 1M default left 200k sessions silent far past their budget.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/context-budget.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git -C "$WORK" init -q
printf 'x\n' > "$WORK/f.md"

# 600000 read bytes ≈ 150k tokens: past 60% of 200k (120k), well under 60% of 1M.
# The hook inherits the caller's env; clear the knobs a developer may have set.
unset MTK_CONTEXT_WINDOW_TOKENS CLAUDE_CODE_DISABLE_1M_CONTEXT CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
run_case() { # $1 = case dir name, $2 = ANTHROPIC_MODEL ('' = unset), $3 = transcript model ('' = none)
  local dir="$WORK/$1" sf transcript=""
  mkdir -p "$dir"
  sf="$(TMPDIR="$dir" CLAUDE_PROJECT_DIR="$WORK" bash -c 'source "'"$REPO_ROOT"'/hooks/lib/hook-io.sh"; f="$(mtk_session_file)"; mtk_init_session_state "$f"; printf "%s" "$f"')"
  sed -i.bak 's/^bytes_read=.*/bytes_read=600000/' "$sf" && rm -f "$sf.bak"
  if [ -n "$3" ]; then
    transcript="$dir/t.jsonl"
    printf '{"type":"assistant","message":{"role":"assistant","model":"%s","content":[]}}\n' "$3" > "$transcript"
  fi
  local payload
  payload="$(printf '{"tool_name":"Read","tool_input":{"file_path":"%s"},"transcript_path":"%s"}' "$WORK/f.md" "$transcript")"
  if [ -n "$2" ]; then
    printf '%s' "$payload" | TMPDIR="$dir" CLAUDE_PROJECT_DIR="$WORK" ANTHROPIC_MODEL="$2" bash "$HOOK" 2>/dev/null || true
  else
    printf '%s' "$payload" | env -u ANTHROPIC_MODEL TMPDIR="$dir" CLAUDE_PROJECT_DIR="$WORK" bash "$HOOK" 2>/dev/null || true
  fi
}

fires() { case "$1" in *'200000-token window'*) return 0 ;; esac; return 1; }
quiet() { case "$1" in *'CONTEXT BUDGET: estimated'*) return 1 ;; esac; return 0; }

out="$(run_case unknown '' '')";               quiet "$out" || fail "unknown model must assume 1M. Got: $out"
out="$(run_case opus55 '' 'claude-opus-5-5')";  quiet "$out" || fail "Opus 5.5 is 1M by default. Got: $out"
out="$(run_case haiku55 'claude-haiku-5-5' '')"; quiet "$out" || fail "Haiku 5.5 is 1M by default. Got: $out"
out="$(run_case fable 'fable' '')";            quiet "$out" || fail "fable alias is 1M. Got: $out"
printf '  PASS  current models and unknown ids get the 1M window\n'

out="$(run_case haiku45 '' 'claude-haiku-4-5')"; fires "$out" || fail "Haiku 4.5 (from the transcript) is 200k. Got: $out"
out="$(run_case sonnet45 'claude-sonnet-4-5' '')"; fires "$out" || fail "Sonnet 4.5 is 200k. Got: $out"
out="$(run_case opus46 'claude-opus-4-6' '')";   fires "$out" || fail "Opus 4.6 without [1m] is 200k. Got: $out"
out="$(run_case opus46-1m 'claude-opus-4-6[1m]' '')"; quiet "$out" || fail "Opus 4.6[1m] is 1M. Got: $out"
printf '  PASS  4.5 models and 4.6 without [1m] get 200k\n'

out="$(CLAUDE_CODE_DISABLE_1M_CONTEXT=1 run_case disabled 'claude-opus-5-5' '')"
fires "$out" || fail "CLAUDE_CODE_DISABLE_1M_CONTEXT=1 must force 200k. Got: $out"
printf '  PASS  CLAUDE_CODE_DISABLE_1M_CONTEXT=1 forces 200k\n'

out="$(MTK_CONTEXT_WINDOW_TOKENS=1000000 run_case override '' 'claude-haiku-4-5')"
quiet "$out" || fail "MTK_CONTEXT_WINDOW_TOKENS must override the model-derived window. Got: $out"
printf '  PASS  MTK_CONTEXT_WINDOW_TOKENS still wins\n'

printf '\nAll context-window checks passed.\n'
