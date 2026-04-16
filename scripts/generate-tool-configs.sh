#!/usr/bin/env bash
set -euo pipefail

# generate-tool-configs.sh — Generate native config files for non-Claude AI coding tools
#
# Generates project guidelines in each tool's native format, using the same
# reference files that power AGENTS.md. Content is read-only — regenerate
# with this script, don't hand-edit.
#
# Formats:
#   cursor-rules   .cursor/rules/mtk-*.mdc  (glob-scoped Cursor rules)
#   copilot         .github/copilot-instructions.md
#   windsurf        .windsurfrules
#   gemini          GEMINI.md
#   cline           .clinerules
#
# Usage:
#   bash scripts/generate-tool-configs.sh --all
#   bash scripts/generate-tool-configs.sh --format cursor-rules
#   bash scripts/generate-tool-configs.sh --format copilot --format windsurf

REFS_DIR=".claude/references"
MANIFEST=".claude/manifest.json"
TECH_STACK_FILE=".claude/tech-stack"

# ─── Helpers ───────────────────────────────────────────────────────────────────

# Strip YAML frontmatter and the first # heading. Shared with generate-agents-md.sh.
strip_frontmatter_and_title() {
  local file="$1"
  local in_frontmatter=0
  local frontmatter_done=0
  local title_stripped=0

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$frontmatter_done" -eq 0 ] && [ "$line" = "---" ]; then
      if [ "$in_frontmatter" -eq 0 ]; then
        in_frontmatter=1; continue
      else
        in_frontmatter=0; frontmatter_done=1; continue
      fi
    fi
    [ "$in_frontmatter" -eq 1 ] && continue
    if [ "$title_stripped" -eq 0 ]; then
      [ -z "$line" ] && continue
      case "$line" in "# "*) title_stripped=1; continue ;; *) title_stripped=1 ;; esac
    fi
    printf '%s\n' "$line"
  done < "$file"
}

# Collapse runs of 3+ consecutive blank lines to one blank line.
collapse_blank_lines() {
  awk '
    /^[[:space:]]*$/ { blank++; next }
    { if (blank > 0) print ""; blank = 0; print }
    END { if (blank > 0) print "" }
  '
}

# Extract applyTo globs for a manifest target path.
# Outputs comma-separated quoted strings, e.g.: "**/*DbContext*", "**/Entities/**"
# Returns empty string if no applyTo found.
extract_apply_to() {
  local target="$1"
  [ -f "$MANIFEST" ] || return 0
  awk -v target="$target" '
    BEGIN { found=0; in_apply=0 }
    index($0, "\"" target "\"") > 0 && /\"target\"/ { found=1; next }
    found && /\"applyTo\"/ { in_apply=1; next }
    in_apply && /\]/ { exit }
    in_apply {
      gsub(/^[[:space:]]+/, "")
      gsub(/,$/, "")
      if ($0 ~ /^"/) printf "%s, ", $0
    }
    found && !in_apply && /^\s*\}/ { found=0 }
  ' "$MANIFEST" | sed 's/, $//'
}

# ─── Detect tech stack ─────────────────────────────────────────────────────────

stack=""
if [ -f "$TECH_STACK_FILE" ]; then
  stack="$(tr -d '[:space:]' < "$TECH_STACK_FILE")"
fi

# ─── Content assembly ──────────────────────────────────────────────────────────

# Emit a single reference file as a markdown section.
emit_section() {
  local title="$1" file="$2"
  [ -f "$file" ] || return 0
  printf '## %s\n\n' "$title"
  strip_frontmatter_and_title "$file" | collapse_blank_lines
  printf '\n\n'
}

# Assemble all reference content into a single stream (for flat-file formats).
assemble_all_content() {
  # Architecture principles
  emit_section "Architecture Principles" "$REFS_DIR/architecture-principles.md"

  # Coding guidelines (from active tech stack)
  if [ -n "$stack" ] && [ -f "$REFS_DIR/${stack}/coding-guidelines.md" ]; then
    local display_stack
    display_stack="$(echo "$stack" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
    emit_section "Coding Guidelines ($display_stack)" "$REFS_DIR/${stack}/coding-guidelines.md"
  fi

  # Core references
  emit_section "Security Requirements" "$REFS_DIR/security-checklist.md"
  emit_section "Testing Expectations" "$REFS_DIR/testing-patterns.md"
  emit_section "Performance Guidelines" "$REFS_DIR/performance-checklist.md"

  # Stack-specific supplements
  if [ -n "$stack" ] && [ -d "$REFS_DIR/${stack}" ]; then
    local display_stack
    display_stack="$(echo "$stack" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
    for supplement in "$REFS_DIR/${stack}/"*.md; do
      [ -f "$supplement" ] || continue
      local basename_file
      basename_file="$(basename "$supplement")"
      [ "$basename_file" = "coding-guidelines.md" ] && continue
      [ "$basename_file" = "analyzer-config.md" ] && continue
      local section_name
      section_name="$(echo "$basename_file" | sed 's/\.md$//' | sed 's/-/ /g')"
      section_name="$(echo "$section_name" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1')"
      emit_section "$display_stack — $section_name" "$supplement"
    done
  fi

  # Domain supplements
  for domain_file in "$REFS_DIR"/domain-*.md; do
    [ -f "$domain_file" ] || continue
    local domain_name
    domain_name="$(basename "$domain_file" | sed 's/^domain-//' | sed 's/\.md$//')"
    local display_domain
    display_domain="$(echo "$domain_name" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
    emit_section "Domain — $display_domain" "$domain_file"
  done
}

# ─── Format: Cursor MDC Rules ─────────────────────────────────────────────────
# Each reference becomes a .cursor/rules/mtk-*.mdc file with frontmatter.
# Files with applyTo globs get glob-scoped rules; others get alwaysApply: true.

write_mdc() {
  local file="$1" output="$2" description="$3" globs="${4:-}"
  {
    printf -- '---\n'
    printf 'description: %s\n' "$description"
    if [ -n "$globs" ]; then
      printf 'globs: [%s]\n' "$globs"
      printf 'alwaysApply: false\n'
    else
      printf 'alwaysApply: true\n'
    fi
    printf -- '---\n\n'
    strip_frontmatter_and_title "$file" | collapse_blank_lines
  } > "$output"
}

generate_cursor_rules() {
  mkdir -p .cursor/rules

  # Remove stale MTK-generated rules (only mtk-* prefixed files)
  find .cursor/rules -name "mtk-*.mdc" -delete 2>/dev/null || true

  # Always-apply: architecture principles
  if [ -f "$REFS_DIR/architecture-principles.md" ]; then
    write_mdc "$REFS_DIR/architecture-principles.md" \
      ".cursor/rules/mtk-architecture.mdc" \
      "Architecture principles for this codebase"
  fi

  # Always-apply: coding guidelines
  if [ -n "$stack" ] && [ -f "$REFS_DIR/${stack}/coding-guidelines.md" ]; then
    write_mdc "$REFS_DIR/${stack}/coding-guidelines.md" \
      ".cursor/rules/mtk-coding-guidelines.mdc" \
      "$stack coding guidelines and conventions"
  fi

  # Always-apply: security checklist
  if [ -f "$REFS_DIR/security-checklist.md" ]; then
    write_mdc "$REFS_DIR/security-checklist.md" \
      ".cursor/rules/mtk-security.mdc" \
      "Security checklist — auth, secrets, PII, SQL injection"
  fi

  # Glob-scoped: testing patterns
  if [ -f "$REFS_DIR/testing-patterns.md" ]; then
    local globs
    globs="$(extract_apply_to ".claude/references/testing-patterns.md")"
    [ -z "$globs" ] && globs='"**/tests/**", "**/*.test.*", "**/*.spec.*", "**/*Test*"'
    write_mdc "$REFS_DIR/testing-patterns.md" \
      ".cursor/rules/mtk-testing.mdc" \
      "Testing patterns and conventions" \
      "$globs"
  fi

  # On-demand: performance checklist (no globs — manually loaded)
  if [ -f "$REFS_DIR/performance-checklist.md" ]; then
    write_mdc "$REFS_DIR/performance-checklist.md" \
      ".cursor/rules/mtk-performance.mdc" \
      "Performance checklist — load when optimizing"
  fi

  # Stack-specific supplements with applyTo globs
  if [ -n "$stack" ] && [ -d "$REFS_DIR/${stack}" ]; then
    for supplement in "$REFS_DIR/${stack}/"*.md; do
      [ -f "$supplement" ] || continue
      local basename_file
      basename_file="$(basename "$supplement")"
      [ "$basename_file" = "coding-guidelines.md" ] && continue
      [ "$basename_file" = "analyzer-config.md" ] && continue

      local rule_name section_name target_path globs
      rule_name="$(echo "$basename_file" | sed 's/\.md$//')"
      section_name="$(echo "$rule_name" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)} 1')"
      target_path=".claude/references/${stack}/${basename_file}"
      globs="$(extract_apply_to "$target_path")"

      if [ -n "$globs" ]; then
        write_mdc "$supplement" \
          ".cursor/rules/mtk-${stack}-${rule_name}.mdc" \
          "$stack — $section_name" \
          "$globs"
      else
        write_mdc "$supplement" \
          ".cursor/rules/mtk-${stack}-${rule_name}.mdc" \
          "$stack — $section_name"
      fi
    done
  fi

  # Domain supplements (always-apply)
  for domain_file in "$REFS_DIR"/domain-*.md; do
    [ -f "$domain_file" ] || continue
    local domain_name display_domain
    domain_name="$(basename "$domain_file" | sed 's/^domain-//' | sed 's/\.md$//')"
    display_domain="$(echo "$domain_name" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
    write_mdc "$domain_file" \
      ".cursor/rules/mtk-domain-${domain_name}.mdc" \
      "$display_domain domain rules"
  done

  local count
  count=$(find .cursor/rules -name "mtk-*.mdc" 2>/dev/null | wc -l | tr -d ' ')
  echo "Generated $count Cursor rule files in .cursor/rules/"
}

# ─── Format: Single-file generators ───────────────────────────────────────────

generate_single_file() {
  local format="$1" output="$2" title="$3"
  {
    printf '# %s\n\n' "$title"
    printf '> Auto-generated by MTK. Regenerate with: `bash scripts/generate-tool-configs.sh --format %s`\n\n' "$format"
    assemble_all_content
  } | collapse_blank_lines > "$output"
  local lines
  lines=$(wc -l < "$output" | tr -d ' ')
  echo "Generated $output ($lines lines)"
}

generate_copilot() {
  mkdir -p .github
  generate_single_file "copilot" ".github/copilot-instructions.md" "Copilot Instructions"
}

generate_windsurf() {
  generate_single_file "windsurf" ".windsurfrules" "Windsurf Rules"
}

generate_gemini() {
  generate_single_file "gemini" "GEMINI.md" "Project Guidelines"
}

generate_cline() {
  generate_single_file "cline" ".clinerules" "Project Rules"
}

# ─── CLI ───────────────────────────────────────────────────────────────────────

usage() {
  echo "Usage: $0 [--all | --format <cursor-rules|copilot|windsurf|gemini|cline> ...]" >&2
  exit 1
}

formats=()
while [ $# -gt 0 ]; do
  case "$1" in
    --all)          formats=(cursor-rules copilot windsurf gemini cline); shift ;;
    --format)       [ $# -ge 2 ] || usage; formats+=("$2"); shift 2 ;;
    -h|--help)      usage ;;
    *)              usage ;;
  esac
done

[ ${#formats[@]} -eq 0 ] && usage

for fmt in "${formats[@]}"; do
  case "$fmt" in
    cursor-rules) generate_cursor_rules ;;
    copilot)      generate_copilot ;;
    windsurf)     generate_windsurf ;;
    gemini)       generate_gemini ;;
    cline)        generate_cline ;;
    *)            echo "Unknown format: $fmt" >&2; exit 1 ;;
  esac
done
