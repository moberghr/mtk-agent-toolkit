#!/usr/bin/env bash
# mtk doctor — health check across MTK installation.
# Reports PASS/WARN/FAIL across categories. Exits 0 unless --strict and any WARN/FAIL,
# or any FAIL otherwise.
set -euo pipefail

# The project being diagnosed is where the doctor was INVOKED, which in a plugin
# install is not the script's own tree. Capture it before the cd below.
DOCTOR_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
DOCTOR_PROJECT_DIR="$(cd "$DOCTOR_PROJECT_DIR" 2>/dev/null && pwd)" || DOCTOR_PROJECT_DIR="$PWD"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Two trees, two kinds of check. Toolkit checks (manifest, skills, agents, hook
# scripts, checksums, validate-toolkit) describe the MTK install and run from
# ROOT_DIR. Project checks (constitution, settings.json permissions and hooks,
# .gitignore, lessons, context baseline, env calibration, tech stack) describe the
# repo the doctor was run for and run from DOCTOR_PROJECT_DIR. In this dev
# checkout the two are the same directory; in a plugin install they are not, and
# running project checks from ROOT_DIR measured the plugin's own AGENTS.md and
# settings instead of the repo's. Each section below switches explicitly.
in_toolkit() { cd "$ROOT_DIR"; }
in_project() { cd "$DOCTOR_PROJECT_DIR"; }
in_toolkit

# Args
JSON=0
FIX=0
STRICT=0
for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    --fix) FIX=1 ;;
    --strict) STRICT=1 ;;
    -h|--help)
      cat <<USAGE
Usage: mtk-doctor [--json] [--fix] [--strict]

  --json    Machine-readable output for CI dashboards
  --fix     Auto-fix safe items: gitignore additions, chmod +x, and moving the
            invalid permissions.allowedTools key into permissions.allow. Any
            other FAIL is reported, never auto-fixed.
  --strict  Exit non-zero on WARN as well as FAIL
USAGE
      exit 0
      ;;
    *) printf 'Unknown flag: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# Deprecated or retired model IDs (prefix match on an agent's `model:` value) —
# update when Anthropic deprecates more. Source: the Anthropic models overview
# (deprecated: Opus 4 / 4.1, Sonnet 4, Haiku 3; every other 3.x and 2.x model is
# retired). Opus 4.5-4.8, Sonnet 4.5/4.6 and Haiku 4.5 are previous-generation
# but still served, so they are listed as superseded (WARN), not deprecated (FAIL).
# Note: agents pin aliases (model: opus|sonnet|haiku|fable), not version IDs. On the
# Anthropic API an alias resolves to the latest in its family (opus -> Opus 5.5,
# sonnet -> Sonnet 5.5, haiku -> Haiku 5.5, fable -> Fable 5.1; see
# .claude/references/model-routing.md "Provider tier slots"). On Bedrock, Google
# Cloud, Foundry and Claude Platform on AWS the same alias may resolve to an OLDER
# version (haiku -> Haiku 4.5, sonnet -> Sonnet 4.5/4.6); pin
# ANTHROPIC_DEFAULT_OPUS_MODEL / _SONNET_MODEL / _HAIKU_MODEL to a full ID there.
DEPRECATED_MODELS=(
  "claude-3-"
  "claude-3.5-"
  "claude-2"
  "claude-instant"
  "claude-opus-4-0"
  "claude-opus-4-1"
  "claude-opus-4-2025"
  "claude-sonnet-4-0"
  "claude-sonnet-4-2025"
)
SUPERSEDED_MODELS=(
  "claude-opus-4-5"
  "claude-opus-4-6"
  "claude-opus-4-7"
  "claude-opus-4-8"
  "claude-sonnet-4-5"
  "claude-sonnet-4-6"
  "claude-haiku-4-5"
)

# Result aggregation
RESULTS=()       # tab-separated: status\tcategory\tname\tdetail
PASS=0; WARN=0; FAIL=0

record() {
  local status="$1" cat="$2" name="$3" detail="${4:-}"
  RESULTS+=("$(printf '%s\t%s\t%s\t%s' "$status" "$cat" "$name" "$detail")")
  case "$status" in
    PASS) PASS=$((PASS + 1)) ;;
    WARN) WARN=$((WARN + 1)) ;;
    FAIL) FAIL=$((FAIL + 1)) ;;
  esac
}

# ──────────────────────────────────────────────
# CORE FILES
# ──────────────────────────────────────────────
# Resolve manifest location: target-repo installs no longer ship .claude/manifest.json,
# so fall back to the plugin root if a project-local copy is absent.
if [ -f ".claude/manifest.json" ]; then
  DOCTOR_MANIFEST=".claude/manifest.json"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/.claude/manifest.json" ]; then
  DOCTOR_MANIFEST="${CLAUDE_PLUGIN_ROOT}/.claude/manifest.json"
else
  DOCTOR_MANIFEST=""
fi

for f in .claude-plugin/plugin.json README.md AGENTS.md scripts/validate-toolkit.sh; do
  if [ -f "$f" ]; then
    record PASS core "$f present"
  else
    record FAIL core "$f missing" "required by toolkit baseline"
  fi
done

if [ -n "$DOCTOR_MANIFEST" ]; then
  record PASS core "manifest.json located" "$DOCTOR_MANIFEST"
else
  record FAIL core "manifest.json missing" "set CLAUDE_PLUGIN_ROOT or run from a plugin clone"
fi

# Target-repo provenance file (single source of truth for installed version).
in_project
if [ -f ".claude/mtk-version.json" ]; then
  record PASS core ".claude/mtk-version.json present"
fi

# Budget the RESOLVED constitution, not a fixed filename. Post-inversion the
# constitution is AGENTS.md and CLAUDE.md is an ~11-line shim, so checking
# CLAUDE.md unconditionally passes vacuously and the file that actually costs
# always-on context is never measured. Resolution matches constitution_file()
# in constitution-digest.sh: AGENTS.md wins when it exists, is not
# generator-marked, and CLAUDE.md is absent, the same file, or a shim.
_RC_BUD="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/resolve-constitution.sh"
[ -f "$_RC_BUD" ] || _RC_BUD="${CLAUDE_PLUGIN_ROOT:-.}/scripts/resolve-constitution.sh"
DOCTOR_CONST=""
if [ -f "$_RC_BUD" ]; then
  DOCTOR_CONST="$(bash "$_RC_BUD" 2>/dev/null || true)"
elif [ -f AGENTS.md ] && { [ ! -f CLAUDE.md ] || [ CLAUDE.md -ef AGENTS.md ] || grep -q '^@AGENTS\.md' CLAUDE.md 2>/dev/null; }; then
  DOCTOR_CONST="AGENTS.md"
elif [ -f CLAUDE.md ]; then
  DOCTOR_CONST="CLAUDE.md"
fi
# The resolver answers "which file", not "is there one".
[ -n "$DOCTOR_CONST" ] && [ -f "$DOCTOR_CONST" ] || DOCTOR_CONST=""

if [ -n "$DOCTOR_CONST" ] && [ -f "$DOCTOR_CONST" ]; then
  # 120 is the hard cap the template, setup-bootstrap and validate-toolkit.sh all
  # state (target 60-80). Doctor WARNs rather than FAILs: a target repo may carry
  # a large legacy constitution it has not split yet.
  CONST_LINES="$(wc -l < "$DOCTOR_CONST" | tr -d '[:space:]')"
  if [ "$CONST_LINES" -le 120 ]; then
    record PASS core "$DOCTOR_CONST within 120-line budget" "${CONST_LINES} lines"
  else
    record WARN core "$DOCTOR_CONST exceeds 120-line budget" "${CONST_LINES} lines (target 60-80) — consider splitting into .claude/rules/ or .claude/references/"
  fi
fi

# Both AGENTS.md and CLAUDE.md present, but CLAUDE.md is not wired as a shim
# importing AGENTS.md (no `^@AGENTS\.md` line): in Claude Code's default
# `claude-md-or-agents-md` mode, a CLAUDE.md in cwd or above suppresses
# AGENTS.md entirely, so the constitution is simply not read. WARN, never
# FAIL: a legacy repo with only CLAUDE.md has nothing to compare, and a repo
# with only AGENTS.md is already unambiguous.
#
# Exempt a generator-marked AGENTS.md (the string `Auto-generated by MTK` within
# its first 10 lines — the marker generate-agents-md.sh / generate-tool-configs.sh
# stamp into what they write). That file is the legacy references SUMMARY, not a
# constitution: it is the correct pre-inversion shape beside a real CLAUDE.md, and
# advising a shim there would promote a pointer file over the governing rules.
# Same marker clause as constitution-digest.sh's constitution_file(); matched on a
# captured variable rather than through a pipe into `grep -q` (S3.17).
if [ -f AGENTS.md ] && [ -f CLAUDE.md ]; then
  DOCTOR_AGENTS_HEAD10="$(awk 'NR<=10' AGENTS.md 2>/dev/null || true)"
  DOCTOR_AGENTS_MARKED=0
  case "$DOCTOR_AGENTS_HEAD10" in *"Auto-generated by MTK"*) DOCTOR_AGENTS_MARKED=1 ;; esac
  if [ "$DOCTOR_AGENTS_MARKED" -eq 0 ] && ! grep -q '^@AGENTS\.md' CLAUDE.md 2>/dev/null; then
    record WARN core "CLAUDE.md does not import AGENTS.md" \
      "both files exist and CLAUDE.md does not import AGENTS.md — the default claude-md-or-agents-md mode reads CLAUDE.md only and ignores AGENTS.md entirely; add a bare @AGENTS.md line to make it an explicit shim"
  fi
fi

# ──────────────────────────────────────────────
# COMPONENTS
# ──────────────────────────────────────────────
in_toolkit
# Manifest version sync
MANIFEST_VERSION=""
if [ -n "$DOCTOR_MANIFEST" ]; then
  MANIFEST_VERSION="$(grep -o '"version": *"[^"]*"' "$DOCTOR_MANIFEST" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')"
fi
# Read the plugin version only if the descriptor is there. Unguarded, this grep
# exits 2 under `set -e` and takes the whole run with it, so a repo without
# .claude-plugin/plugin.json got a raw `grep: ... No such file` and exit 2
# instead of the "plugin.json missing" FAIL already recorded above — the doctor
# could not diagnose the one thing it had just detected.
PLUGIN_VERSION=""
if [ -f .claude-plugin/plugin.json ]; then
  PLUGIN_VERSION="$(grep -o '"version": *"[^"]*"' .claude-plugin/plugin.json | head -1 | sed 's/.*"\([^"]*\)".*/\1/')"
fi
if [ -z "$MANIFEST_VERSION" ] && [ -z "$PLUGIN_VERSION" ]; then
  record WARN components "version sync unknown" "neither manifest.json nor .claude-plugin/plugin.json is readable here — nothing to compare"
elif [ "$MANIFEST_VERSION" = "$PLUGIN_VERSION" ] && [ -n "$MANIFEST_VERSION" ]; then
  record PASS components "version sync" "$MANIFEST_VERSION"
else
  record FAIL components "version mismatch" "manifest=${MANIFEST_VERSION:-?} plugin=${PLUGIN_VERSION:-?}"
fi

# Skill count vs disk. `find` on a missing .claude/skills exits non-zero and
# pipefail carries that out of the command substitution — the second way this
# run died before reporting anything.
if [ -d .claude/skills ]; then
  SKILL_DIRS=$(find .claude/skills -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d '[:space:]')
  record PASS components "skills on disk" "${SKILL_DIRS} directories"
else
  record WARN components "no .claude/skills directory" "skills resolve from the plugin root in a plugin install — set CLAUDE_PLUGIN_ROOT to check them"
fi

# Skill name matches directory (S1.12 / C0.3)
SKILL_NAME_MISMATCHES=()
while IFS= read -r skill_md; do
  dir_name="$(basename "$(dirname "$skill_md")")"
  fm_name="$(grep -m1 '^name:' "$skill_md" 2>/dev/null | sed 's/^name:[[:space:]]*//')"
  if [ -n "$fm_name" ] && [ "$fm_name" != "$dir_name" ]; then
    SKILL_NAME_MISMATCHES+=("$dir_name vs name: $fm_name")
  fi
done < <(find .claude/skills -name SKILL.md -mindepth 2 -maxdepth 3 2>/dev/null)

if [ "${#SKILL_NAME_MISMATCHES[@]}" -eq 0 ]; then
  record PASS components "skill name/dir match" "all skills consistent"
else
  for m in "${SKILL_NAME_MISMATCHES[@]}"; do
    record FAIL components "skill name mismatch" "$m"
  done
fi

# Deprecated models in agent frontmatter
DEPRECATED_HITS=()
SUPERSEDED_HITS=()
while IFS= read -r agent_md; do
  agent_model="$(awk '/^model:/ { sub(/^model:[[:space:]]*/, ""); print; exit }' "$agent_md" 2>/dev/null || true)"
  [ -n "$agent_model" ] || continue
  for model in "${DEPRECATED_MODELS[@]}"; do
    case "$agent_model" in "$model"*) DEPRECATED_HITS+=("$agent_md → $agent_model") ;; esac
  done
  for model in "${SUPERSEDED_MODELS[@]}"; do
    case "$agent_model" in "$model"*) SUPERSEDED_HITS+=("$agent_md → $agent_model") ;; esac
  done
done < <(find .claude/agents -name '*.md' -type f 2>/dev/null)
for h in "${SUPERSEDED_HITS[@]+"${SUPERSEDED_HITS[@]}"}"; do
  record WARN components "previous-generation model pinned" "$h — still served, but the alias (opus|sonnet|haiku|fable) follows the current generation"
done

if [ "${#DEPRECATED_HITS[@]}" -eq 0 ]; then
  record PASS components "no deprecated model IDs" "checked ${#DEPRECATED_MODELS[@]} known-deprecated IDs; aliases resolve to latest on Anthropic API — pin ANTHROPIC_DEFAULT_*_MODEL on Bedrock/Vertex"
else
  for h in "${DEPRECATED_HITS[@]}"; do
    record FAIL components "deprecated model" "$h"
  done
fi

# ──────────────────────────────────────────────
# HOOKS
# ──────────────────────────────────────────────
# All registered hook scripts in the PROJECT's .claude/settings.json must exist
# and be executable.
in_project
# The documented Claude Code hook events (code.claude.com/docs/en/hooks, checked
# Oct 2026). A key outside this list never fires, so a typo is a dead hook.
KNOWN_EVENTS="SessionStart Setup UserPromptSubmit UserPromptExpansion PreToolUse PermissionRequest PermissionDenied PostToolUse PostToolUseFailure PostToolBatch Notification MessageDisplay SubagentStart SubagentStop TaskCreated TaskCompleted Stop StopFailure TeammateIdle InstructionsLoaded ConfigChange CwdChanged DirectoryAdded FileChanged WorktreeCreate WorktreeRemove PreCompact PostCompact PreModelSwitch PostModelSwitch Elicitation ElicitationResult SessionEnd"

while IFS= read -r line; do
  cmd="$(printf '%s' "$line" | sed 's/^.*"command": *"//; s/".*$//')"
  # Strip $ARGUMENTS and similar suffixes
  script="$(printf '%s' "$cmd" | awk '{print $1}')"
  # `bash $CLAUDE_PLUGIN_ROOT/hooks/x.sh` is the form setup-bootstrap writes into
  # target repos, so the first token is the interpreter, not the hook. Take the
  # next one. (Before the grep below was widened, those lines never matched at
  # all, so this only shows up now.)
  case "$script" in
    bash|sh|zsh|python3|python|node) script="$(printf '%s' "$cmd" | awk '{print $2}')" ;;
  esac
  [ -z "$script" ] && continue
  # Hook commands are anchored on $CLAUDE_PROJECT_DIR here and on
  # $CLAUDE_PLUGIN_ROOT in plugin-installed repos; resolve both so the existence
  # and +x checks below run against a real path.
  script="${script//\$CLAUDE_PROJECT_DIR/$DOCTOR_PROJECT_DIR}"
  script="${script//\$\{CLAUDE_PROJECT_DIR\}/$DOCTOR_PROJECT_DIR}"
  # $CLAUDE_PLUGIN_ROOT is only authoritative when the environment supplies it.
  # This checkout is a reasonable guess otherwise — but remember it was a guess,
  # because "I guessed and missed" must not be reported as "the hook is missing".
  plugin_guessed=0
  case "$script" in
    *'$CLAUDE_PLUGIN_ROOT'*|*'${CLAUDE_PLUGIN_ROOT}'*)
      [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || plugin_guessed=1 ;;
  esac
  DOCTOR_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$ROOT_DIR}"
  script="${script//\$CLAUDE_PLUGIN_ROOT/$DOCTOR_PLUGIN_ROOT}"
  script="${script//\$\{CLAUDE_PLUGIN_ROOT\}/$DOCTOR_PLUGIN_ROOT}"
  # A variable this script cannot resolve is not evidence the hook is missing.
  # Say so instead of reporting a FAIL the reader has no way to act on.
  case "$script" in
    *'$'*) record WARN hooks "hook path has an unresolved variable" "$cmd"; continue ;;
  esac
  case "$script" in /*) ;; *) script="$DOCTOR_PROJECT_DIR/$script" ;; esac
  if [ ! -f "$script" ]; then
    if [ "$plugin_guessed" -eq 1 ]; then
      record WARN hooks "hook path unresolvable" "$cmd — \$CLAUDE_PLUGIN_ROOT is unset and the hook is not under $ROOT_DIR either; set it to check plugin-installed hooks"
    else
      record FAIL hooks "registered hook missing" "$cmd"
    fi
  elif [ ! -x "$script" ]; then
    if [ "$FIX" -eq 1 ]; then
      chmod +x "$script" && record PASS hooks "hook fixed (chmod +x)" "$cmd"
    else
      record WARN hooks "hook not executable" "$cmd — run with --fix"
    fi
  fi
done < <(grep -E '"command": *"[^"]*hooks/' .claude/settings.json 2>/dev/null || true)

# Check that hook event names are valid: the keys of the `hooks` object only, so
# a capitalised key elsewhere in the file is not mistaken for an event.
HOOK_EVENT_NAMES=""
if [ -f .claude/settings.json ] && command -v python3 >/dev/null 2>&1; then
  HOOK_EVENT_NAMES="$(python3 - .claude/settings.json <<'PY' 2>/dev/null || true
import sys; sys.stdout.reconfigure(newline="\n")  # LF even on Windows python3: bash parses this output
import json
hooks = json.load(open(sys.argv[1])).get("hooks", {})
for k in sorted(hooks if isinstance(hooks, dict) else {}):
    print(k)
PY
)"
fi
while IFS= read -r event; do
  [ -n "$event" ] || continue
  case " $KNOWN_EVENTS " in
    *" $event "*) ;;
    *) record WARN hooks "unknown hook event" "$event" ;;
  esac
done <<< "$HOOK_EVENT_NAMES"

SETTINGS_PARSE_OK=1
if [ -f .claude/settings.json ] && command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' .claude/settings.json >/dev/null 2>&1 || SETTINGS_PARSE_OK=0
fi
if [ "$SETTINGS_PARSE_OK" -eq 1 ]; then
  record PASS hooks "settings.json hook block validated"
else
  record FAIL hooks ".claude/settings.json is not valid JSON" "Claude Code cannot load it, so none of its hooks, permissions or env apply — fix the syntax (python3 -m json.tool .claude/settings.json shows where)"
fi

# Claude Code's permission keys are permissions.allow / deny / ask. There is no
# permissions.allowedTools (that is the --allowedTools CLI flag), so a list
# written under it is silently ignored and every command it meant to allow still
# prompts. Earlier setup-bootstrap runs wrote exactly that key. --fix migrates it.
DOCTOR_MIGRATE="$ROOT_DIR/scripts/migrate-settings-permissions.sh"
[ -f "$DOCTOR_MIGRATE" ] || DOCTOR_MIGRATE="${CLAUDE_PLUGIN_ROOT:-.}/scripts/migrate-settings-permissions.sh"
# The migration moves only narrow build/test/lint entries (they were never in
# effect, so moving a broad one would silently switch it on). Exit codes of
# --check: 0 nothing convertible (inert leftovers are listed), 1 convertible
# entries remain, 2 cannot check. Only 1 is "uses allowedTools".
for sf in .claude/settings.json .claude/settings.local.json; do
  [ -f "$sf" ] || continue
  grep -q '"allowedTools"' "$sf" 2>/dev/null || continue
  if [ ! -f "$DOCTOR_MIGRATE" ]; then
    record WARN permissions "$sf: allowedTools not checked" "migrate-settings-permissions.sh not found (looked in $ROOT_DIR/scripts and \${CLAUDE_PLUGIN_ROOT}/scripts)"
    continue
  fi
  mig_rc=0
  mig_out="$(bash "$DOCTOR_MIGRATE" --check "$sf" 2>&1)" || mig_rc=$?
  if [ "$mig_rc" -eq 1 ] && [ "$FIX" -eq 1 ]; then
    fix_rc=0
    fix_out="$(bash "$DOCTOR_MIGRATE" "$sf" 2>&1)" || fix_rc=$?
    if [ "$fix_rc" -eq 0 ]; then
      record PASS permissions "$sf migrated" "$(grep -c '^activated: ' <<<"$fix_out" || true) narrow permissions.allowedTools entr(y/ies) activated in permissions.allow: $(grep '^activated: ' <<<"$fix_out" | sed 's/^activated: [^:]*: //' | tr '\n' ' ')"
      mig_rc=0
      mig_out="$fix_out"
    else
      record FAIL permissions "$sf migration failed" "migrate-settings-permissions.sh exited $fix_rc: $(awk 'NR==1' <<<"$fix_out")"
      continue
    fi
  fi
  case "$mig_rc" in
    0) ;;
    1) record FAIL permissions "$sf uses permissions.allowedTools" "Claude Code ignores that key, so these narrow entries never apply: $(grep '^convertible: ' <<<"$mig_out" | sed 's/^convertible: [^:]*: //' | tr '\n' ' ')— run with --fix, or: bash \${CLAUDE_PLUGIN_ROOT}/scripts/migrate-settings-permissions.sh $sf"
       continue ;;
    *) record WARN permissions "$sf: allowedTools check failed" "migrate-settings-permissions.sh --check exited $mig_rc: $(awk 'NR==1' <<<"$mig_out")"
       continue ;;
  esac
  inert="$(grep 'needs a manual decision' <<<"$mig_out" | sed -E 's/^left inert: [^:]*: (.*) needs a manual decision.*/\1/' | tr '\n' ' ' || true)"
  if [ -n "$inert" ]; then
    record WARN permissions "$sf has inert broad permissions.allowedTools entries" "never in effect and not migrated automatically: ${inert}— move each to permissions.allow only if you want it on, then delete permissions.allowedTools"
  fi
done

# All shell scripts in hooks/ must have set -euo pipefail (S3.1)
in_toolkit
PIPEFAIL_MISSING=()
while IFS= read -r sh; do
  if ! head -15 "$sh" | grep -q 'set -euo pipefail'; then
    PIPEFAIL_MISSING+=("$sh")
  fi
done < <(find hooks/ -type f -name '*.sh' 2>/dev/null)

if [ "${#PIPEFAIL_MISSING[@]}" -eq 0 ]; then
  record PASS hooks "all hooks use 'set -euo pipefail'"
else
  for s in "${PIPEFAIL_MISSING[@]}"; do
    record FAIL hooks "missing pipefail" "$s — violates S3.1"
  done
fi

# ──────────────────────────────────────────────
# INTEGRITY
# ──────────────────────────────────────────────
# Manifest paths exist on disk (sample check — full check is in validate-toolkit.sh)
MISSING_PATHS=()
SAMPLED_PATHS=0
# `source` paths are relative to the tree the manifest describes, which is not
# necessarily the cwd: when the manifest resolves to $CLAUDE_PLUGIN_ROOT, every
# path belongs to the plugin, and checking it against the project reports the
# whole toolkit as missing.
DOCTOR_MANIFEST_ROOT="$ROOT_DIR"
if [ -n "$DOCTOR_MANIFEST" ]; then
  DOCTOR_MANIFEST_ROOT="$(cd "$(dirname "$DOCTOR_MANIFEST")/.." 2>/dev/null && pwd)" || DOCTOR_MANIFEST_ROOT="$ROOT_DIR"
fi
while IFS= read -r src; do
  SAMPLED_PATHS=$((SAMPLED_PATHS + 1))
  [ -e "${DOCTOR_MANIFEST_ROOT}/${src}" ] || MISSING_PATHS+=("$src")
done < <(grep -oE '"source": *"[^"]+"' "${DOCTOR_MANIFEST:-/dev/null}" 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/' | sort -u | head -50)

if [ "$SAMPLED_PATHS" -eq 0 ]; then
  # Zero paths checked is not zero paths missing. Without a manifest this check
  # has nothing to say, and saying "present" would be a green light nobody earned.
  record WARN integrity "manifest paths unchecked" "no manifest resolved — 0 paths sampled"
elif [ "${#MISSING_PATHS[@]}" -eq 0 ]; then
  record PASS integrity "manifest paths present" "sampled ${SAMPLED_PATHS}"
else
  for p in "${MISSING_PATHS[@]}"; do
    record FAIL integrity "manifest path missing" "$p"
  done
fi

# ──────────────────────────────────────────────
# Runtime-referenced MTK files resolve somewhere along the documented order
# (.claude/references/mtk-file-resolution.md): MTK_HELPER_ROOT → CLAUDE_PLUGIN_ROOT
# → this tree → the project → newest plugin-cache copy. Skills name these files
# by path mid-run; a 2026-09 field run discovered four of them missing
# only when a phase tried to read them, and its scripts' inline resolvers
# (`${CLAUDE_PLUGIN_ROOT:-.}/scripts/…`) never look in the plugin cache at all.
# FAIL when a file resolves nowhere; WARN when it resolves ONLY by cache search,
# because then every inline resolver in the skills still misses it.
REFERENCED_FILES=(
  .claude/references/security-checklist.md
  .claude/references/testing-patterns.md
  .claude/references/performance-checklist.md
  .claude/references/mtk-file-resolution.md
  .claude/review-config.json
  .claude/schemas/handoff.schema.json
  scripts/learnings.sh
  scripts/constitution-digest.sh
  scripts/workflow-artifact.sh
  scripts/build-context-pack.sh
  scripts/resolve-tech-stack.sh
  scripts/mtk-verify-run.sh
)
CACHE_ROOT=""
# `tail -1` consumes all input, so this pipe is SIGPIPE-safe under pipefail (S3.17).
CACHE_PROBE="$(find "${HOME:-/nonexistent}/.claude/plugins" -maxdepth 8 -name "SKILL.md" -path "*/mtk/*/context-engineering/*" -type f 2>/dev/null | sort -V | tail -1 || true)"
[ -n "$CACHE_PROBE" ] && CACHE_ROOT="${CACHE_PROBE%/.claude/skills/context-engineering/SKILL.md}"
REF_UNRESOLVED=(); REF_CACHE_ONLY=0; REF_VIA=""
for rf in "${REFERENCED_FILES[@]}"; do
  via=""
  for cand_label in "MTK_HELPER_ROOT:${MTK_HELPER_ROOT:-}" "CLAUDE_PLUGIN_ROOT:${CLAUDE_PLUGIN_ROOT:-}" "install:${ROOT_DIR}" "project:${DOCTOR_PROJECT_DIR}" "plugin-cache:${CACHE_ROOT}"; do
    cand="${cand_label#*:}"; label="${cand_label%%:*}"
    [ -n "$cand" ] && [ -f "$cand/$rf" ] && { via="$label"; break; }
  done
  if [ -z "$via" ]; then
    REF_UNRESOLVED+=("$rf")
  else
    [ "$via" = "plugin-cache" ] && REF_CACHE_ONLY=$((REF_CACHE_ONLY + 1))
    [ -n "$REF_VIA" ] || REF_VIA="$via"
  fi
done
if [ "${#REF_UNRESOLVED[@]}" -gt 0 ]; then
  for rf in "${REF_UNRESOLVED[@]}"; do
    record FAIL integrity "referenced file unresolvable" "$rf — not under MTK_HELPER_ROOT, CLAUDE_PLUGIN_ROOT, $ROOT_DIR, $DOCTOR_PROJECT_DIR, or any plugin-cache copy; set MTK_HELPER_ROOT to a claude-helpers checkout or reinstall the mtk plugin"
  done
elif [ "$REF_CACHE_ONLY" -gt 0 ]; then
  record WARN integrity "referenced files resolve only via plugin-cache search" "${REF_CACHE_ONLY} of ${#REFERENCED_FILES[@]} found under $CACHE_ROOT but neither MTK_HELPER_ROOT nor CLAUDE_PLUGIN_ROOT is set — inline script resolvers will miss them; set MTK_HELPER_ROOT=$CACHE_ROOT in .claude/settings.local.json env or the shell"
else
  record PASS integrity "runtime-referenced files resolve" "${#REFERENCED_FILES[@]} files via $REF_VIA"
fi

# .gitignore coverage
in_project
GITIGNORE_MISSING=()
GITIGNORE_REQUIRED=(
  ".claude/settings.local.json"
  ".claude/observability/"
)
for entry in "${GITIGNORE_REQUIRED[@]}"; do
  if ! grep -qF "$entry" .gitignore 2>/dev/null; then
    GITIGNORE_MISSING+=("$entry")
  fi
done

if [ "${#GITIGNORE_MISSING[@]}" -eq 0 ]; then
  record PASS integrity ".gitignore covers expected paths"
else
  for g in "${GITIGNORE_MISSING[@]}"; do
    if [ "$FIX" -eq 1 ]; then
      printf '%s\n' "$g" >> .gitignore
      record PASS integrity ".gitignore fixed" "added $g"
    else
      record WARN integrity ".gitignore missing entry" "$g — run with --fix"
    fi
  done
fi

# Rule enforcement map — which rules are load-bearing and which are hope.
in_toolkit
# WARN on broken refs (a rule naming an enforcer that does not exist reads as
# enforced and is not) and on undocumented hooks (an enforcer nothing
# documents is the same drift from the other side).
if [ -f scripts/rule-enforcement-map.sh ] && [ -d .claude/rules ]; then
  MAP_SUMMARY="$(bash scripts/rule-enforcement-map.sh --quiet 2>/dev/null | tail -1 || true)"
  case "$MAP_SUMMARY" in
    *' 0 broken ref(s)'*)
      record PASS integrity "rule enforcement refs live" "$MAP_SUMMARY" ;;
    *broken*)
      record WARN integrity "broken rule-enforcement refs" "$MAP_SUMMARY — run 'bash scripts/rule-enforcement-map.sh' for the per-rule verdicts" ;;
    *)
      record PASS integrity "rule enforcement unchecked" "no summary from rule-enforcement-map.sh" ;;
  esac
  case "$MAP_SUMMARY" in
    *' 0 undocumented'*) : ;;
    *undocumented*)
      record WARN integrity "undocumented enforcer hooks" "$MAP_SUMMARY — hooks no rule documents; document or justify in .claude/rules/" ;;
  esac
fi

# Lesson anchor staleness — a lesson citing a path/symbol that no longer
# exists reads as authority while pointing at nothing. WARN-only; retirement
# is the lesson-refresh skill's job and always a human decision.
if [ -f tasks/lessons.md ] && [ -f scripts/lesson-anchors.sh ]; then
  ANCHOR_SUMMARY="$(bash scripts/lesson-anchors.sh 2>/dev/null | tail -1 || true)"
  case "$ANCHOR_SUMMARY" in
    *' 0 stale'*) record PASS integrity "lesson anchors live" "$ANCHOR_SUMMARY" ;;
    *stale*)      record WARN integrity "stale lesson anchors" "$ANCHOR_SUMMARY — run 'bash scripts/lesson-anchors.sh' for locations, then the lesson-refresh skill to triage" ;;
    *)            record PASS integrity "lesson anchors unchecked" "no summary from lesson-anchors.sh" ;;
  esac
fi

# Analytics freshness
in_project
if [ -f .claude/analytics.json ]; then
  if find .claude/analytics.json -mtime +30 -print -quit 2>/dev/null | grep -q .; then
    record WARN integrity "analytics.json stale" "older than 30 days — toolkit may be unused"
  else
    record PASS integrity "analytics.json fresh"
  fi
else
  record PASS integrity "analytics.json absent" "first session will create"
fi

# Release checksum manifest (optional) — installed bytes match the release.
in_toolkit
if [ -f checksums.sha256 ] && [ -f scripts/generate-checksums.sh ]; then
  CHECKSUM_LINE="$(bash scripts/generate-checksums.sh --verify --quiet 2>/dev/null | grep '^checksums:' | tail -1 || true)"
  if printf '%s' "$CHECKSUM_LINE" | grep -q ' 0 mismatched, 0 missing'; then
    record PASS integrity "release checksums verified" "$CHECKSUM_LINE"
  else
    record WARN integrity "release checksum drift" "${CHECKSUM_LINE:-verification failed} — expected with local changes; on a clean install this means the bytes are not the released bytes"
  fi
else
  record PASS integrity "release checksum manifest absent" "generate at release: bash scripts/generate-checksums.sh"
fi

# Release signature (optional, advisory knob) — proves WHO published, not just that
# bytes are unmodified. Absence of the whole feature is never a hard FAIL (opt-in
# supply-chain hardening), but once a public key IS configured, a missing .sig is a
# WARN (a stripped signature must not silently downgrade to "not configured"), and
# tool problems (no openssl, LibreSSL without Ed25519 support, unreadable key) are
# reported as "uncheckable" — only a genuine verify failure is a tamper FAIL.
if [ -n "${MTK_RELEASE_PUBLIC_KEY:-}" ] || [ -f checksums.sha256.sig ]; then
  if [ -z "${MTK_RELEASE_PUBLIC_KEY:-}" ]; then
    record PASS integrity "release signing not configured" "checksums.sha256.sig present — set MTK_RELEASE_PUBLIC_KEY to verify it"
  elif [ ! -f checksums.sha256.sig ]; then
    record WARN integrity "release signature missing" "MTK_RELEASE_PUBLIC_KEY is set but checksums.sha256.sig is absent — unsigned release or stripped signature"
  elif [ ! -f checksums.sha256 ]; then
    record WARN integrity "release signature uncheckable" "checksums.sha256.sig present but checksums.sha256 is missing"
  elif [ ! -r "$MTK_RELEASE_PUBLIC_KEY" ]; then
    record WARN integrity "release signature uncheckable" "MTK_RELEASE_PUBLIC_KEY does not point at a readable file: $MTK_RELEASE_PUBLIC_KEY"
  elif ! command -v openssl >/dev/null 2>&1; then
    record WARN integrity "release signature uncheckable" "checksums.sha256.sig present but openssl not found"
  elif ! openssl pkeyutl -help 2>&1 | grep -q -- '-rawin'; then
    record WARN integrity "release signature uncheckable" "openssl lacks pkeyutl -rawin (stock macOS LibreSSL) — install OpenSSL 3+ to verify Ed25519 signatures"
  elif openssl pkeyutl -verify -pubin -inkey "$MTK_RELEASE_PUBLIC_KEY" -rawin -in checksums.sha256 -sigfile checksums.sha256.sig >/dev/null 2>&1; then
    record PASS integrity "release signature verified" "checksums.sha256 signed by MTK_RELEASE_PUBLIC_KEY"
  else
    record FAIL integrity "release signature invalid" "checksums.sha256.sig does not verify against MTK_RELEASE_PUBLIC_KEY — bytes may be tampered or key mismatched"
  fi
else
  record PASS integrity "release signing not configured" "set MTK_RELEASE_PUBLIC_KEY and ship checksums.sha256.sig to enable"
fi

# Run validate-toolkit as one composite check
if bash scripts/validate-toolkit.sh >/dev/null 2>&1; then
  record PASS integrity "validate-toolkit passes"
else
  record FAIL integrity "validate-toolkit fails" "run: bash scripts/validate-toolkit.sh"
fi

# ──────────────────────────────────────────────
# LESSONS
# ──────────────────────────────────────────────
# Executable lesson-contract well-formedness (v7.25). Optional feature — a lesson
# with no contract fields is fine, and malformed contracts are WARN (never FAIL),
# so the check never blocks a repo that doesn't use contracts. See
# .claude/references/learnings-schema.md → Executable lesson contract.
in_project
LEARN_FILE=".mtk/learnings.jsonl"
if [ -f "$LEARN_FILE" ] && command -v python3 >/dev/null 2>&1; then
  LINT_OUT="$(python3 - "$LEARN_FILE" <<'PY'
import sys; sys.stdout.reconfigure(newline="\n")  # LF even on Windows python3: bash parses this output
import json, sys
checked = 0
issues = []
with open(sys.argv[1]) as f:
    for n, line in enumerate(f, 1):
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            issues.append("line %d: unparseable JSON in learnings store (corrupt entry)" % n)
            continue
        if not any(k in e for k in ("confidence", "output_contract",
                                    "prefinal_verification_checklist", "source_evidence_refs")):
            continue
        checked += 1
        lid = e.get("id", "line%d" % n)
        c = e.get("confidence")
        if c is not None and c not in ("low", "medium", "high"):
            issues.append("%s: confidence '%s' not in low|medium|high" % (lid, c))
        if "output_contract" in e and not isinstance(e["output_contract"], dict):
            issues.append("%s: output_contract is not an object" % lid)
        cl = e.get("prefinal_verification_checklist")
        if cl is not None:
            if not isinstance(cl, list):
                issues.append("%s: prefinal_verification_checklist is not an array" % lid)
            else:
                for i, item in enumerate(cl):
                    if not isinstance(item, dict) or "check_id" not in item:
                        issues.append("%s: checklist[%d] missing check_id" % (lid, i))
                    elif "blocking" in item and not isinstance(item["blocking"], bool):
                        issues.append("%s: checklist[%d].blocking must be true/false" % (lid, i))
        if "source_evidence_refs" in e and not isinstance(e["source_evidence_refs"], list):
            issues.append("%s: source_evidence_refs is not an array" % lid)
print(checked)
for it in issues:
    print("ISSUE " + it)
PY
)"
  CONTRACT_COUNT="$(printf '%s\n' "$LINT_OUT" | sed -n '1p')"
  MALFORMED="$(printf '%s\n' "$LINT_OUT" | grep -c '^ISSUE ' || true)"
  if [ "${MALFORMED:-0}" != "0" ]; then
    # Surface every issue (malformed contract field OR unparseable store line),
    # even when there are zero valid contracts — a corrupt store must not read green.
    while IFS= read -r il; do
      case "$il" in "ISSUE "*) record WARN lessons "lesson store issue" "${il#ISSUE }" ;; esac
    done < <(printf '%s\n' "$LINT_OUT")
  elif [ "${CONTRACT_COUNT:-0}" = "0" ]; then
    record PASS lessons "no executable lesson contracts to lint"
  else
    record PASS lessons "lesson contracts well-formed" "${CONTRACT_COUNT} contract(s)"
  fi
else
  record PASS lessons "no local learnings store" ".mtk/learnings.jsonl absent — nothing to lint"
fi

# Cross-store lesson consistency. A 2026-09 field run found analytics.json
# claiming 25 lessons captured while .mtk/learnings.jsonl was 0 bytes — and
# tasks/lessons.md was populated. That exact shape is the "never seeded" store:
# ten skills query the JSONL store, so every lesson query in that repo answered
# nothing. WARN (never FAIL) whenever analytics claims lessons but the structured
# store is empty; the remedy depends on whether the markdown has content
# (`learnings.sh migrate`, or any `query` — it auto-seeds — vs. nothing captured).
if [ -f .claude/analytics.json ] && command -v python3 >/dev/null 2>&1; then
  ANALYTICS_LESSONS="$(python3 -c 'import json,sys; sys.stdout.reconfigure(newline="\n"); print(json.load(open(".claude/analytics.json")).get("lessons_captured",0))' 2>/dev/null || echo 0)"
  JSONL_LESSONS="$(grep -c '[^[:space:]]' .mtk/learnings.jsonl 2>/dev/null || echo 0)"
  MD_LESSONS="$(grep -c '^## ' tasks/lessons.md 2>/dev/null || echo 0)"
  # Normalize to bare integers so `set -e` arithmetic never aborts on stray text.
  ANALYTICS_LESSONS="${ANALYTICS_LESSONS//[!0-9]/}"; ANALYTICS_LESSONS="${ANALYTICS_LESSONS:-0}"
  JSONL_LESSONS="${JSONL_LESSONS//[!0-9]/}"; JSONL_LESSONS="${JSONL_LESSONS:-0}"
  MD_LESSONS="${MD_LESSONS//[!0-9]/}"; MD_LESSONS="${MD_LESSONS:-0}"
  if [ "$ANALYTICS_LESSONS" -gt 0 ] && [ "$JSONL_LESSONS" -eq 0 ] && [ "$MD_LESSONS" -gt 0 ]; then
    record WARN lessons "lesson stores disagree" "analytics.json reports ${ANALYTICS_LESSONS} lessons and tasks/lessons.md has ${MD_LESSONS} heading blocks, but .mtk/learnings.jsonl is empty — the store skills query was never seeded; run 'bash scripts/learnings.sh migrate' (any 'learnings.sh query' also auto-seeds it)"
  elif [ "$ANALYTICS_LESSONS" -gt 0 ] && [ "$JSONL_LESSONS" -eq 0 ]; then
    record WARN lessons "lesson stores disagree" "analytics.json reports ${ANALYTICS_LESSONS} lessons but .mtk/learnings.jsonl and tasks/lessons.md are both empty — one store is stale; both lose evidentiary value"
  else
    record PASS lessons "lesson stores consistent" "analytics=${ANALYTICS_LESSONS} jsonl=${JSONL_LESSONS} md=${MD_LESSONS}"
  fi
fi

# ──────────────────────────────────────────────
# SECURITY (poison-floor supply-chain lint)
# ──────────────────────────────────────────────
# Scan shipped context-entering artifacts (skills/agents/hook config) for
# prompt-injection / credential-exfil / hidden-Unicode red flags. See P0#5.
in_toolkit
if [ -f "scripts/poison-lint.sh" ]; then
  POISON_OUT="$(bash scripts/poison-lint.sh --quiet 2>&1 || true)"
  POISON_SUMMARY="$(printf '%s\n' "$POISON_OUT" | grep '^poison-lint:' | tail -1 || true)"
  if printf '%s\n' "$POISON_OUT" | grep -q '^FAIL '; then
    record FAIL security "poison-floor lint found injection/exfil patterns" "${POISON_SUMMARY:-see: bash scripts/poison-lint.sh}"
  elif printf '%s\n' "$POISON_OUT" | grep -q '^WARN '; then
    record WARN security "poison-floor lint advisories" "${POISON_SUMMARY:-see: bash scripts/poison-lint.sh}"
  else
    record PASS security "poison-floor lint clean" "${POISON_SUMMARY:-no injection/exfil patterns in shipped artifacts}"
  fi
else
  record WARN security "poison-floor lint unavailable" "scripts/poison-lint.sh not found"
fi

# ──────────────────────────────────────────────
# CONTEXT
# ──────────────────────────────────────────────
# Always-on context cost: what loads into every session before the first prompt
# (CLAUDE.md + the rules wake-up layer + alwaysApply references + MCP tool schemas).
# Report-only — surfaces the baseline so teams can keep it lean. These checks must
# stay PASS on a clean repo (pressure-test S1); the numbers live in the detail string.
in_project
ctx_lines=0
ctx_bytes=0
add_ctx_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  local l b
  l="$(wc -l < "$f" | tr -d '[:space:]')"
  b="$(wc -c < "$f" | tr -d '[:space:]')"
  ctx_lines=$((ctx_lines + l))
  ctx_bytes=$((ctx_bytes + b))
}

add_ctx_file "CLAUDE.md"
# AGENTS.md is always-on only when it is actually loaded — resolve-constitution.sh
# --loaded. Deliberately NOT the canonical rule (see the WARN above): a
# generator-marked AGENTS.md that CLAUDE.md imports is still read by the model, so
# it still costs context and is still counted here. The marker decides which file
# is CANONICAL, not which bytes are loaded.
_RC_DOC="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/resolve-constitution.sh"
[ -f "$_RC_DOC" ] || _RC_DOC="${CLAUDE_PLUGIN_ROOT:-.}/scripts/resolve-constitution.sh"
CTX_AGENTS=""
CTX_LOADED=""
if [ -f "$_RC_DOC" ]; then
  CTX_LOADED="$(bash "$_RC_DOC" --loaded 2>/dev/null || true)"
elif [ -f AGENTS.md ] && { [ ! -f CLAUDE.md ] || [ CLAUDE.md -ef AGENTS.md ] || grep -q '^@AGENTS\.md' CLAUDE.md 2>/dev/null; }; then
  CTX_LOADED="AGENTS.md"
fi
if [ "$CTX_LOADED" = "AGENTS.md" ] && [ -f AGENTS.md ]; then
  add_ctx_file "AGENTS.md"
  CTX_AGENTS="AGENTS.md + "
fi
add_ctx_file ".claude/rules/INDEX.md"

# alwaysApply=true references — the only refs that load unconditionally. Read the
# generated TSV index (tab-separated: path, alwaysApply, description, globs).
ALWAYSON_REFS=0
if [ -f ".claude/references.index" ]; then
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if [ -f "$ref" ]; then
      add_ctx_file "$ref"
      ALWAYSON_REFS=$((ALWAYSON_REFS + 1))
    fi
  done < <(awk -F'\t' '/^#/{next} $2=="true"{print $1}' .claude/references.index)
fi

if [ "$ctx_bytes" -gt 0 ]; then
  # ~13 tokens/line proxy, consistent with the context-engineering skill.
  ctx_tokens=$((ctx_lines * 13))
  record PASS context "always-on context baseline" \
    "~${ctx_tokens} tokens (${ctx_lines} lines / ${ctx_bytes} bytes): CLAUDE.md + ${CTX_AGENTS}rules/INDEX.md + ${ALWAYSON_REFS} alwaysApply ref(s)"
else
  record PASS context "always-on context baseline" \
    "no always-on files found (CLAUDE.md / AGENTS.md / rules/INDEX.md absent — likely the source repo)"
fi

# MCP schema overhead — every connected server loads its full tool schema at
# session start (~10-20k tokens each). Count servers declared in this repo's
# .mcp.json (no jq per S3.3; each server entry carries a "type" key).
if [ -f ".mcp.json" ]; then
  MCP_COUNT="$(grep -c '"type"' .mcp.json 2>/dev/null || printf '0')"
  record PASS context "MCP schema baseline" \
    "${MCP_COUNT} server(s) in .mcp.json — each adds ~10-20k tokens of tool schema per session"
else
  record PASS context "MCP schema baseline" "no .mcp.json — no MCP schema baseline"
fi

# Tool-search deferral — defers MCP tool schemas until first use instead of
# loading them all upfront. Advisory either way (never WARN — it is opt-in).
if grep -q 'ENABLE_TOOL_SEARCH' .claude/settings.json 2>/dev/null; then
  record PASS context "tool-search deferral enabled" \
    "ENABLE_TOOL_SEARCH set — MCP tool schemas load on demand"
else
  record PASS context "tool-search deferral not set" \
    "ENABLE_TOOL_SEARCH unset — consider enabling if you connect many MCP servers (defers schema loading)"
fi

# ──────────────────────────────────────────────
# ENVIRONMENT
# ──────────────────────────────────────────────
# Structural checks answer "is MTK installed correctly". These answer "does this
# install fit the machine it is running on" — the class of problem where every
# file is present, every version matches, and the toolkit still misbehaves
# because a knob is calibrated for someone else's setup or a binary is absent.

# Read an env value MTK would see: process env wins, then settings.local.json
# (per-machine), then settings.json (shared). No jq (S3.3) — the env block is
# flat "KEY": "VALUE" pairs.
env_setting() {
  local key="$1" v f
  v="$(printenv "$key" 2>/dev/null || true)"
  if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  for f in .claude/settings.local.json .claude/settings.json; do
    [ -f "$f" ] || continue
    v="$(grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$f" 2>/dev/null | head -1 |
         sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' || true)"
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
  return 0
}

# 1. Context-budget calibration. hooks/context-budget.sh scales its file/mod/op
#    nudges off MTK_CONTEXT_WINDOW_TOKENS, default 1000000. On a 200k model the
#    defaults fire too late; on a 1M model an old 200000 pin fires several times
#    too early, which trains the engineer to ignore the one hook that tells them
#    to checkpoint.
#
#    Claude Code context windows (code.claude.com/docs/en/model-config, Oct 2026):
#    1M by default on Fable 5 / 5.1, Opus 4.7 and later (5, 5.5), Sonnet 5 and
#    later (5.5) and Haiku 5.5. Opus 4.6 and Sonnet 4.6 reach 1M only through
#    their `[1m]` variant. Haiku 4.5, Sonnet 4.5, Opus 4.5 and older are 200k.
#    CLAUDE_CODE_DISABLE_1M_CONTEXT=1 caps every model at 200k. On Bedrock,
#    Google Cloud and Foundry the `haiku` and `sonnet` aliases resolve to the 4.5
#    models (200k), and `opus` on Foundry to Opus 4.6.
#    model_context_window prints 200000, 1000000, or nothing when unknown.
model_context_window() {
  local m provider
  m="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [ -n "$m" ] || return 0
  if [ "$(env_setting CLAUDE_CODE_DISABLE_1M_CONTEXT)" = "1" ]; then
    printf '200000'; return 0
  fi
  case "$m" in *'[1m]'*) printf '1000000'; return 0 ;; esac
  provider="anthropic"
  [ "$(env_setting CLAUDE_CODE_USE_BEDROCK)" = "1" ] && provider="cloud"
  [ "$(env_setting CLAUDE_CODE_USE_VERTEX)" = "1" ] && provider="cloud"
  [ "$(env_setting CLAUDE_CODE_USE_FOUNDRY)" = "1" ] && provider="foundry"
  case "$m" in
    haiku|sonnet)
      [ "$provider" = "anthropic" ] && printf '1000000' || printf '200000' ;;
    opus)
      [ "$provider" = "foundry" ] && printf '200000' || printf '1000000' ;;
    fable|best|opusplan) printf '1000000' ;;
    *opus-4-6*|*sonnet-4-6*) printf '200000' ;;
    *haiku-4*|*sonnet-4*|*opus-4-5*|*opus-4-1*|*opus-4-0*|*opus-4-2025*|*claude-3*|*claude-2*) printf '200000' ;;
    *opus-4-7*|*opus-4-8*|*opus-5*|*sonnet-5*|*haiku-5*|*fable-5*|*mythos-5*) printf '1000000' ;;
  esac
  return 0
}
CTX_WINDOW="$(env_setting MTK_CONTEXT_WINDOW_TOKENS)"
MODEL_HINT="$(env_setting ANTHROPIC_MODEL)"
[ -n "$MODEL_HINT" ] || MODEL_HINT="$(env_setting model)"
MODEL_WINDOW="$(model_context_window "$MODEL_HINT")"
# context-budget.sh sizes its window from the session's model id with the same
# mapping as model_context_window, so an unset MTK_CONTEXT_WINDOW_TOKENS is the
# normal case, not a miscalibration. Only a pin that disagrees with the model is
# worth a WARN: it overrides the derived window for every model.
if [ -n "$CTX_WINDOW" ] && [ -n "$MODEL_WINDOW" ] && [ "$CTX_WINDOW" != "$MODEL_WINDOW" ]; then
  record WARN environment "context budget pinned against the model" \
    "MTK_CONTEXT_WINDOW_TOKENS=${CTX_WINDOW}, but model '${MODEL_HINT}' runs with ${MODEL_WINDOW} tokens — context-budget.sh would size itself from the model id; unset the pin unless the override is deliberate"
elif [ -n "$CTX_WINDOW" ]; then
  record PASS environment "context budget pinned" \
    "MTK_CONTEXT_WINDOW_TOKENS=${CTX_WINDOW} overrides the window context-budget.sh derives from the model id"
else
  record PASS environment "context budget sized from the model id" \
    "context-budget.sh derives the window per session (${MODEL_HINT:-model unknown here}: ${MODEL_WINDOW:-1000000 assumed}); set MTK_CONTEXT_WINDOW_TOKENS only to override it"
fi

# 2. Hook basename also wired in the user's global settings. Two different
#    scripts sharing a basename both fire, and their log lines are
#    indistinguishable — a real debugging trap, not a correctness bug. Nothing
#    suppresses either copy (MTK hooks have no double-run guard), so both run.
USER_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
if [ -f "$USER_SETTINGS" ]; then
  # Compare against the basenames of hook commands the user actually WIRES, not
  # every occurrence of the string anywhere in the file. A `permissions.allow`
  # entry naming an unrelated script is not a second hook, and a WARN claiming
  # "both run" when nothing else runs is how a whole category gets ignored.
  # Extract "command" values, split off flags, basename each token, keep scripts.
  USER_HOOK_BASENAMES="$(
    grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]*"' "$USER_SETTINGS" 2>/dev/null |
      sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' |
      tr ' ' '\n' | sed -e 's|.*/||' | grep -E '\.sh$' | sort -u || true
  )"
  # MTK's hooks live in the project in this checkout and in the plugin root in an
  # install. Without either, there is nothing to compare — say so rather than
  # reporting "no collisions" for a comparison that never happened.
  MTK_HOOK_DIR="$ROOT_DIR/hooks"
  [ -d "$MTK_HOOK_DIR" ] || MTK_HOOK_DIR="${CLAUDE_PLUGIN_ROOT:-}/hooks"
  SHADOWED=""
  MTK_HOOKS_SEEN=0
  for h in "$MTK_HOOK_DIR"/*.sh; do
    [ -f "$h" ] || continue
    MTK_HOOKS_SEEN=$((MTK_HOOKS_SEEN + 1))
    b="$(basename "$h")"
    if printf '%s\n' "$USER_HOOK_BASENAMES" | grep -qxF "$b"; then
      SHADOWED="${SHADOWED}${SHADOWED:+, }${b}"
    fi
  done
  if [ "$MTK_HOOKS_SEEN" -eq 0 ]; then
    record WARN environment "hook collision check skipped" \
      "no hooks/ directory here and \$CLAUDE_PLUGIN_ROOT is unset — 0 MTK hooks compared against ${USER_SETTINGS}"
  elif [ -n "$SHADOWED" ]; then
    record WARN environment "hook basename also wired globally" \
      "${SHADOWED} — ${USER_SETTINGS} wires a hook command with the same filename. Both run, and their output is hard to tell apart; confirm that is intended"
  else
    record PASS environment "no hook basename collisions with user settings" \
      "compared ${MTK_HOOKS_SEEN} MTK hooks against wired commands in ${USER_SETTINGS}"
  fi
else
  record PASS environment "no user-level settings.json to collide with"
fi

# 2b. Hooks registered twice: plugin hooks/hooks.json + project
#    .claude/settings.json, for ANY event. The harness counts both ("Ran 9 stop
#    hooks" in the field, issue #60 — 5 plugin + 4 project) and both copies run:
#    there is no double-run guard. Show the Stop arithmetic, and WARN for every
#    event+basename wired in both places — the project copy should be removed (a
#    dev checkout runs the repo's hooks through `claude --plugin-dir .`).
HOOKS_JSON="$ROOT_DIR/hooks/hooks.json"
if [ -f "$HOOKS_JSON" ] && command -v python3 >/dev/null 2>&1; then
  HOOK_WIRING="$(python3 - "$HOOKS_JSON" ".claude/settings.json" <<'PY' 2>/dev/null || true
import sys; sys.stdout.reconfigure(newline="\n")  # LF even on Windows python3: bash parses this output
import json, os
def basenames(path):
    try:
        doc = json.load(open(path))
    except Exception:
        return []
    hooks = doc.get("hooks", doc) if isinstance(doc, dict) else {}
    out = []
    for event, entries in (hooks.items() if isinstance(hooks, dict) else []):
        for entry in entries if isinstance(entries, list) else []:
            for h in (entry.get("hooks", []) if isinstance(entry, dict) else []) or []:
                tok = str(h.get("command", "")).split()
                if tok and tok[0] in ("bash", "sh", "zsh"):
                    tok = tok[1:]
                if tok:
                    out.append((event, os.path.basename(tok[0].strip("\"'"))))
    return out
for e, b in basenames(sys.argv[1]): print("plugin\t" + e + "\t" + b)
for e, b in basenames(sys.argv[2]): print("project\t" + e + "\t" + b)
PY
)"
  PLUGIN_STOP=0; PROJECT_STOP=0; DOUBLE_WIRED=""
  while IFS=$'\t' read -r src event base; do
    [ -n "$base" ] && [ "$event" = "Stop" ] || continue
    case "$src" in
      plugin)  PLUGIN_STOP=$((PLUGIN_STOP + 1)) ;;
      project) PROJECT_STOP=$((PROJECT_STOP + 1)) ;;
    esac
  done <<< "$HOOK_WIRING"
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    DOUBLE_WIRED="${DOUBLE_WIRED}${DOUBLE_WIRED:+, }${pair}"
  done < <(awk -F'\t' '$1=="plugin"{p[$2" "$3]=1} $1=="project"{q[$2" "$3]=1} END{for (k in p) if (k in q) print k}' <<<"$HOOK_WIRING" | sort)
  STOP_TOTAL=$((PLUGIN_STOP + PROJECT_STOP))
  # The arithmetic is always worth showing; the WARN rides alongside it.
  record PASS environment "Stop hook registrations accounted for" \
    "${STOP_TOTAL} = ${PLUGIN_STOP} plugin (hooks/hooks.json) + ${PROJECT_STOP} project (.claude/settings.json) — the harness reports this as 'Ran ${STOP_TOTAL} stop hooks'"
  if [ -n "$DOUBLE_WIRED" ]; then
    record WARN environment "hook wired twice" \
      "${DOUBLE_WIRED} — registered in hooks/hooks.json and .claude/settings.json, so both copies run on every such event and race on shared files; remove the .claude/settings.json entry (dev checkouts: run claude --plugin-dir .)"
  fi
fi

# 2c. Stale plugin-cache versions. installed_plugins.json records ONE installPath
#    per plugin; older version directories beside it are upgrade leftovers. They
#    cost disk, and any "newest cache copy" search (this doctor's own, or an
#    engineer setting MTK_HELPER_ROOT by hand) can land on the wrong one. Name
#    them with the exact removal command — never delete on the engineer's behalf.
if [ -n "$CACHE_ROOT" ]; then
  CACHE_VERSIONS_DIR="$(dirname "$CACHE_ROOT")"
  INSTALLED_CACHE_PATH=""
  IP_JSON="${HOME:-/nonexistent}/.claude/plugins/installed_plugins.json"
  if [ -f "$IP_JSON" ] && command -v python3 >/dev/null 2>&1; then
    INSTALLED_CACHE_PATH="$(python3 - "$IP_JSON" "$CACHE_VERSIONS_DIR" <<'PY' 2>/dev/null || true
import sys; sys.stdout.reconfigure(newline="\n")  # LF even on Windows python3: bash parses this output
import json, os
doc = json.load(open(sys.argv[1]))
want = os.path.realpath(sys.argv[2])
for entries in (doc.get("plugins") or {}).values():
    for e in (entries if isinstance(entries, list) else [entries]):
        p = e.get("installPath", "") if isinstance(e, dict) else ""
        if p and os.path.realpath(os.path.dirname(p)) == want:
            print(p)
            raise SystemExit
PY
)"
  fi
  # No registry entry for this cache → the newest copy is the best guess.
  [ -n "$INSTALLED_CACHE_PATH" ] && [ -d "$INSTALLED_CACHE_PATH" ] || INSTALLED_CACHE_PATH="$CACHE_ROOT"
  INSTALLED_REAL="$(cd "$INSTALLED_CACHE_PATH" && pwd -P)"
  STALE_VERSIONS=""
  for vd in "$CACHE_VERSIONS_DIR"/*/; do
    vd="${vd%/}"
    [ -d "$vd" ] || continue
    [ "$(cd "$vd" && pwd -P)" = "$INSTALLED_REAL" ] && continue
    STALE_VERSIONS="${STALE_VERSIONS}${STALE_VERSIONS:+ }$(basename "$vd")"
  done
  if [ -n "$STALE_VERSIONS" ]; then
    RM_CMD="rm -rf"
    for v in $STALE_VERSIONS; do RM_CMD="$RM_CMD ${CACHE_VERSIONS_DIR}/${v}"; done
    record WARN environment "stale plugin-cache versions" \
      "${STALE_VERSIONS// /, } under ${CACHE_VERSIONS_DIR} — installed is $(basename "$INSTALLED_REAL") per installed_plugins.json; the rest are upgrade leftovers. Remove with: ${RM_CMD}"
  else
    record PASS environment "plugin cache holds only the installed version" \
      "$(basename "$INSTALLED_REAL") under ${CACHE_VERSIONS_DIR}"
  fi
fi

# 3. Formatter present for the active stack. format-on-edit.sh never blocks and
#    logs only to stderr, so a missing binary is invisible: edits look formatted
#    and are not.
STACK=""
[ -f ".claude/tech-stack" ] && STACK="$(tr -d '[:space:]' < .claude/tech-stack)"
if [ -z "$STACK" ]; then
  record PASS environment "no active tech stack" ".claude/tech-stack absent — formatter check skipped"
else
  case "$STACK" in
    dotnet)   FMT_OK=0; command -v dotnet >/dev/null 2>&1 && FMT_OK=1; FMT_WANT="dotnet" ;;
    python)   FMT_OK=0; { command -v ruff >/dev/null 2>&1 || command -v black >/dev/null 2>&1; } && FMT_OK=1; FMT_WANT="ruff or black" ;;
    typescript) FMT_OK=0; command -v npx >/dev/null 2>&1 && FMT_OK=1; FMT_WANT="npx (biome/prettier)" ;;
    *)        FMT_OK=1; FMT_WANT="" ;;
  esac
  if [ -z "$FMT_WANT" ]; then
    record PASS environment "formatter check not defined for stack" "$STACK"
  elif [ "$FMT_OK" -eq 1 ]; then
    record PASS environment "formatter available for ${STACK}" "$FMT_WANT"
  else
    record WARN environment "formatter missing for ${STACK}" \
      "${FMT_WANT} not on PATH — format-on-edit.sh logs to stderr and never blocks, so edits will silently go unformatted"
  fi
fi

# ──────────────────────────────────────────────
# OUTPUT
# ──────────────────────────────────────────────
if [ "$JSON" -eq 1 ]; then
  printf '{"summary":{"pass":%d,"warn":%d,"fail":%d},"checks":[' "$PASS" "$WARN" "$FAIL"
  first=1
  for line in "${RESULTS[@]}"; do
    status="$(printf '%s' "$line" | cut -f1)"
    cat="$(printf '%s' "$line" | cut -f2)"
    name="$(printf '%s' "$line" | cut -f3)"
    detail="$(printf '%s' "$line" | cut -f4)"
    [ "$first" -eq 0 ] && printf ','
    first=0
    # Escape quotes/backslashes for JSON
    name_esc="${name//\\/\\\\}"; name_esc="${name_esc//\"/\\\"}"
    detail_esc="${detail//\\/\\\\}"; detail_esc="${detail_esc//\"/\\\"}"
    printf '{"status":"%s","category":"%s","name":"%s","detail":"%s"}' \
      "$status" "$cat" "$name_esc" "$detail_esc"
  done
  printf ']}\n'
else
  current_cat=""
  for line in "${RESULTS[@]}"; do
    status="$(printf '%s' "$line" | cut -f1)"
    cat="$(printf '%s' "$line" | cut -f2)"
    name="$(printf '%s' "$line" | cut -f3)"
    detail="$(printf '%s' "$line" | cut -f4)"
    if [ "$cat" != "$current_cat" ]; then
      printf '\n%s\n' "$(printf '%s' "$cat" | tr '[:lower:]' '[:upper:]')"
      current_cat="$cat"
    fi
    case "$status" in
      PASS) sym='✓' ;;
      WARN) sym='⚠' ;;
      FAIL) sym='✗' ;;
    esac
    if [ -n "$detail" ]; then
      printf '  %s %s — %s\n' "$sym" "$name" "$detail"
    else
      printf '  %s %s\n' "$sym" "$name"
    fi
  done
  printf '\nSummary: %d PASS, %d WARN, %d FAIL\n' "$PASS" "$WARN" "$FAIL"
fi

# Exit code
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
if [ "$STRICT" -eq 1 ] && [ "$WARN" -gt 0 ]; then
  exit 1
fi
exit 0
