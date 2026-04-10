#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || fail "Missing file: $1"
}

require_section() {
  local file="$1"
  local pattern="$2"
  grep -q "$pattern" "$file" || fail "Missing section '$pattern' in $file"
}

require_file ".claude/manifest.json"
require_file ".claude-plugin/plugin.json"
require_file "README.md"
require_file "CONTRIBUTING.md"
require_file "AGENTS.md"
require_file ".claude/references/coding-guidelines.md"
require_file ".claude/references/testing-patterns.md"
require_file ".claude/references/security-checklist.md"
require_file ".claude/references/performance-checklist.md"
require_file ".claude/references/ef-core-checklist.md"
require_file ".claude/references/mediatr-slice-patterns.md"

manifest_version="$(grep -E '"version"' .claude/manifest.json | head -1 | sed -E 's/.*"version": "([^"]+)".*/\1/')"
plugin_version="$(grep -E '"version"' .claude-plugin/plugin.json | head -1 | sed -E 's/.*"version": "([^"]+)".*/\1/')"

[ "$manifest_version" = "$plugin_version" ] || fail "Version mismatch: manifest=$manifest_version plugin=$plugin_version"

while IFS= read -r file; do
  require_section "$file" '^---$'
done < <(find .claude/commands .claude/agents .claude/skills -name '*.md' | sort)

while IFS= read -r skill; do
  skill_dir="$(basename "$(dirname "$skill")")"
  skill_name="$(grep -E '^name:' "$skill" | sed -E 's/name:[[:space:]]*//')"
  [ "$skill_dir" = "$skill_name" ] || fail "Skill name mismatch: $skill uses '$skill_name' but directory is '$skill_dir'"
  require_section "$skill" '^## Overview'
  require_section "$skill" '^## When To Use'
  require_section "$skill" '^## Workflow'
  require_section "$skill" '^## Verification'
done < <(find .claude/skills -name 'SKILL.md' | sort)

while IFS= read -r path; do
  [ -e "$path" ] || fail "Manifest references missing path: $path"
done < <(awk '/"files": \{/,/^[[:space:]]*\},?$/' .claude/manifest.json | grep -E '"source": ' | sed -E 's/.*"source": "([^"]+)".*/\1/')

grep -q 'skills/' README.md || fail "README does not describe skills"
grep -q 'AGENTS.md' README.md || fail "README does not mention AGENTS.md"
grep -q 'docs/skill-anatomy.md' CONTRIBUTING.md || fail "CONTRIBUTING does not point to skill anatomy guidance"
grep -q 'test-driven-development-dotnet' README.md || fail "README does not mention the new skill set"
grep -q 'context-engineering' AGENTS.md || fail "AGENTS.md does not route context-engineering"

printf 'Toolkit validation passed.\n'
