#!/usr/bin/env bash
# count-tokens.sh — approximate line/token count for a file.
set -euo pipefail

# Contract:
#   count-tokens.sh <file>
#     stdout: "<lines> <tokens>" (tab-separated)
#     exit 0 on success, non-zero if file missing.
# Approximation: tokens ≈ words × 1.3 (good enough for size alarms, not billing).

if [[ $# -ne 1 ]]; then
  echo "usage: count-tokens.sh <file>" >&2
  exit 2
fi

file="$1"
if [[ ! -f "$file" ]]; then
  echo "count-tokens: not found: $file" >&2
  exit 1
fi

lines=$(wc -l < "$file" | tr -d ' ')
words=$(wc -w < "$file" | tr -d ' ')
# Integer math: tokens = words * 13 / 10
tokens=$(( words * 13 / 10 ))
printf "%s\t%s\n" "$lines" "$tokens"
