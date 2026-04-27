---
name: context-report
description: Diagnostic snapshot of active MTK configuration — tech stack, references, linter packs, domains, hooks, and rules
type: skill
license: MIT
compatibility:
  - claude-code
  - cursor
  - codex
user-invocable: false
---

# Context Report

## Overview

Diagnostic snapshot of the MTK toolkit's active configuration. Shows what's loaded, what's not, and why. Use this when debugging review behavior, understanding why a linter pattern fired, or verifying that a domain pack is active.

## When To Use

- After running `/mtk-setup` to verify configuration
- When a review misses something and you want to see what references loaded
- When onboarding to a new repo to understand the MTK setup
- When debugging linter false positives or false negatives

### When NOT To Use

- As part of normal implementation flow (context-engineering handles loading)

## Workflow

### STEP 1 — Gather state

Collect the following diagnostic data and present it in a single structured report.

#### 1a. Tech Stack

```!
echo "--- Tech Stack ---"
cat .claude/tech-stack 2>/dev/null || echo "(not set)"
if [ -f .claude/tech-stack-pm ]; then echo "Package Manager: $(cat .claude/tech-stack-pm)"; fi
```

#### 1b. Active Domains

```!
echo "--- Domains ---"
if [ -f .claude/domains ]; then
  cat .claude/domains
else
  echo "(none — create .claude/domains with one domain per line to activate domain packs)"
fi
```

#### 1c. Linter Packs

```!
echo "--- Linter Packs ---"
PATTERNS_DIR="hooks/linter-patterns"

echo "Core:"
if [ -d "$PATTERNS_DIR/core" ]; then
  for f in "$PATTERNS_DIR"/core/*.txt; do
    [ -f "$f" ] && echo "  $(basename "$f") ($(grep -c '^[^#]' "$f" 2>/dev/null || echo 0) rules)"
  done
else
  echo "  (flat-file layout — pre-6.2)"
fi

STACK="$(cat .claude/tech-stack 2>/dev/null | tr -d '[:space:]')"
if [ -n "$STACK" ]; then
  echo "Stack ($STACK):"
  if [ -d "$PATTERNS_DIR/stack-$STACK" ]; then
    for f in "$PATTERNS_DIR"/stack-"$STACK"/*.txt; do
      [ -f "$f" ] && echo "  $(basename "$f") ($(grep -c '^[^#]' "$f" 2>/dev/null || echo 0) rules)"
    done
  else
    echo "  (not found)"
  fi
fi

echo "Domain:"
if [ -f .claude/domains ]; then
  while IFS= read -r domain; do
    domain="$(echo "$domain" | tr -d '[:space:]')"
    [ -z "$domain" ] && continue
    [[ "$domain" == \#* ]] && continue
    if [ -d "$PATTERNS_DIR/domain-$domain" ]; then
      for f in "$PATTERNS_DIR"/domain-"$domain"/*.txt; do
        [ -f "$f" ] && echo "  $domain/$(basename "$f") ($(grep -c '^[^#]' "$f" 2>/dev/null || echo 0) rules)"
      done
    else
      echo "  $domain: (pack not found at $PATTERNS_DIR/domain-$domain/)"
    fi
  done < .claude/domains
else
  echo "  (no .claude/domains file)"
fi

echo "Project-local:"
project_count=0
if [ -d "$PATTERNS_DIR/project" ]; then
  for f in "$PATTERNS_DIR"/project/*.txt; do
    [ -f "$f" ] && echo "  $(basename "$f") ($(grep -c '^[^#]' "$f" 2>/dev/null || echo 0) rules)" && project_count=$((project_count+1))
  done
fi
[ "$project_count" -eq 0 ] && echo "  (none — add .txt files to hooks/linter-patterns/project/)"
```

#### 1d. Rules Files

```!
echo "--- Rules ---"
if [ -d .claude/rules ]; then
  for f in .claude/rules/*.md; do
    [ -f "$f" ] && echo "  $(basename "$f") ($(wc -l < "$f" | tr -d ' ') lines)"
  done
else
  echo "(no .claude/rules/ directory)"
fi
```

#### 1e. Hook Status

```!
echo "--- Hooks ---"
for hook_file in .claude/settings.json hooks/hooks.json; do
  if [ -f "$hook_file" ]; then
    echo "  $hook_file:"
    grep -oE '"(PreToolUse|PostToolUse|PostCompact|Stop|SessionStart)"' "$hook_file" 2>/dev/null | sort -u | sed 's/^/    event: /' || echo "    (no hooks)"
  fi
done

echo "Git hooks:"
if [ -f hooks/git-hooks/pre-commit ] && [ -x hooks/git-hooks/pre-commit ]; then
  echo "  pre-commit: active"
else
  echo "  pre-commit: NOT FOUND or not executable"
fi
```

#### 1f. Review Agents

```!
echo "--- Review Agents ---"
for agent in .claude/agents/*.md; do
  [ -f "$agent" ] || continue
  name="$(grep '^name:' "$agent" | sed 's/name:[[:space:]]*//' | head -1)"
  model="$(grep '^model:' "$agent" | sed 's/model:[[:space:]]*//' | head -1)"
  echo "  $name (model: ${model:-default})"
done
```

#### 1g. Reference Coverage

```!
echo "--- References ---"
echo "Shared:"
for f in .claude/references/*.md; do
  [ -f "$f" ] && echo "  $(basename "$f")"
done

STACK="$(cat .claude/tech-stack 2>/dev/null | tr -d '[:space:]')"
if [ -n "$STACK" ] && [ -d ".claude/references/$STACK" ]; then
  echo "Stack ($STACK):"
  for f in ".claude/references/$STACK"/*.md; do
    [ -f "$f" ] && echo "  $(basename "$f")"
  done
fi
```

#### 1h. Reference Footprint

```!
echo "--- Reference Footprint ---"
total_lines=0
STACK="$(cat .claude/tech-stack 2>/dev/null | tr -d '[:space:]')"

for f in .claude/references/*.md; do
  [ -f "$f" ] || continue
  lines=$(wc -l < "$f" | tr -d ' ')
  tokens=$((lines * 13))
  printf "  %-45s %4d lines  (~%dk tokens)\n" "$(basename "$f")" "$lines" "$((tokens / 1000 + 1))"
  total_lines=$((total_lines + lines))
done

if [ -n "$STACK" ] && [ -d ".claude/references/$STACK" ]; then
  for f in ".claude/references/$STACK"/*.md; do
    [ -f "$f" ] || continue
    lines=$(wc -l < "$f" | tr -d ' ')
    tokens=$((lines * 13))
    printf "  %-45s %4d lines  (~%dk tokens)\n" "$STACK/$(basename "$f")" "$lines" "$((tokens / 1000 + 1))"
    total_lines=$((total_lines + lines))
  done
fi

total_tokens=$((total_lines * 13))
echo "  ──────────────────────────────────────────────────────────────────"
printf "  Total available: %d lines  (~%dk tokens)\n" "$total_lines" "$((total_tokens / 1000 + 1))"
echo "  (actual load depends on path-scoped matching in context-engineering)"
```

#### 1i. Active Specs

```!
echo "--- Active Specs ---"
if [ -d docs/specs ]; then
  # Group by slug (strip date prefix, -vN suffix, and extension)
  declare -A slugs 2>/dev/null || true
  for f in docs/specs/*.md; do
    [ -f "$f" ] || continue
    base="$(basename "$f" .md)"
    # Strip leading date (YYYY-MM-DD-)
    slug="${base#????-??-??-}"
    # Strip trailing -vN suffix
    slug="$(echo "$slug" | sed 's/-v[0-9]*$//')"
    echo "  $f"
  done | sort
  # Show version groups
  echo ""
  echo "  Version groups:"
  for f in docs/specs/*.json; do
    [ -f "$f" ] || continue
    base="$(basename "$f" .json)"
    slug="${base#????-??-??-}"
    slug="$(echo "$slug" | sed 's/-v[0-9]*$//')"
    version_marker=""
    if echo "$base" | grep -qE '\-v[0-9]+$'; then
      version_marker=" $(echo "$base" | grep -oE 'v[0-9]+$')"
    else
      version_marker=" v1"
    fi
    printf "    slug=%-35s  file=%s\n" "$slug" "$(basename "$f")"
  done
else
  echo "  (no docs/specs/ directory)"
fi
```

### STEP 2 — Report

Present the gathered data as a clean summary. Flag any issues:
- Tech stack set but no matching stack skill → warn
- Domain listed but no matching domain pack → warn
- Hook file missing or not executable → warn
- Reference directory missing for active stack → warn

## Verification

- All sections render without errors
- Warnings accurately reflect missing configuration
- No false alarms for optional components (domains, project packs)
