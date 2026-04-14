#!/usr/bin/env bash
#
# API backward compatibility checker. Scans the diff against main for
# breaking changes: removed routes, changed DTOs, removed public properties.
# Emits findings in review-finding-schema JSON with source: "linter".

set -euo pipefail

BASE_BRANCH="${1:-main}"
STACK=""

if [ -f .claude/tech-stack ]; then
  STACK="$(tr -d '[:space:]' < .claude/tech-stack)"
fi

# Get the diff against base branch
DIFF="$(git diff "$BASE_BRANCH"...HEAD 2>/dev/null || git diff "$BASE_BRANCH" 2>/dev/null || true)"
[ -n "$DIFF" ] || { echo '{"findings":[]}'; exit 0; }

# Only look at removed lines (lines starting with -)
REMOVED="$(echo "$DIFF" | grep '^-[^-]' || true)"
[ -n "$REMOVED" ] || { echo '{"findings":[]}'; exit 0; }

FINDING_NUM=0
FINDINGS=""

add_finding() {
  local sev="$1" rule="$2" file="$3" line="$4" rationale="$5" fix="$6"
  FINDING_NUM=$((FINDING_NUM + 1))
  local fid
  fid="$(printf 'BC%03d' "$FINDING_NUM")"
  FINDINGS="${FINDINGS:+$FINDINGS,}
    {\"id\":\"$fid\",\"severity\":\"$sev\",\"confidence\":100,\"rule\":\"$rule\",\"source\":\"linter\",\"file\":\"$file\",\"line\":$line,\"rationale\":\"$rationale\",\"suggested_fix\":\"$fix\"}"
}

# --- .NET breaking changes ---
if [ "$STACK" = "dotnet" ]; then
  # Removed [Http*] routes
  while IFS= read -r line; do
    if [[ "$line" =~ ^---\ a/(.+)$ ]]; then
      current_file="${BASH_REMATCH[1]}"
    fi
    if [[ "$line" =~ ^-.*\[(HttpGet|HttpPost|HttpPut|HttpPatch|HttpDelete)\(\"([^\"]+)\"\) ]]; then
      route="${BASH_REMATCH[2]}"
      add_finding "critical" "API-ROUTE-REMOVED" "$current_file" 0 \
        "API route removed: [${BASH_REMATCH[1]}(\\\"$route\\\")] — existing consumers will get 404" \
        "Deprecate with [Obsolete] before removing, or add a redirect"
    fi
    # Removed public properties from DTOs/records
    if [[ "$line" =~ ^-[[:space:]]+public[[:space:]]+(required[[:space:]]+)?[A-Za-z\<\>\[\]\?]+[[:space:]]+([A-Za-z]+)[[:space:]]*\{ ]]; then
      prop="${BASH_REMATCH[2]}"
      if echo "$current_file" | grep -qiE '(dto|request|response|model|contract|event)'; then
        add_finding "warning" "API-PROPERTY-REMOVED" "$current_file" 0 \
          "Public property '$prop' removed from API contract type — may break deserialization for consumers" \
          "Mark as [Obsolete] or [JsonIgnore] before removing from the type"
      fi
    fi
    # Removed public method signatures
    if [[ "$line" =~ ^-[[:space:]]+public[[:space:]]+(static[[:space:]]+)?(async[[:space:]]+)?[A-Za-z\<\>\[\]\?]+[[:space:]]+([A-Za-z]+)\( ]]; then
      method="${BASH_REMATCH[3]}"
      if echo "$current_file" | grep -qiE '(controller|endpoint|handler|service\.cs)'; then
        add_finding "warning" "API-METHOD-REMOVED" "$current_file" 0 \
          "Public method '$method' removed from API surface — callers will break" \
          "Deprecate before removing, or verify no external consumers"
      fi
    fi
  done <<< "$DIFF"
fi

# --- Python breaking changes ---
if [ "$STACK" = "python" ]; then
  current_file=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^---\ a/(.+)$ ]]; then
      current_file="${BASH_REMATCH[1]}"
    fi
    # Removed route decorators
    if [[ "$line" =~ ^-.*@(app|router)\.(get|post|put|patch|delete)\(\"([^\"]+)\" ]]; then
      route="${BASH_REMATCH[3]}"
      add_finding "critical" "API-ROUTE-REMOVED" "$current_file" 0 \
        "API route removed: @${BASH_REMATCH[1]}.${BASH_REMATCH[2]}(\\\"$route\\\") — consumers will get 404" \
        "Deprecate before removing"
    fi
    # Removed class attributes from dataclass/pydantic models
    if [[ "$line" =~ ^-[[:space:]]+([a-z_]+):[[:space:]] ]]; then
      field="${BASH_REMATCH[1]}"
      if echo "$current_file" | grep -qiE '(schema|model|dto|request|response)'; then
        add_finding "warning" "API-FIELD-REMOVED" "$current_file" 0 \
          "Field '$field' removed from API contract type — may break consumers" \
          "Mark as deprecated before removing"
      fi
    fi
  done <<< "$DIFF"
fi

# --- TypeScript breaking changes ---
if [ "$STACK" = "typescript" ]; then
  current_file=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^---\ a/(.+)$ ]]; then
      current_file="${BASH_REMATCH[1]}"
    fi
    # Removed route handlers
    if [[ "$line" =~ ^-.*\.(get|post|put|patch|delete)\([\"\']/([^\"\']+ ]]; then
      route="${BASH_REMATCH[2]}"
      add_finding "critical" "API-ROUTE-REMOVED" "$current_file" 0 \
        "API route removed: .${BASH_REMATCH[1]}(\\\"/$route\\\") — consumers will get 404" \
        "Deprecate before removing"
    fi
    # Removed exported interface/type properties
    if [[ "$line" =~ ^-[[:space:]]+([a-zA-Z]+)\??\: ]]; then
      prop="${BASH_REMATCH[1]}"
      if echo "$current_file" | grep -qiE '(type|interface|dto|schema|model)'; then
        add_finding "warning" "API-PROPERTY-REMOVED" "$current_file" 0 \
          "Property '$prop' removed from exported type — may break consumers" \
          "Mark as @deprecated before removing"
      fi
    fi
  done <<< "$DIFF"
fi

# --- Language-agnostic: OpenAPI spec changes ---
if git diff "$BASE_BRANCH"...HEAD --name-only 2>/dev/null | grep -qiE '(openapi|swagger)\.(json|ya?ml)'; then
  add_finding "warning" "API-SPEC-CHANGED" "openapi/swagger spec" 0 \
    "OpenAPI/Swagger specification file modified — verify backward compatibility" \
    "Run an OpenAPI diff tool to check for breaking changes"
fi

# Output
cat <<EOF
{
  "findings": [${FINDINGS}
  ]
}
EOF
