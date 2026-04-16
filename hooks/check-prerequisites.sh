#!/usr/bin/env bash
set -euo pipefail

# check-prerequisites.sh — Check for recommended development tools.
# Called by setup-bootstrap after tech stack detection.
# Reports missing tools as warnings, never blocks.
#
# Usage:
#   bash hooks/check-prerequisites.sh [stack]
#   stack: dotnet | python | typescript (reads .claude/tech-stack if omitted)

STACK="${1:-}"
if [ -z "$STACK" ] && [ -f .claude/tech-stack ]; then
  STACK="$(tr -d '[:space:]' < .claude/tech-stack)"
fi

missing=()
recommended=()
warn_count=0

# ─── Check a tool and record result ────────────────────────────────────────────

check_tool() {
  local name="$1" purpose="$2" install_hint="${3:-}"
  if command -v "$name" &>/dev/null; then
    return 0
  fi
  missing+=("$name")
  local msg="  ⚠  $name — $purpose"
  [ -n "$install_hint" ] && msg="$msg ($install_hint)"
  recommended+=("$msg")
  warn_count=$((warn_count + 1))
}

# ─── Core tools (all stacks) ──────────────────────────────────────────────────

check_tool "shellcheck" \
  "validates hook and script quality" \
  "brew install shellcheck"

check_tool "shfmt" \
  "formats shell scripts consistently" \
  "brew install shfmt"

check_tool "jq" \
  "parses JSON in hooks and scripts" \
  "brew install jq"

# ─── Stack-specific tools ─────────────────────────────────────────────────────

case "${STACK:-}" in
  dotnet)
    check_tool "dotnet" \
      "required for build and test" \
      "https://dot.net/download"
    check_tool "dotnet-format" \
      "code formatting" \
      "dotnet tool install -g dotnet-format"
    ;;
  python)
    check_tool "python3" \
      "required for build and test" \
      "brew install python3"
    check_tool "ruff" \
      "fast Python linter and formatter" \
      "pip install ruff"
    check_tool "mypy" \
      "static type checking" \
      "pip install mypy"
    check_tool "pytest" \
      "test runner" \
      "pip install pytest"
    ;;
  typescript)
    check_tool "node" \
      "required for build and test" \
      "brew install node"
    # Check for the active package manager
    if [ -f .claude/tech-stack-pm ]; then
      PM="$(tr -d '[:space:]' < .claude/tech-stack-pm)"
      check_tool "$PM" \
        "active package manager for this repo" \
        "npm install -g $PM"
    fi
    ;;
esac

# ─── Report ────────────────────────────────────────────────────────────────────

if [ "$warn_count" -eq 0 ]; then
  echo "Prerequisites: all recommended tools found."
else
  echo ""
  echo "Prerequisites: ${warn_count} recommended tool(s) not found:"
  printf '%s\n' "${recommended[@]}"
  echo ""
  echo "These are optional but improve hook and linter quality."
  echo "Install them when convenient — MTK works without them."
fi
