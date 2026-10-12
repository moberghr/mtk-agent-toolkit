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

# --task-scoped <comma-separated file list>
# Verifies that every touched skill / hook / agent / reference is fully wired:
#   - frontmatter `name:` matches dir for skills
#   - file is registered in .claude/manifest.json
#   - hooks are chmod +x and referenced from .claude/settings.json OR hooks/hooks.json
#   - agent files appear in .claude-plugin/plugin.json
#   - reference files are listed in .claude/references.index (if the index exists)
# Exits non-zero on the first unwired artifact. Returns silently on success.
if [ "${1:-}" = "--task-scoped" ]; then
  shift
  files_csv="${1:-}"
  [ -n "$files_csv" ] || fail "--task-scoped requires a comma-separated file list"
  manifest=".claude/manifest.json"
  settings=".claude/settings.json"
  hooks_json="hooks/hooks.json"
  plugin=".claude-plugin/plugin.json"
  refidx=".claude/references.index"
  IFS=',' read -r -a files <<< "$files_csv"
  for f in "${files[@]}"; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || fail "wiring: file does not exist: $f"
    case "$f" in
      .claude/skills/*/SKILL.md)
        dir="$(dirname "$f")"; expected="$(basename "$dir")"
        actual="$(awk '/^name:/ { print $2; exit }' "$f")"
        [ "$expected" = "$actual" ] || fail "wiring: $f frontmatter name='$actual' does not match dir '$expected'"
        grep -q "\"skills/${expected}/SKILL.md\"" "$manifest" || fail "wiring: skill '$expected' is not registered in $manifest"
        ;;
      hooks/*.sh|hooks/git-hooks/*.sh|hooks/lib/*.sh|hooks/*/*.sh)
        [ -x "$f" ] || fail "wiring: hook script $f is not executable (chmod +x)"
        if ! grep -q "$(basename "$f")" "$settings" 2>/dev/null && ! grep -q "$(basename "$f")" "$hooks_json" 2>/dev/null; then
          # Library files in hooks/lib/ are sourced by other hooks — accept if referenced anywhere under hooks/.
          if ! grep -rq "$(basename "$f")" hooks/ 2>/dev/null; then
            fail "wiring: hook $f is not referenced from $settings, $hooks_json, or any other hook"
          fi
        fi
        ;;
      .claude/agents/*.md)
        rel="./${f}"
        grep -q "\"${rel}\"" "$plugin" || grep -q "\"${f}\"" "$plugin" || fail "wiring: agent $f is not registered in $plugin"
        ;;
      .claude/references/*.md)
        if [ -f "$refidx" ]; then
          grep -q "^${f}\b" "$refidx" || fail "wiring: reference $f is not in $refidx (run scripts/build-references-index.sh)"
        fi
        ;;
      .claude/manifest.json|.claude/settings.json|.claude-plugin/plugin.json|.claude-plugin/marketplace.json)
        # configuration files are themselves the wiring registry — no check
        ;;
      *)
        # unknown file type — defer to the regular validator semantics
        ;;
    esac
  done
  printf 'Task-scoped wiring check passed (%s).\n' "$files_csv"
  exit 0
fi

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
# Claude Code's permission keys are allow / deny / ask. `permissions.allowedTools`
# is not one (it is the --allowedTools CLI flag), so a list there is silently
# ignored. scripts/migrate-settings-permissions.sh moves it into allow.
bash scripts/migrate-settings-permissions.sh --check .claude/settings.json >/dev/null \
  || fail "settings.json has permissions.allowedTools, which Claude Code ignores — run: bash scripts/migrate-settings-permissions.sh .claude/settings.json"
# The dev checkout runs the repo's hooks as a plugin (`claude --plugin-dir .`),
# from hooks/hooks.json. Wiring them in .claude/settings.json as well would run
# every hook twice, so the project settings carry no hooks block at all.
python3 - <<'MTKPY' || fail ".claude/settings.json declares hooks — the dev checkout loads hooks/hooks.json via 'claude --plugin-dir .'; remove the settings.json hooks block (CONTRIBUTING.md, Developing MTK)"
import json, sys
sys.exit(1 if "hooks" in json.load(open(".claude/settings.json")) else 0)
MTKPY

# Hook commands must be root-anchored, never relative (S3.5/S3.6).
#
# A relative "hooks/x.sh" resolves against the hook process's cwd, and a hook is
# NOT guaranteed to run with cwd inside the repo. When the cwd is elsewhere the
# command is simply not found and the hook does not run: the guard is silently
# OFF rather than loudly broken, the same failure mode S1.17 exists to prevent.
# hooks.json anchors on ${CLAUDE_PLUGIN_ROOT}; the project settings.json wires no
# hooks at all (checked above).
#
# The scan is spacing-tolerant and asserts it matched something. A check whose
# input selector can silently return zero rows passes by inspecting nothing —
# which is exactly the mtk-doctor bug fixed alongside this one, where the
# selector was pinned to a spelling. Reformatting settings.json to
# `"command":"…"` must not quietly switch the guard off.
check_hook_anchor() { # $1=file  $2=required substring  $3=message
  local file="$1" want="$2" msg="$3" line count=0
  while IFS= read -r line; do
    count=$((count + 1))
    case "$line" in
      *"$want"*) ;;
      *) fail "${msg}: ${line}" ;;
    esac
  done < <(grep -oE '"command"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*hooks/([^"\\]|\\.)*"' "$file" || true)
  [ "$count" -gt 0 ] || fail "$file: found 0 hook commands to check — the selector matched nothing, so this guard inspected nothing. Fix the selector, do not assume the file is clean."
}

check_hook_anchor hooks/hooks.json '${CLAUDE_PLUGIN_ROOT}' \
  "hooks.json hook command is not anchored on \${CLAUDE_PLUGIN_ROOT} — plugin-installed repos have no repo-relative hooks/ directory"

# A tech-stack skill's `## Settings Additions` is copied verbatim into the TARGET
# repo's .claude/settings.json. ${CLAUDE_PLUGIN_ROOT} is defined only for hooks a
# plugin declares in its own hooks/hooks.json — in a project settings file it
# expands to the empty string and the hook runs as `bash /hooks/<name>`, failing
# on every invocation. That shipped: 4,552 such failures across 7 bootstrapped
# repos, with formatting never once running. MTK hooks belong in hooks/hooks.json;
# a tech-stack skill must never hand bootstrap one to write. Only the
# `## Settings Additions` section is copied; elsewhere (a command the agent runs
# itself, such as the build-diagnostics parser) the plugin-relative path is right.
for stack_skill in .claude/skills/tech-stack-*/SKILL.md; do
  [ -f "$stack_skill" ] || continue
  settings_additions="$(awk '/^## /{p=($0=="## Settings Additions")} p' "$stack_skill")"
  if grep -qE '\$\{?CLAUDE_PLUGIN_ROOT(:-[^}]*)?\}?/hooks/' <<< "$settings_additions"; then
    fail "$stack_skill ## Settings Additions references \$CLAUDE_PLUGIN_ROOT/hooks/ — that variable is empty in a project settings.json, so every generated hook invocation fails. Declare the hook in hooks/hooks.json instead."
  fi
done

# The hooks MTK used to hand to target repos must actually be declared here, or
# removing them from the tech-stack templates silently drops the behaviour.
# Every hook must declare a timeout. An unbounded hook has no ceiling on how long it
# can wedge a tool call or a stop: the harness cancels a hook that overruns its
# timeout, and with none set there is nothing to overrun. This bit MTK before — a
# Stop hook with no timeout is the one place a hang costs the whole session. A
# blocking hook that times out fails OPEN (its decision never arrives), which is the
# right trade: a missed advisory beats a frozen session.
python3 - <<'MTKPY' || fail "hooks/hooks.json has a hook with no timeout"
import json, sys
d = json.load(open("hooks/hooks.json")).get("hooks", {})
bad = [(ev, h.get("command", "?").split("/")[-1])
       for ev, blocks in d.items() for b in blocks for h in b.get("hooks", [])
       if "timeout" not in h]
for ev, name in bad:
    print(f"ERROR: hooks.json {ev} hook {name} declares no timeout", file=sys.stderr)
sys.exit(1 if bad else 0)
MTKPY

for required_cmd in format-on-edit.sh; do
  grep -q "$required_cmd" hooks/hooks.json \
    || fail "hooks/hooks.json does not declare $required_cmd — it was removed from the tech-stack Settings Additions, so nothing wires it any more"
done

# All shell scripts in hooks/ and scripts/ must be executable and follow S3.1
while IFS= read -r script; do
  [ -x "$script" ] || fail "$script is not executable (chmod +x) — violates S3.2"
  # Some scripts have multi-line comment headers before pipefail; scan first 15 lines.
  # <(head …) not head|grep: grep -q exits on match, head takes SIGPIPE (141), and
  # pipefail would turn that success into a spurious failure on a random file.
  grep -q 'set -euo pipefail' <(head -15 "$script") || fail "$script missing 'set -euo pipefail' — violates S3.1"
done < <(find hooks/ scripts/ -type f \( -name '*.sh' -o -name 'pre-commit' -o -name 'session-start' -o -name 'verify-completion' \) | sort)

# The git pre-commit hook and linter script must agree on supported flags. The
# linter is an on-demand script, not a wired hook, so it may live in hooks/ or
# scripts/; check whichever copy exists rather than pinning one location.
linters_found=0
for linters in hooks/pre-commit-linters.sh scripts/pre-commit-linters.sh; do
  [ -f "$linters" ] || continue
  linters_found=1
  grep -q -- '--cached' "$linters" || fail "$linters must support --cached for git hooks"
done
[ "$linters_found" -eq 1 ] || fail "pre-commit-linters.sh not found in hooks/ or scripts/ — hooks/git-hooks/pre-commit depends on it"

# Every hook hooks.json wires must exist and be executable. Data-driven on
# purpose: the check iterates what hooks.json actually registers, so renaming or
# removing a hook needs no edit here, and a dangling registration (the script
# deleted, the entry left behind) fails instead of erroring on every tool call.
python3 - <<'MTKPY' || fail "hooks/hooks.json wires a hook command that does not resolve to an executable file"
import json, os, shlex, sys
d = json.load(open("hooks/hooks.json")).get("hooks", {})
bad, seen = [], 0
for ev, blocks in d.items():
    for b in blocks:
        for h in b.get("hooks", []):
            cmd = h.get("command")
            if not cmd:
                continue
            seen += 1
            try:
                exe = shlex.split(cmd)[0]
            except ValueError:
                bad.append(f"{ev}: unparseable command {cmd!r}")
                continue
            path = exe.replace("${CLAUDE_PLUGIN_ROOT}", ".")
            if not os.path.isfile(path):
                bad.append(f"{ev}: {exe} does not exist")
            elif not os.access(path, os.X_OK):
                bad.append(f"{ev}: {exe} is not executable")
if seen == 0:
    bad.append("found 0 hook commands — the selector matched nothing, so this check inspected nothing")
for line in bad:
    print(f"ERROR: hooks.json {line}", file=sys.stderr)
sys.exit(1 if bad else 0)
MTKPY

# Runtime diet lock. Read, Grep, Glob, MCP tool calls and user prompts carry zero
# MTK hooks: each one is a process spawn on the hottest paths of every session, and
# native Claude Code already covers what those hooks did (path-scoped rules via
# `paths:`, skill routing via descriptions). Fail if hooks.json registers
# UserPromptSubmit, or any tool-event matcher that covers Read, Grep, Glob or an
# mcp__ tool. Matcher semantics follow Claude Code: empty or "*" matches every
# tool; a plain `A|B` list matches those names exactly; anything else is a regex.
# One classifier, shared with mtk-doctor: hooks/lib/hot_path_matchers.py (any
# matcher naming mcp__ is MCP, however it is server-scoped).
if ! DIET_OUT="$(python3 hooks/lib/hot_path_matchers.py hooks/hooks.json 2>&1)"; then
  while IFS=$'\t' read -r where why; do
    [ -n "$where" ] && printf 'ERROR: runtime diet: %s %s\n' "$where" "$why" >&2
  done <<< "$DIET_OUT"
  fail "hooks/hooks.json breaks the runtime diet — no hook may run on user prompts or on Read/Grep/Glob/MCP tool calls"
fi

for required_cmd in format-on-edit.sh; do
  grep -q "$required_cmd" hooks/hooks.json \
    || fail "hooks/hooks.json does not declare $required_cmd — it was removed from the tech-stack Settings Additions, so nothing wires it any more"
done

# All shell scripts in hooks/ and scripts/ must be executable and follow S3.1
while IFS= read -r script; do
  [ -x "$script" ] || fail "$script is not executable (chmod +x) — violates S3.2"
  # Some scripts have multi-line comment headers before pipefail; scan first 15 lines.
  # <(head …) not head|grep: grep -q exits on match, head takes SIGPIPE (141), and
  # pipefail would turn that success into a spurious failure on a random file.
  grep -q 'set -euo pipefail' <(head -15 "$script") || fail "$script missing 'set -euo pipefail' — violates S3.1"
done < <(find hooks/ scripts/ -type f \( -name '*.sh' -o -name 'pre-commit' -o -name 'session-start' -o -name 'verify-completion' \) | sort)

# The git pre-commit hook and linter script must agree on supported flags. The
# linter is an on-demand script, not a wired hook, so it may live in hooks/ or
# scripts/; check whichever copy exists rather than pinning one location.
linters_found=0
for linters in hooks/pre-commit-linters.sh scripts/pre-commit-linters.sh; do
  [ -f "$linters" ] || continue
  linters_found=1
  grep -q -- '--cached' "$linters" || fail "$linters must support --cached for git hooks"
done
[ "$linters_found" -eq 1 ] || fail "pre-commit-linters.sh not found in hooks/ or scripts/ — hooks/git-hooks/pre-commit depends on it"

# Every hook hooks.json wires must exist and be executable. Data-driven on
# purpose: the check iterates what hooks.json actually registers, so renaming or
# removing a hook needs no edit here, and a dangling registration (the script
# deleted, the entry left behind) fails instead of erroring on every tool call.
python3 - <<'MTKPY' || fail "hooks/hooks.json wires a hook command that does not resolve to an executable file"
import json, os, shlex, sys
d = json.load(open("hooks/hooks.json")).get("hooks", {})
bad, seen = [], 0
for ev, blocks in d.items():
    for b in blocks:
        for h in b.get("hooks", []):
            cmd = h.get("command")
            if not cmd:
                continue
            seen += 1
            try:
                exe = shlex.split(cmd)[0]
            except ValueError:
                bad.append(f"{ev}: unparseable command {cmd!r}")
                continue
            path = exe.replace("${CLAUDE_PLUGIN_ROOT}", ".")
            if not os.path.isfile(path):
                bad.append(f"{ev}: {exe} does not exist")
            elif not os.access(path, os.X_OK):
                bad.append(f"{ev}: {exe} is not executable")
if seen == 0:
    bad.append("found 0 hook commands — the selector matched nothing, so this check inspected nothing")
for line in bad:
    print(f"ERROR: hooks.json {line}", file=sys.stderr)
sys.exit(1 if bad else 0)
MTKPY

# Runtime diet lock. Read, Grep, Glob, MCP tool calls and user prompts carry zero
# MTK hooks: each one is a process spawn on the hottest paths of every session, and
# native Claude Code already covers what those hooks did (path-scoped rules via
# `paths:`, skill routing via descriptions). Fail if hooks.json registers
# UserPromptSubmit, or any tool-event matcher that covers Read, Grep, Glob or an
# mcp__ tool. Matcher semantics follow Claude Code: empty or "*" matches every
# tool; a plain `A|B` list matches those names exactly; anything else is a regex.
python3 - <<'MTKPY' || fail "hooks/hooks.json breaks the runtime diet — no hook may run on user prompts or on Read/Grep/Glob/MCP tool calls"
import json, os, re, shlex, sys
d = json.load(open("hooks/hooks.json")).get("hooks", {})
TOOL_EVENTS = {"PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"}
PROBES = ["Read", "Grep", "Glob", "mcp__server__tool"]
def covers(matcher, tool):
    if matcher in (None, "", "*"):
        return True
    if re.fullmatch(r"[A-Za-z0-9_|]+", matcher):
        return tool in matcher.split("|")
    try:
        return re.search(matcher, tool) is not None
    except re.error:
        return True  # an unparseable matcher cannot be proved narrow
bad = []
if d.get("UserPromptSubmit"):
    bad.append("UserPromptSubmit is registered")
for ev, blocks in d.items():
    if ev not in TOOL_EVENTS:
        continue
    for b in blocks:
        m = b.get("matcher")
        hit = [t for t in PROBES if covers(m, t)]
        if hit:
            names = [os.path.basename(shlex.split(h["command"])[0]) if h.get("command") else "?"
                     for h in b.get("hooks", [])]
            bad.append(f"{ev} matcher {m!r} covers {', '.join(hit)} ({', '.join(names)})")
for line in bad:
    print(f"ERROR: runtime diet: {line}", file=sys.stderr)
sys.exit(1 if bad else 0)
MTKPY

# Unified setup entry point must exist
require_file ".claude/skills/mtk-setup/SKILL.md"

# Changelog must exist
require_file "CHANGELOG.md"

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
marketplace_version="$(grep -E '"version"' .claude-plugin/marketplace.json | head -1 | sed -E 's/.*"version": "([^"]+)".*/\1/')"

[ "$manifest_version" = "$plugin_version" ] || fail "Version mismatch: manifest=$manifest_version plugin=$plugin_version"
[ "$manifest_version" = "$marketplace_version" ] || fail "Version mismatch: manifest=$manifest_version marketplace=$marketplace_version"

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

# Disk -> manifest completeness for hook tests. Every tests/hooks/*.sh is
# individually registered by convention (C0.2); a file on disk but absent from
# the manifest ships untracked and the suite is falsely green. This is a
# disk->manifest direction the source-path loop above cannot catch.
for t in tests/hooks/*.sh; do
  [ -e "$t" ] || continue
  grep -qF "\"$t\"" .claude/manifest.json || fail "Hook test not registered in manifest.json: $t (add a files entry — C0.2)"
done

# Disk -> manifest completeness for the whole repo (C0.2). The source-path loop
# above only proves every manifest entry exists; this proves every file in the
# repo (tracked, plus untracked files git does not ignore) has an entry, so a new
# file cannot ship unregistered. The allow-list is the files that are not
# distributed: the descriptors that define what ships, repo metadata, this
# repo's own rules and lessons, specs/plans, and internal research notes.
manifest_allowed_unlisted() {
  case "$1" in
    .claude/manifest.json|.claude-plugin/*) return 0 ;;
    README.md|CONTRIBUTING.md|LICENSE|CLAUDE.md|.gitignore|*/.gitkeep) return 0 ;;
    .github/*) return 0 ;;
    .claude/rules/*|tasks/lessons.md|.claude/references/pre-commit-review-list.md) return 0 ;;
    docs/specs/*|docs/plans/*) return 0 ;;
    docs/competitive-analysis-*.md|docs/ecc-harness-adapters-*.md|docs/harness-support-matrix.md) return 0 ;;
  esac
  return 1
}
# Read once, guarded: a grep that matches nothing exits 1, and under pipefail
# that would abort this script inside $(…) with no message at all.
manifest_sources="$(grep -E '^[[:space:]]*"source":' .claude/manifest.json 2>/dev/null | sed -E 's/.*"source":[[:space:]]*"([^"]+)".*/\1/' || true)"
[ -n "$manifest_sources" ] || fail ".claude/manifest.json lists no \"source\" entries — cannot check C0.2"
# The disk -> manifest direction needs git to tell repo files from build output
# and ignored files. Outside a work tree that check cannot run, and skipping it
# silently would print "Toolkit validation passed" for an unchecked tree.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "not inside a git work tree — the disk -> manifest.json check (C0.2) cannot run; validate from a git checkout"
else
  unlisted=()
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    manifest_allowed_unlisted "$f" && continue
    grep -qxF -- "$f" <<< "$manifest_sources" || unlisted+=("$f")
  done < <(git ls-files --cached --others --exclude-standard)
  if [ "${#unlisted[@]}" -gt 0 ]; then
    printf 'ERROR: not in manifest.json: %s\n' "${unlisted[@]}" >&2
    fail "${#unlisted[@]} repo file(s) have no manifest.json files entry — register each one, or add it to manifest_allowed_unlisted in this script if it is not distributed (C0.2)"
  fi
fi

# Internal project names must not ship. Every manifest-listed file is distributed
# to other teams' repos, so a client or internal codename in a skill, reference,
# hook or test leaks it. Specs, plans and the changelog are working history and
# are excluded. The pattern uses a character class per name so this script does
# not match itself.
# Codenames that are ordinary English words elsewhere match as whole words only.
INTERNAL_NAMES_RE='pay[f]ac|collection-[s]ystem|bn[p]l|(^|[^[:alnum:]_])(a[u]dur|b[e]acon|i[n]venthor)([^[:alnum:]_]|$)'
leaks=()
while IFS= read -r f; do
  case "$f" in docs/specs/*|docs/plans/*|CHANGELOG.md) continue ;; esac
  [ -f "$f" ] || continue
  if grep -qiE "$INTERNAL_NAMES_RE" "$f"; then
    leaks+=("$f")
  fi
done < <(grep -v '://' <<<"$manifest_sources" | sort -u)
if [ "${#leaks[@]}" -gt 0 ]; then
  for f in "${leaks[@]}"; do
    grep -niE "$INTERNAL_NAMES_RE" "$f" | awk -v f="$f" '{ print "ERROR: internal name in " f ":" $0 }' >&2
  done
  fail "${#leaks[@]} shipped file(s) name an internal project — replace it with a neutral example"
fi

# Plugin-root spelling (S2.27). Claude Code substitutes only the braced form
# ${CLAUDE_PLUGIN_ROOT} into skill and agent text at load time, and never exports
# it to the Bash tool. A default-value form is left unsubstituted and degrades to
# its fallback (usually "."), which breaks every plugin install outside this repo.
# References are read with the Read tool, so nothing in them is substituted.
plugin_root_bad=$(grep -rnE '\$\{CLAUDE_PLUGIN_ROOT:-' .claude/skills .claude/agents .claude/references 2>/dev/null || true)
if [ -n "$plugin_root_bad" ]; then
  printf '%s\n' "$plugin_root_bad" | awk '{ print "ERROR: " $0 }' >&2
  fail "\${CLAUDE_PLUGIN_ROOT:-…} is never substituted — use \${CLAUDE_PLUGIN_ROOT} in skills/agents and \$MTK_ROOT in references (S2.27)"
fi
# The unbraced $CLAUDE_PLUGIN_ROOT/ is not substituted either, and in a fenced
# bash block the model runs it verbatim: the Bash tool has no such variable, so
# the path collapses to /scripts/… . Prose mentions in backticks are fine; only
# fenced bash/sh/shell blocks are scanned.
plugin_root_unbraced="$(find .claude/skills .claude/agents -name '*.md' -type f 2>/dev/null | sort | while IFS= read -r md; do
  awk -v f="$md" '
    /^[[:space:]]*```/ {
      if (fence) { fence = 0 } else { fence = ($0 ~ /^[[:space:]]*```[[:space:]]*(bash|sh|shell|zsh)[[:space:]]*$/) ? 1 : 2 }
      next
    }
    fence == 1 && /[$]CLAUDE_PLUGIN_ROOT\// { print f ":" NR ": " $0 }
  ' "$md"
done)"
if [ -n "$plugin_root_unbraced" ]; then
  printf '%s\n' "$plugin_root_unbraced" | awk '{ print "ERROR: " $0 }' >&2
  fail "unbraced \$CLAUDE_PLUGIN_ROOT/ inside a fenced bash block is never substituted — write \${CLAUDE_PLUGIN_ROOT}/ (S2.27)"
fi

# applyTo values must be glob patterns (strings). Quick sanity: any applyTo line
# must be an array opener or a quoted glob. Detect obvious errors (non-array value).
if grep -nE '"applyTo":[[:space:]]*[^\[]' .claude/manifest.json | grep -v '"applyTo": \[$' >/dev/null; then
  fail "manifest.json has an 'applyTo' entry that is not an array. Use [\"glob1\", \"glob2\"] form."
fi

# Frontmatter must be valid YAML: an unquoted flow sequence followed by more text
# (e.g. `argument-hint: [--json] [--fix]`) breaks the parse and Anthropic's directory
# validator blocks on it. `key: [a, b]` alone is fine; quote the whole value otherwise.
# The awk scans each `key: [` value tracking bracket depth and quoted strings, finds
# the `]` that closes the sequence, and flags only non-comment text after it. A
# trailing CR is stripped first so CRLF files are checked too. Runs before the
# `^---$` presence check so a CRLF file reports this, the more specific finding.
while IFS= read -r file; do
  bad_line="$(awk -v sq="'" -v dq='"' '
    { sub(/\r$/, "") }
    NR==1 && $0 !~ /^---[[:space:]]*$/ {exit}
    /^---[[:space:]]*$/ {c++; if (c==2) exit; next}
    c==1 && match($0, /^[A-Za-z0-9_.-]+:[[:space:]]*\[/) {
      v = substr($0, RLENGTH); n = length(v)
      depth = 0; q = ""; prev = ""; close_at = 0
      for (i = 1; i <= n; i++) {
        ch = substr(v, i, 1)
        if (q != "") {
          if (q == dq && ch == "\\") { i++; continue }
          if (ch == q) {
            if (q == sq && substr(v, i + 1, 1) == sq) { i++; continue }
            q = ""; prev = ch
          }
          continue
        }
        if ((ch == sq || ch == dq) && (prev == "[" || prev == "," || prev == ":" || prev == "{")) { q = ch; continue }
        if (ch == "[") depth++
        else if (ch == "]") { depth--; if (depth == 0) { close_at = i; break } }
        if (ch !~ /[[:space:]]/) prev = ch
      }
      if (close_at) {
        rest = substr(v, close_at + 1)
        if (rest !~ /^[[:space:]]*($|#)/) { print NR ": " $0; exit }
      }
    }
  ' "$file")"
  [ -z "$bad_line" ] || fail "invalid YAML frontmatter in $file line $bad_line — unquoted flow sequence followed by more text; quote the whole value (e.g. argument-hint: \"[--a] [--b]\")"
done < <({ find .claude/agents -name '*.md'; printf '%s\n' "${manifest_skill_paths[@]+"${manifest_skill_paths[@]}"}"; } | sort -u)

# Frontmatter check on agents and manifest-tracked skills only.
# (Third-party skill plugins under .claude/skills/ are not MTK-managed.)
while IFS= read -r file; do
  require_section "$file" '^---$'
done < <({ find .claude/agents -name '*.md'; printf '%s\n' "${manifest_skill_paths[@]+"${manifest_skill_paths[@]}"}"; } | sort -u)

# Skill anatomy check — only MTK-managed skills (those in the manifest)
for skill in "${manifest_skill_paths[@]+"${manifest_skill_paths[@]}"}"; do
  skill_dir="$(basename "$(dirname "$skill")")"
  skill_name="$(grep -E '^name:' "$skill" | sed -E 's/name:[[:space:]]*//')"
  [ "$skill_dir" = "$skill_name" ] || fail "Skill name mismatch: $skill uses '$skill_name' but directory is '$skill_dir'"
  # Entry-point skills (with allowed-tools) have phase-based structure, not the standard anatomy.
  if grep -q '^allowed-tools:' "$skill"; then
    require_section "$skill" '^## '
  elif echo "$skill_dir" | grep -q '^tech-stack-'; then
    # Tech stack skills are declarative — no Workflow section.
    require_section "$skill" '^## Overview'
    require_section "$skill" '^## When To Use'
    require_section "$skill" '^## Verification'
  elif grep -qE '^## (Phase [0-9]|STEP [0-9]|Process|Modes|Route Table)' "$skill"; then
    # Phase-based workflow skills (ex-entry-points dispatched via /mtk router).
    # They use phase/step headers instead of the standard anatomy. At least one ## section required.
    require_section "$skill" '^## '
  else
    # Workflow skills require full anatomy.
    require_section "$skill" '^## Overview'
    require_section "$skill" '^## When To Use'
    require_section "$skill" '^## Workflow'
    require_section "$skill" '^## Verification'
  fi
done

# README and AGENTS coverage
grep -q 'skills/' README.md || fail "README does not describe skills"
grep -q 'AGENTS.md' README.md || fail "README does not mention AGENTS.md"
grep -q 'docs/skill-anatomy.md' CONTRIBUTING.md || fail "CONTRIBUTING does not point to skill anatomy guidance"
grep -q 'tech-stack' README.md || fail "README does not mention the tech stack architecture"
grep -q 'context-engineering' AGENTS.md || fail "AGENTS.md does not route context-engineering"

# AGENTS.md is the canonical constitution; CLAUDE.md is only the shim that imports it.
if [ -f "CLAUDE.md" ]; then
  grep -q '^@AGENTS\.md' CLAUDE.md || fail "CLAUDE.md does not import AGENTS.md — the shim needs a bare '@AGENTS.md' line (not in backticks or a fence), since AGENTS.md is the canonical constitution."
fi

# Token budget enforcement: prevent context bloat.
# AGENTS.md is the always-loaded constitution, so it carries the 120-line hard cap
# the template and setup-bootstrap document (target 60-80). The cap is enforced in
# BOTH lines and bytes: a 120-line file of wide markdown table rows can still reach
# tens of KB, so a line count alone does not bound what this costs every session.
agents_lines="$(wc -l < AGENTS.md | tr -d '[:space:]')"
[ "$agents_lines" -le 120 ] || fail "AGENTS.md exceeds 120-line hard cap ($agents_lines lines, target 60-80). Move detail to .claude/rules/ or .claude/references/"
agents_bytes="$(wc -c < AGENTS.md | tr -d '[:space:]')"
[ "$agents_bytes" -le 16000 ] || fail "AGENTS.md exceeds 16000-byte budget ($agents_bytes bytes). Wide table rows cost context even when the line count passes — move reference tables to .claude/references/"

# The shim is a handful of lines by construction; a large CLAUDE.md beside a
# canonical AGENTS.md means content leaked back into it.
if [ -f "CLAUDE.md" ]; then
  claude_lines="$(wc -l < CLAUDE.md | tr -d '[:space:]')"
  [ "$claude_lines" -le 30 ] || fail "CLAUDE.md exceeds the 30-line shim budget ($claude_lines lines). It must import AGENTS.md and carry only Claude-Code-specific notes."
fi

for skill in "${manifest_skill_paths[@]+"${manifest_skill_paths[@]}"}"; do
  skill_lines="$(wc -l < "$skill")"
  # Tech stack skills are larger — they carry scan recipes and full reference paths.
  # Entry-point skills (with allowed-tools) orchestrate full workflows, so 1000-line budget.
  # Phase-based workflow skills (ex-entry-points routed via /mtk) also get the 1000-line budget.
  if echo "$skill" | grep -q 'tech-stack-'; then
    [ "$skill_lines" -le 1000 ] || fail "Tech stack skill $skill exceeds 1000-line budget ($skill_lines lines). Split scan recipes or references into companion files."
  elif grep -q '^allowed-tools:' "$skill"; then
    [ "$skill_lines" -le 1000 ] || fail "Entry-point skill $skill exceeds 1000-line budget ($skill_lines lines). Split into core + companion files."
  elif grep -qE '^## (Phase [0-9]|STEP [0-9]|Process|Modes)' "$skill"; then
    [ "$skill_lines" -le 1000 ] || fail "Phase-based workflow skill $skill exceeds 1000-line budget ($skill_lines lines). Split into core + companion files."
  else
    [ "$skill_lines" -le 500 ] || fail "Skill $skill exceeds 500-line budget ($skill_lines lines). Split into core + reference files"
  fi
  # Char budget (S2.26): line counts under-report dense skills (115+ chars/line). Workflow
  # skills 20,000 chars; phase-structured / entry-point / tech-stack skills 35,000 chars.
  # WARN only in this release — becomes `fail` one release later.
  skill_chars="$(wc -c < "$skill" | tr -d ' ')"
  if echo "$skill" | grep -q 'tech-stack-' || grep -q '^allowed-tools:' "$skill" || grep -qE '^## (Phase [0-9]|STEP [0-9]|Process|Modes|Route Table)' "$skill"; then
    skill_char_cap=35000
  else
    skill_char_cap=20000
  fi
  [ "$skill_chars" -le "$skill_char_cap" ] || printf 'WARN: skill %s exceeds %d-char budget (%d chars) — move detail to a reference (S2.26)\n' "$(basename "$(dirname "$skill")")" "$skill_char_cap" "$skill_chars"
done

# Skill description budget (S2.5/S2.6): every skill `description` is injected into
# EVERY session — Claude Code reserves only ~1% of the context window for skill
# metadata, so on a 200K model the whole skill catalogue shares ~2K tokens. Cap each
# description and the aggregate so routing survives on smaller-context models and the
# always-on floor cannot silently drift upward as skills are added.
DESC_CHAR_CAP=200
DESC_TOTAL_BUDGET=7000
desc_total=0
for skill in "${manifest_skill_paths[@]+"${manifest_skill_paths[@]}"}"; do
  [ -f "$skill" ] || continue
  desc="$(awk '/^description:/ { sub(/^description:[[:space:]]*/, ""); print; exit }' "$skill")"
  desc_len=${#desc}
  [ "$desc_len" -le "$DESC_CHAR_CAP" ] || fail "Skill description too long ($desc_len > $DESC_CHAR_CAP chars): $skill — tighten to a keyword-dense 'what + when' sentence (S2.5/S2.6)."
  desc_total=$((desc_total + desc_len))
done
printf 'Skill descriptions: %d chars (~%d tokens) / %d-char budget.\n' "$desc_total" "$((desc_total / 4))" "$DESC_TOTAL_BUDGET"
[ "$desc_total" -le "$DESC_TOTAL_BUDGET" ] || fail "Skill descriptions exceed the aggregate budget ($desc_total > $DESC_TOTAL_BUDGET chars). They load into every session — tighten the longest ones."

if [ -d ".claude/rules" ]; then
  while IFS= read -r rule; do
    rule_lines="$(wc -l < "$rule")"
    [ "$rule_lines" -le 120 ] || fail "Rule file $rule exceeds 120-line budget ($rule_lines lines). Tighten wording or split"
  done < <(find .claude/rules -name '*.md' | sort)
fi

# The root-constitution ceiling now lives on AGENTS.md (see the budget block
# above). Checking CLAUDE.md here was vacuous post-inversion: it measures an
# ~11-line shim and can never fail, while the file that actually costs always-on
# context went unbounded.

# Every .claude/references/**/*.md must have description/globs/alwaysApply frontmatter.
# <(head …) not head|grep: grep -q exits on match, head takes SIGPIPE (141), and
# pipefail turns that success into a spurious failure blaming a random file —
# the same S3.1 flake class fixed in the shell-script scan above.
while IFS= read -r ref; do
  grep -q '^---$' <(head -1 "$ref") || fail "$ref missing YAML frontmatter"
  grep -q '^description:' <(head -20 "$ref") || fail "$ref frontmatter missing 'description:'"
  grep -q '^globs:' <(head -20 "$ref") || fail "$ref frontmatter missing 'globs:'"
  grep -q '^alwaysApply:' <(head -20 "$ref") || fail "$ref frontmatter missing 'alwaysApply:'"
done < <(find .claude/references -name '*.md' -type f | sort)

# References index must be in sync with frontmatter (only if it exists; gitignored).
if [ -f .claude/references.index ]; then
  bash scripts/build-references-index.sh --check
fi

# Router-decision fixtures (S3.10): validate JSON shape and gate names.
if [ -d tests/fixtures ] && ls tests/fixtures/*.json >/dev/null 2>&1; then
  bash scripts/run-fixtures.sh >/dev/null || fail "router-decision fixtures failed (run: bash scripts/run-fixtures.sh)"
fi

# Embedded-bash lint for skills — deterministic bug classes in fenced ```bash blocks.
require_file "scripts/lint-skill-bash.sh"
bash scripts/lint-skill-bash.sh || fail "skill bash lint failed (run: bash scripts/lint-skill-bash.sh)"

# Poison-floor supply-chain lint (borrow — assay poison floor; see P0#5). Scans the
# context-entering artifacts MTK ships (skills, agents, plugin hook config) for
# prompt-injection / credential-exfil / hidden-Unicode red flags. Hard FAIL on any
# P-* FAIL finding; advisory WARN findings do not fail the build.
require_file "scripts/poison-lint.sh"
bash scripts/poison-lint.sh --quiet || fail "poison-floor lint failed (run: bash scripts/poison-lint.sh)"

# Advisory: multi-sentence skill descriptions hurt routing (S2.5) — warn only, never fail.
for skill in .claude/skills/*/SKILL.md; do
  [ -f "$skill" ] || continue
  desc="$(awk '/^description:/ { sub(/^description:[[:space:]]*/, ""); print; exit }' "$skill")"
  if printf '%s' "$desc" | grep -qE '\. [A-Z]'; then
    printf 'WARN: multi-sentence description: %s\n' "$(basename "$(dirname "$skill")")"
  fi
done

# Advisory: section caps on workflow skills (S2.26 — a SKILL.md is a navigation layer).
# `## Verification` body > 8 non-blank lines; for `user-invocable: false` skills also
# `## Overview` body > 3 non-blank lines and `## When To Use` body > 5 bullets (lines
# starting with "- ", `### When NOT To Use` sub-bullets included). Warn only, never fail.
section_body() { awk -v h="## $2" '$0==h{p=1;next} /^## /{p=0} p' "$1"; }
for skill in .claude/skills/*/SKILL.md; do
  [ -f "$skill" ] || continue
  skill_name="$(basename "$(dirname "$skill")")"
  ver_lines="$(section_body "$skill" 'Verification' | grep -c '[^[:space:]]' || true)"
  [ "$ver_lines" -le 8 ] || printf 'WARN: skill %s ## Verification has %d non-blank lines (cap 8) — fold prose into the Workflow step it verifies\n' "$skill_name" "$ver_lines"
  if grep -qE '^user-invocable:[[:space:]]*false' "$skill"; then
    ov_lines="$(section_body "$skill" 'Overview' | grep -c '[^[:space:]]' || true)"
    [ "$ov_lines" -le 3 ] || printf 'WARN: skill %s ## Overview has %d non-blank lines (cap 3 for user-invocable: false) — the frontmatter description already says what it is\n' "$skill_name" "$ov_lines"
    wtu_bullets="$(section_body "$skill" 'When To Use' | grep -c '^- ' || true)"
    [ "$wtu_bullets" -le 5 ] || printf 'WARN: skill %s ## When To Use has %d bullets (cap 5 for user-invocable: false) — keep routing-relevant conditions only\n' "$skill_name" "$wtu_bullets"
  fi
done

# Least-privilege for agents (S1.7). Claude Code enforces the `tools:` frontmatter key on
# agent definitions — `allowed-tools:` is a skill-frontmatter key; an agent that only declares `allowed-tools` runs with EVERY tool, and its spawn
# carries every tool schema, every MCP tool name, and the whole skill roster (~35k extra
# tokens measured on a loaded machine). So `tools:` is REQUIRED on every agent and must not
# grant a mutating tool, `Agent`, or `Skill` — reviewers are read-only and never re-dispatch.
for agent in .claude/agents/*.md; do
  [ -f "$agent" ] || continue
  agent_name="$(basename "$agent" .md)"
  fm="$(awk 'NR==1&&$0!="---"{exit} /^---[[:space:]]*$/{c++; if(c==2)exit; next} c==1{print}' "$agent")"
  tools_line="$(printf '%s\n' "$fm" | awk -F: '/^tools:/{sub(/^[^:]*:[[:space:]]*/,"");print;exit}')"
  [ -n "$tools_line" ] \
    || fail "agent $agent_name has no 'tools:' frontmatter — Claude Code ignores allowed-tools on agents, so this agent would run with every tool and pay for every schema/MCP/skill in its spawn (S1.7)"
  if printf '%s' "$tools_line" | grep -qE '\b(Edit|Write|MultiEdit|NotebookEdit|Agent|Skill|Workflow)\b'; then
    fail "agent $agent_name grants a mutating or dispatching tool in tools: ($tools_line) — reviewers are read-only and never re-dispatch (S1.7)"
  fi
done

# Advisory: frontmatter enum sanity on agents (borrow — schema-validated frontmatter).
# Catch typo'd model/effort tiers early. Warn only, never fail.
for agent in .claude/agents/*.md; do
  [ -f "$agent" ] || continue
  agent_name="$(basename "$agent" .md)"
  model="$(awk -F: '/^model:/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$agent")"
  effort="$(awk -F: '/^effort:/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$agent")"
  case "${model:-}" in ''|opus|sonnet|haiku|fable|inherit) : ;; *) printf 'WARN: agent %s has unexpected model tier "%s" (expected opus|sonnet|haiku|fable|inherit)\n' "$agent_name" "$model" ;; esac
  case "${effort:-}" in ''|low|medium|high|max) : ;; *) printf 'WARN: agent %s has unexpected effort "%s" (expected low|medium|high|max)\n' "$agent_name" "$effort" ;; esac
done

printf 'Toolkit validation passed.\n'
