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

# Always-required files (stack-agnostic)
require_file ".claude/manifest.json"
require_file ".claude-plugin/plugin.json"
require_file "README.md"
require_file "CONTRIBUTING.md"
require_file "AGENTS.md"

# Generic references — required regardless of stack
require_file ".claude/references/testing-patterns.md"
require_file ".claude/references/security-checklist.md"
require_file ".claude/references/performance-checklist.md"

# Reviewer agents — the two-stage review model depends on these
require_file ".claude/agents/compliance-reviewer.md"
require_file ".claude/agents/test-reviewer.md"
require_file ".claude/agents/architecture-reviewer.md"

# Settings sanity (ported from former doctor command)
require_file ".claude/settings.json"
grep -q '"deny"' .claude/settings.json || fail "settings.json missing permissions.deny — dangerous operations are not blocked"
grep -q '"hooks"' .claude/settings.json || fail "settings.json missing hooks block — verify-completion / format hooks are not registered"

# Tech stack validation: each tech stack skill must declare its own reference files,
# and those files must exist. The toolkit ships with at least the dotnet stack.
for stack_dir in .claude/skills/tech-stack-*/; do
  [ -d "$stack_dir" ] || continue
  stack_skill="${stack_dir}SKILL.md"
  require_file "$stack_skill"
  stack_name="$(basename "$stack_dir" | sed 's/^tech-stack-//')"
  # Each tech stack has a coding-guidelines reference (even if placeholder)
  require_file ".claude/references/${stack_name}/coding-guidelines.md"
done

manifest_version="$(grep -E '"version"' .claude/manifest.json | head -1 | sed -E 's/.*"version": "([^"]+)".*/\1/')"
plugin_version="$(grep -E '"version"' .claude-plugin/plugin.json | head -1 | sed -E 's/.*"version": "([^"]+)".*/\1/')"

[ "$manifest_version" = "$plugin_version" ] || fail "Version mismatch: manifest=$manifest_version plugin=$plugin_version"

# Manifest source path existence + collect manifest-tracked skill paths.
# manifest.json has no nested objects with "source" keys other than file entries,
# so a flat grep is sufficient and correct.
manifest_skill_paths=()
while IFS= read -r path; do
  [ -e "$path" ] || fail "Manifest references missing path: $path"
  case "$path" in
    .claude/skills/*/SKILL.md) manifest_skill_paths+=("$path") ;;
  esac
done < <(grep -E '^[[:space:]]*"source":' .claude/manifest.json | sed -E 's/.*"source":[[:space:]]*"([^"]+)".*/\1/' | grep -v '://')

# applyTo values must be glob patterns (strings). Quick sanity: any applyTo line
# must be an array opener or a quoted glob. Detect obvious errors (non-array value).
if grep -nE '"applyTo":[[:space:]]*[^\[]' .claude/manifest.json | grep -v '"applyTo": \[$' >/dev/null; then
  fail "manifest.json has an 'applyTo' entry that is not an array. Use [\"glob1\", \"glob2\"] form."
fi

# Frontmatter check on commands, agents, and manifest-tracked skills only.
# (Third-party skill plugins under .claude/skills/ — e.g. gitnexus/ — are not MTK-managed.)
while IFS= read -r file; do
  require_section "$file" '^---$'
done < <({ find .claude/commands .claude/agents -name '*.md'; printf '%s\n' "${manifest_skill_paths[@]+"${manifest_skill_paths[@]}"}"; } | sort -u)

# Skill anatomy check — only MTK-managed skills (those in the manifest)
for skill in "${manifest_skill_paths[@]+"${manifest_skill_paths[@]}"}"; do
  skill_dir="$(basename "$(dirname "$skill")")"
  skill_name="$(grep -E '^name:' "$skill" | sed -E 's/name:[[:space:]]*//')"
  [ "$skill_dir" = "$skill_name" ] || fail "Skill name mismatch: $skill uses '$skill_name' but directory is '$skill_dir'"
  require_section "$skill" '^## Overview'
  require_section "$skill" '^## When To Use'
  # Tech stack skills don't have a Workflow section — they're declarative context.
  # All other skills must.
  if ! echo "$skill_dir" | grep -q '^tech-stack-'; then
    require_section "$skill" '^## Workflow'
  fi
  require_section "$skill" '^## Verification'
done

# README and AGENTS coverage
grep -q 'skills/' README.md || fail "README does not describe skills"
grep -q 'AGENTS.md' README.md || fail "README does not mention AGENTS.md"
grep -q 'docs/skill-anatomy.md' CONTRIBUTING.md || fail "CONTRIBUTING does not point to skill anatomy guidance"
grep -q 'tech-stack' README.md || fail "README does not mention the tech stack architecture"
grep -q 'context-engineering' AGENTS.md || fail "AGENTS.md does not route context-engineering"

# Token budget enforcement: prevent context bloat
if [ -f "CLAUDE.md" ]; then
  claude_lines="$(wc -l < CLAUDE.md)"
  [ "$claude_lines" -le 200 ] || fail "CLAUDE.md exceeds 200-line budget ($claude_lines lines). Move detail to .claude/rules/"
fi

for skill in "${manifest_skill_paths[@]+"${manifest_skill_paths[@]}"}"; do
  skill_lines="$(wc -l < "$skill")"
  # Tech stack skills are larger — they carry scan recipes and full reference paths.
  if echo "$skill" | grep -q 'tech-stack-'; then
    [ "$skill_lines" -le 1000 ] || fail "Tech stack skill $skill exceeds 1000-line budget ($skill_lines lines). Split scan recipes or references into companion files."
  else
    [ "$skill_lines" -le 500 ] || fail "Skill $skill exceeds 500-line budget ($skill_lines lines). Split into core + reference files"
  fi
done

if [ -d ".claude/rules" ]; then
  while IFS= read -r rule; do
    rule_lines="$(wc -l < "$rule")"
    [ "$rule_lines" -le 120 ] || fail "Rule file $rule exceeds 120-line budget ($rule_lines lines). Tighten wording or split"
  done < <(find .claude/rules -name '*.md' | sort)
fi

printf 'Toolkit validation passed.\n'
