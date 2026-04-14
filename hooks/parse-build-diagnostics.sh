#!/usr/bin/env bash
#
# Parse build tool diagnostics (dotnet build, ruff, tsc, biome) into the
# review-finding schema (see .claude/references/review-finding-schema.md)
# with source: "analyzer" and confidence: 100.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SEVERITY_DIR="$ROOT_DIR/hooks/analyzer-severity"

# --- Options ---
FORMAT=""               # msbuild | ruff | tsc | biome (auto-detect if empty)
STACK=""                # auto-detect if empty
INPUT_FILE=""           # read from stdin if empty

while [ $# -gt 0 ]; do
  case "$1" in
    --format)  FORMAT="${2:-}"; shift 2 ;;
    --stack)   STACK="${2:-}"; shift 2 ;;
    --file)    INPUT_FILE="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<'EOF'
Usage: hooks/parse-build-diagnostics.sh [--format <msbuild|ruff|tsc|biome>] [--stack <name>] [--file <path>]

Parses build tool diagnostics into review-finding-schema JSON.
Reads from stdin if --file is not specified.

--format    Override format detection (default: auto-detect from input)
--stack     Override tech stack (default: reads .claude/tech-stack)
--file      Read from file instead of stdin
EOF
      exit 0
      ;;
    *) printf 'Unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

# --- Stack detection ---
if [ -z "$STACK" ] && [ -f .claude/tech-stack ]; then
  STACK="$(tr -d '[:space:]' < .claude/tech-stack)"
fi

# --- Read input ---
if [ -n "$INPUT_FILE" ]; then
  INPUT="$(cat "$INPUT_FILE")"
else
  INPUT="$(cat)"
fi

[ -n "$INPUT" ] || { echo '{"findings":[]}'; exit 0; }

# --- Load severity mappings ---
declare -A SEVERITY_MAP
if [ -n "$STACK" ] && [ -f "$SEVERITY_DIR/$STACK.txt" ]; then
  while IFS=$'\t' read -r rule_id sev desc; do
    [ -n "$rule_id" ] && [[ ! "$rule_id" =~ ^# ]] && SEVERITY_MAP["$rule_id"]="$sev"
  done < "$SEVERITY_DIR/$STACK.txt"
fi

get_severity() {
  local rule_id="$1"
  echo "${SEVERITY_MAP[$rule_id]:-warning}"
}

# --- Format auto-detection ---
if [ -z "$FORMAT" ]; then
  if echo "$INPUT" | head -5 | grep -qE '^\[?\{' 2>/dev/null; then
    # JSON input — likely ruff or biome
    if echo "$INPUT" | grep -q '"code"' 2>/dev/null; then
      FORMAT="ruff"
    else
      FORMAT="biome"
    fi
  elif echo "$INPUT" | head -20 | grep -qE '\([0-9]+,[0-9]+\):.*warning|error' 2>/dev/null; then
    FORMAT="msbuild"
  elif echo "$INPUT" | head -20 | grep -qE '\.tsx?\([0-9]+,[0-9]+\):' 2>/dev/null; then
    FORMAT="tsc"
  else
    FORMAT="msbuild"  # default fallback
  fi
fi

# --- JSON string escaping (no jq per S3.3) ---
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"      # backslash
  s="${s//\"/\\\"}"      # double quote
  s="${s//$'\n'/\\n}"    # newline
  s="${s//$'\r'/\\r}"    # carriage return
  s="${s//$'\t'/\\t}"    # tab
  printf '%s' "$s"
}

# --- Finding counter ---
FINDING_NUM=0
next_id() {
  FINDING_NUM=$((FINDING_NUM + 1))
  printf 'A%03d' "$FINDING_NUM"
}

# --- Parse by format ---
FINDINGS=""

case "$FORMAT" in
  msbuild)
    # Pattern: path(line,col): warning|error CODE: message [project]
    while IFS= read -r line; do
      if [[ "$line" =~ ^(.+)\(([0-9]+),[0-9]+\):[[:space:]]*(warning|error)[[:space:]]+([A-Z]+[0-9]+):[[:space:]]*(.+) ]]; then
        file="${BASH_REMATCH[1]}"
        lineno="${BASH_REMATCH[2]}"
        level="${BASH_REMATCH[3]}"
        rule="${BASH_REMATCH[4]}"
        msg="${BASH_REMATCH[5]}"
        # Strip trailing [Project.csproj] if present
        msg="${msg%%\[*}"
        msg="${msg%"${msg##*[![:space:]]}"}"  # trim trailing whitespace
        sev="$(get_severity "$rule")"
        [ "$level" = "error" ] && sev="critical"
        fid="$(next_id)"
        esc_msg="$(json_escape "$msg")"
        esc_file="$(json_escape "$file")"
        FINDINGS="${FINDINGS:+$FINDINGS,}
    {\"id\":\"$fid\",\"severity\":\"$sev\",\"confidence\":100,\"rule\":\"$rule\",\"source\":\"analyzer\",\"file\":\"$esc_file\",\"line\":$lineno,\"rationale\":\"$esc_msg\",\"suggested_fix\":\"See analyzer documentation for $rule\"}"
      fi
    done <<< "$INPUT"
    ;;

  ruff)
    # ruff JSON output: array of objects with code, message, filename, location
    # Parse with basic text extraction (no jq dependency per S3.3)
    while IFS= read -r line; do
      if [[ "$line" =~ \"code\":\"([^\"]+)\" ]]; then
        rule="${BASH_REMATCH[1]}"
      fi
      if [[ "$line" =~ \"message\":\"([^\"]+)\" ]]; then
        msg="${BASH_REMATCH[1]}"
      fi
      if [[ "$line" =~ \"filename\":\"([^\"]+)\" ]]; then
        file="${BASH_REMATCH[1]}"
      fi
      if [[ "$line" =~ \"row\":([0-9]+) ]]; then
        lineno="${BASH_REMATCH[1]}"
        # Emit finding when we have all fields
        if [ -n "${rule:-}" ] && [ -n "${msg:-}" ] && [ -n "${file:-}" ]; then
          sev="$(get_severity "$rule")"
          fid="$(next_id)"
          esc_msg="$(json_escape "$msg")"
          esc_file="$(json_escape "$file")"
          FINDINGS="${FINDINGS:+$FINDINGS,}
    {\"id\":\"$fid\",\"severity\":\"$sev\",\"confidence\":100,\"rule\":\"$rule\",\"source\":\"analyzer\",\"file\":\"$esc_file\",\"line\":$lineno,\"rationale\":\"$esc_msg\",\"suggested_fix\":\"See ruff documentation for $rule\"}"
          rule="" msg="" file="" lineno=""
        fi
      fi
    done <<< "$INPUT"
    ;;

  tsc)
    # Pattern: path(line,col): error TSxxxx: message
    while IFS= read -r line; do
      if [[ "$line" =~ ^(.+)\(([0-9]+),[0-9]+\):[[:space:]]*(error)[[:space:]]+(TS[0-9]+):[[:space:]]*(.+) ]]; then
        file="${BASH_REMATCH[1]}"
        lineno="${BASH_REMATCH[2]}"
        rule="${BASH_REMATCH[4]}"
        msg="${BASH_REMATCH[5]}"
        sev="$(get_severity "$rule")"
        fid="$(next_id)"
        esc_msg="$(json_escape "$msg")"
        esc_file="$(json_escape "$file")"
        FINDINGS="${FINDINGS:+$FINDINGS,}
    {\"id\":\"$fid\",\"severity\":\"$sev\",\"confidence\":100,\"rule\":\"$rule\",\"source\":\"analyzer\",\"file\":\"$esc_file\",\"line\":$lineno,\"rationale\":\"$esc_msg\",\"suggested_fix\":\"See TypeScript documentation for $rule\"}"
      fi
    done <<< "$INPUT"
    ;;

  biome)
    # Biome JSON output — similar structure to ruff
    while IFS= read -r line; do
      if [[ "$line" =~ \"category\":\"([^\"]+)\" ]]; then
        rule="${BASH_REMATCH[1]}"
      fi
      if [[ "$line" =~ \"message\":\"([^\"]+)\" ]]; then
        msg="${BASH_REMATCH[1]}"
      fi
      if [[ "$line" =~ \"path\":\"([^\"]+)\" ]]; then
        file="${BASH_REMATCH[1]}"
      fi
      if [[ "$line" =~ \"line\":([0-9]+) ]]; then
        lineno="${BASH_REMATCH[1]}"
        if [ -n "${rule:-}" ] && [ -n "${msg:-}" ] && [ -n "${file:-}" ]; then
          sev="$(get_severity "$rule")"
          fid="$(next_id)"
          esc_msg="$(json_escape "$msg")"
          esc_file="$(json_escape "$file")"
          FINDINGS="${FINDINGS:+$FINDINGS,}
    {\"id\":\"$fid\",\"severity\":\"$sev\",\"confidence\":100,\"rule\":\"$rule\",\"source\":\"analyzer\",\"file\":\"$esc_file\",\"line\":$lineno,\"rationale\":\"$esc_msg\",\"suggested_fix\":\"See Biome documentation for $rule\"}"
          rule="" msg="" file="" lineno=""
        fi
      fi
    done <<< "$INPUT"
    ;;
esac

# --- Emit JSON ---
cat <<EOF
{
  "findings": [${FINDINGS}
  ]
}
EOF
