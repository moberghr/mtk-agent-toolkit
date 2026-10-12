#!/usr/bin/env bash
# secret-scan.sh — grep-based pre-write secret detector. See block below.
set -euo pipefail

# Contract:
#   secret-scan.sh <file>...
#     exit 0                                    → clean, write may proceed
#     exit 1 + "<file>:<line>: <pattern>" lines → at least one match, BLOCK write
#   secret-scan.sh --self-test
#     Feeds tests/fixtures/known-secrets.txt and asserts every pattern fires.
# Precision over recall — escape hatch: MTK_SECRET_SCAN_SKIP=1.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# pattern_name|egrep_pattern
PATTERNS=(
  "aws-access-key|AKIA[0-9A-Z]{16}"
  "azure-storage-key|DefaultEndpointsProtocol=.*AccountKey=[A-Za-z0-9+/=]{20,}"
  "github-token|gh[pousr]_[0-9a-zA-Z]{36,}"
  "slack-token|xox[baprs]-[0-9a-zA-Z-]{10,}"
  "anthropic-key|sk-ant-[a-zA-Z0-9_-]{20,}"
  "openai-key|sk-[a-zA-Z0-9]{32,}"
  "private-key-block|-----BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----"
  "password-assignment|(password|passwd|pwd|secret|api[_-]?key)[[:space:]]*[:=][[:space:]]*[\"'][^\"']{12,}[\"']"
  "iban|\\b[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}\\b"
  "jwt|eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}"
  "url-credential|[a-zA-Z][a-zA-Z0-9+.-]*://[^[:space:]/@:]+:[^[:space:]/@]+@"
)

# url-credential fires on scheme://user:password@ regardless of whether the
# credential is a real secret or an obvious placeholder. Placeholders are
# filtered out below (checked against the matched credential text only, never
# the full line, so a real secret next to a host like "example.azurewebsites.net"
# still fires).
URL_CREDENTIAL_PLACEHOLDER_ERE='user:pass@|<user>:<pass(word)?>@|username:password@|foo:bar@|example|xxx'

scan_file() {
  local file="$1"
  local hits=0
  [[ -f "$file" ]] || return 0
  for entry in "${PATTERNS[@]}"; do
    local name="${entry%%|*}"
    local pattern="${entry#*|}"
    while IFS=: read -r lineno _; do
      [[ -n "$lineno" ]] || continue
      if [[ "$name" == "url-credential" ]]; then
        local matched
        matched="$(sed -n "${lineno}p" "$file" | grep -oE -- "$pattern" | head -1)"
        grep -qEi -- "$URL_CREDENTIAL_PLACEHOLDER_ERE" <<<"$matched" && continue
      fi
      echo "${file}:${lineno}: ${name}" >&2
      hits=$((hits + 1))
    done < <(grep -nE -e "$pattern" "$file" 2>/dev/null || true)
  done
  return "$hits"
}

self_test() {
  local fixture="$REPO_ROOT/tests/fixtures/known-secrets.txt"
  if [[ ! -f "$fixture" ]]; then
    echo "self-test: fixture not found at $fixture" >&2
    exit 2
  fi
  local missing=0
  for entry in "${PATTERNS[@]}"; do
    local name="${entry%%|*}"
    local pattern="${entry#*|}"
    if ! grep -qE -e "$pattern" "$fixture"; then
      echo "self-test: pattern '$name' did not fire on fixture" >&2
      missing=$((missing + 1))
    fi
  done
  if (( missing > 0 )); then
    echo "self-test: $missing pattern(s) missing fixture coverage" >&2
    exit 1
  fi
  echo "self-test: all ${#PATTERNS[@]} patterns fire on fixture"
}

main() {
  if [[ "${MTK_SECRET_SCAN_SKIP:-0}" == "1" ]]; then
    echo "secret-scan: skipped (MTK_SECRET_SCAN_SKIP=1)" >&2
    exit 0
  fi

  if [[ $# -eq 0 ]]; then
    echo "usage: secret-scan.sh <file>... | --self-test" >&2
    exit 2
  fi

  if [[ "$1" == "--self-test" ]]; then
    self_test
    exit 0
  fi

  local total_hits=0
  for f in "$@"; do
    scan_file "$f" || total_hits=$((total_hits + $?))
  done

  if (( total_hits > 0 )); then
    echo "secret-scan: blocked write — $total_hits match(es). Investigate before retrying." >&2
    exit 1
  fi
}

main "$@"
