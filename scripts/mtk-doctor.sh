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
# .gitignore, lessons, context baseline, environment fit, tech stack) describe the
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
USAGE_MODE=0
for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    --fix) FIX=1 ;;
    --strict) STRICT=1 ;;
    --usage) USAGE_MODE=1 ;;
    -h|--help)
      cat <<USAGE
Usage: mtk-doctor [--json] [--fix] [--strict] [--usage]

  --json    Machine-readable output for CI dashboards
  --fix     Auto-fix safe items: gitignore additions, chmod +x, moving the
            invalid permissions.allowedTools key into permissions.allow, and
            merging missing permission-baseline deny/ask rules into
            .claude/settings.json. Any other FAIL is reported, never auto-fixed.
  --strict  Exit non-zero on WARN as well as FAIL
  --usage   Report raw usage numbers instead of health checks: the
            .claude/analytics.json counters (n = sessions), spec/plan/lesson
            counts, learnings.sh decision-origin totals, eval cases, and
            shadow-mode guard decisions per hook and code
            (.mtk/metrics/enforcement-shadow.jsonl). No thresholds, no
            verdicts. Read-only; combine with --json.
USAGE
      exit 0
      ;;
    *) printf 'Unknown flag: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# ──────────────────────────────────────────────
# USAGE MODE (--usage) — raw numbers, no thresholds
# ──────────────────────────────────────────────
# Healthy-range thresholds were never calibrated against real usage, so this
# mode reports counts with their n and leaves the judgement to the reader. Read-only: it never writes a file.
if [ "$USAGE_MODE" -eq 1 ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'mtk-doctor --usage needs python3\n' >&2; exit 2
  fi
  in_project
  METRICS_JSON=""
  if [ -f "$ROOT_DIR/scripts/learnings.sh" ]; then
    METRICS_JSON="$(bash "$ROOT_DIR/scripts/learnings.sh" metrics 2>/dev/null || true)"
  fi
  EVALS_DIR=""
  [ -d "$ROOT_DIR/evals" ] && EVALS_DIR="$ROOT_DIR/evals"
  # Shadow-mode guards (mtk_deny_gated) log under the hooks' project root:
  # $CLAUDE_PROJECT_DIR when the harness set it, else the git top level — not
  # necessarily the directory the doctor was invoked from.
  SHADOW_ROOT="${CLAUDE_PROJECT_DIR:-}"
  [ -n "$SHADOW_ROOT" ] && [ -d "$SHADOW_ROOT" ] || SHADOW_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  SHADOW_LOG="$SHADOW_ROOT/.mtk/metrics/enforcement-shadow.jsonl"
  python3 - "$JSON" "$METRICS_JSON" "$EVALS_DIR" "$SHADOW_LOG" <<'PY'
import glob, json, os, re, sys
sys.stdout.reconfigure(newline="\n")  # LF even on Windows python3
as_json, metrics_raw, evals_dir, shadow_log = sys.argv[1] == "1", sys.argv[2], sys.argv[3], sys.argv[4]
out = {}
a_path = ".claude/analytics.json"
if not os.path.isfile(a_path):
    out["analytics"] = {"status": "absent", "detail": "created by the Stop recorder after the first session"}
else:
    try:
        with open(a_path, encoding="utf-8") as fh:
            a = json.load(fh)
        out["analytics"] = {"status": "ok", "n_sessions": a.get("sessions", 0)}
        out["analytics"].update({k: v for k, v in a.items() if k != "sessions"})
    except (OSError, ValueError) as e:
        out["analytics"] = {"status": "unparseable", "detail": str(e)}
lessons = 0
if os.path.isfile("tasks/lessons.md"):
    with open("tasks/lessons.md", encoding="utf-8", errors="replace") as fh:
        lessons = sum(1 for line in fh if line.startswith("## "))
out["artifacts"] = {"specs": len(glob.glob("docs/specs/*.md")), "plans": len(glob.glob("docs/plans/*.md")),
                    "lessons_md_entries": lessons}
if metrics_raw.strip():
    try:
        m = json.loads(metrics_raw)
        t = m.get("totals", {})
        n = sum(t.get(k, 0) for k in ("claude-recommended-approved", "claude-recommended-modified",
                                      "claude-recommended-rejected"))
        out["decision_origin"] = {"window_days": m.get("window_days"), "totals": t,
                                  "n_recommendations": n, "pi": m.get("pi")}
    except ValueError:
        out["decision_origin"] = {"status": "unparseable"}
else:
    out["decision_origin"] = {"status": "unavailable"}
if evals_dir:
    tags = {}
    cases = glob.glob(os.path.join(evals_dir, "*", "prompt.md"))
    for c in cases:
        with open(c, encoding="utf-8", errors="replace") as fh:
            front = fh.read(4000).split("\n---", 1)[0]
        for tag in sorted(set(re.findall(r"\b(smoke|core)\b", front))):
            tags[tag] = tags.get(tag, 0) + 1
    ev = {"cases": len(cases), "tags": tags}
    runs = sorted(glob.glob(os.path.join(evals_dir, "results", "*", "aggregate-result.json")), key=os.path.getmtime)
    if runs:
        try:
            with open(runs[-1], encoding="utf-8") as fh:
                r = json.load(fh)
            g = r.get("aggregates", {})
            ev["latest_run"] = {"file": os.path.relpath(runs[-1], evals_dir), "overallScore": g.get("overallScore"),
                                "casesPassed": g.get("casesPassed"), "casesTotal": g.get("casesTotal"),
                                "meanDelta": g.get("meanDelta"), "partial": r.get("partial", g.get("partial"))}
        except (OSError, ValueError):
            ev["latest_run"] = {"status": "unparseable"}
    out["evals"] = ev
# Would-have-denied decisions of guards running in shadow mode, counted per hook
# and code. Raw counts only: whether a code is ready for `active` is the reader's call.
if not os.path.isfile(shadow_log):
    out["enforcement_shadow"] = {"status": "absent", "detail": "written only by a guard running in shadow mode"}
else:
    by_hook, total, bad = {}, 0, 0
    try:
        with open(shadow_log, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if not line.strip():
                    continue
                try:
                    ev_ = json.loads(line)
                    hook, code = str(ev_.get("hook") or "?"), str(ev_.get("code") or "?")
                except (ValueError, AttributeError):
                    bad += 1
                    continue
                by_hook.setdefault(hook, {})
                by_hook[hook][code] = by_hook[hook].get(code, 0) + 1
                total += 1
        out["enforcement_shadow"] = {"status": "ok", "n_events": total, "by_hook": by_hook,
                                     "unparseable_lines": bad}
    except OSError as e:
        out["enforcement_shadow"] = {"status": "unreadable", "detail": str(e)}
if as_json:
    print(json.dumps(out, sort_keys=True))
else:
    for section, body in out.items():
        print(section.upper())
        for k, v in body.items():
            print(f"  {k}: {json.dumps(v) if isinstance(v, (dict, list)) else v}")
        print()
    print("Raw counts with their n. A ratio over fewer than ~20 sessions or ~10 recommendations is noise.")
PY
  exit 0
fi

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

# $CLAUDE_PLUGIN_ROOT is set only for hooks a plugin declares in its own
# hooks/hooks.json. In a project's settings file it expands to the empty string,
# so `bash $CLAUDE_PLUGIN_ROOT/hooks/x.sh` runs as `bash /hooks/x.sh` and fails
# on every matching tool call ("No such file or directory"). Earlier bootstraps
# wrote exactly these entries; the plugin already wires the same hooks itself, so
# removing them loses nothing. --fix strips them (other hooks are kept).
for sf in .claude/settings.json .claude/settings.local.json; do
  [ -f "$sf" ] || continue
  command -v python3 >/dev/null 2>&1 || break
  pr_mode=check; [ "$FIX" -eq 1 ] && pr_mode=fix
  pr_out="$(python3 - "$sf" "$pr_mode" <<'PY' 2>/dev/null || true
import json, os, sys, tempfile
sys.stdout.reconfigure(newline="\n")
path, mode = sys.argv[1], sys.argv[2]
try:
    doc = json.load(open(path))
except (OSError, ValueError):
    sys.exit(0)
hooks = doc.get("hooks") if isinstance(doc, dict) else None
if not isinstance(hooks, dict):
    sys.exit(0)
bad = []
for event, groups in list(hooks.items()):
    if not isinstance(groups, list):
        continue
    kept_groups = []
    for g in groups:
        hs = g.get("hooks", []) if isinstance(g, dict) else []
        kept = [h for h in hs if "CLAUDE_PLUGIN_ROOT" not in str(h.get("command", ""))]
        bad += ["%s: %s" % (event, h.get("command", "")) for h in hs if h not in kept]
        if kept:
            g["hooks"] = kept
            kept_groups.append(g)
    if kept_groups:
        hooks[event] = kept_groups
    else:
        del hooks[event]
if not bad:
    sys.exit(0)
if mode == "fix":
    if not hooks:
        del doc["hooks"]
    target = os.path.realpath(path)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target))
    with os.fdopen(fd, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    os.chmod(tmp, os.stat(target).st_mode & 0o777)
    os.replace(tmp, target)
    print("fixed")
for b in bad:
    print(b)
PY
)"
  [ -n "$pr_out" ] || continue
  if [ "$(awk 'NR==1' <<<"$pr_out")" = "fixed" ]; then
    record PASS hooks "removed broken \$CLAUDE_PLUGIN_ROOT hooks from $sf" "$(awk 'NR>1' <<<"$pr_out" | tr '\n' ';' | sed 's/;$//')"
  else
    record FAIL hooks "$sf wires hooks through \$CLAUDE_PLUGIN_ROOT" "$(tr '\n' ';' <<<"$pr_out" | sed 's/;$//') — that variable is empty outside plugin hooks, so these run as /hooks/… and fail on every call; the plugin already wires them. Run with --fix to remove them."
  fi
done

while IFS= read -r line; do
  cmd="$(printf '%s' "$line" | sed 's/^.*"command": *"//; s/".*$//')"
  # Reported by the $CLAUDE_PLUGIN_ROOT check above; never resolvable here.
  case "$cmd" in *CLAUDE_PLUGIN_ROOT*) continue ;; esac
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

# Permission baseline (.claude/references/settings-baseline.md): the native
# deny/ask rules that replaced read-guard.sh's secret-file denies. Repos
# bootstrapped before 8.1.0 carry none of them, so a secret file is readable
# there with no guard at all. WARN listing what is missing; --fix unions the
# baseline into .claude/settings.json with merge-settings.sh (existing keys and
# rules are kept).
DOCTOR_BASELINE="$ROOT_DIR/scripts/settings-baseline.sh"
[ -f "$DOCTOR_BASELINE" ] || DOCTOR_BASELINE="${CLAUDE_PLUGIN_ROOT:-.}/scripts/settings-baseline.sh"
if [ ! -f "$DOCTOR_BASELINE" ]; then
  record WARN permissions "permission baseline not checked" "settings-baseline.sh not found (looked in $ROOT_DIR/scripts and \${CLAUDE_PLUGIN_ROOT}/scripts)"
else
  bl_rc=0
  bl_out="$(bash "$DOCTOR_BASELINE" --missing .claude/settings.json 2>&1)" || bl_rc=$?
  if [ "$bl_rc" -eq 1 ] && [ "$FIX" -eq 1 ]; then
    bl_n="$(grep -c "$(printf '\t')" <<<"$bl_out" || true)"
    fix_rc=0
    fix_out="$(bash "$DOCTOR_BASELINE" --merge .claude/settings.json 2>&1)" || fix_rc=$?
    if [ "$fix_rc" -eq 0 ]; then
      record PASS permissions "permission baseline merged" "${bl_n} missing deny/ask rule(s) added to .claude/settings.json via merge-settings.sh"
      bl_rc=0
      bl_out="$(bash "$DOCTOR_BASELINE" --missing .claude/settings.json 2>&1)" || bl_rc=$?
    else
      record FAIL permissions "permission baseline merge failed" "settings-baseline.sh --merge exited $fix_rc: $(awk 'NR==1' <<<"$fix_out")"
    fi
  fi
  case "$bl_rc" in
    0) record PASS permissions "permission baseline present" "every deny/ask rule in settings-baseline.md is in .claude/settings.json" ;;
    1) record WARN permissions "missing baseline permission rules" "$(grep -c "$(printf '\t')" <<<"$bl_out" || true) rule(s) absent from .claude/settings.json: $(awk -F'\t' 'NF==2{printf "%s %s; ", $1, $2}' <<<"$bl_out")— run with --fix, or /mtk-setup --refresh to review them" ;;
    *) record WARN permissions "permission baseline not checked" "settings-baseline.sh --missing exited $bl_rc: $(awk 'NR==1' <<<"$bl_out")" ;;
  esac
fi

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

# No hook on the hot path (S3.6): nothing on UserPromptSubmit, and no tool
# matcher that fires on Read/Grep/Glob or on MCP calls. Each of those runs a
# process on every prompt or read for advice current models do not need; the
# runtime diet removed them all, and this keeps one from being re-added. A
# matcher is judged as the regex Claude Code applies, so `Read|Edit`, `.*` and a
# missing matcher (match-all) all count.
# The classifier is shared with validate-toolkit (hooks/lib/hot_path_matchers.py),
# so the two locks cannot disagree.
HOT_PATH_LIB="hooks/lib/hot_path_matchers.py"
if [ -f hooks/hooks.json ] && command -v python3 >/dev/null 2>&1; then
  if [ ! -f "$HOT_PATH_LIB" ]; then
    record WARN hooks "hot-path check skipped" "$HOT_PATH_LIB not found in $ROOT_DIR"
  else
    hp_rc=0
    HOT_PATH="$(python3 "$HOT_PATH_LIB" hooks/hooks.json 2>&1)" || hp_rc=$?
    if [ "$hp_rc" -eq 0 ]; then
      record PASS hooks "no hot-path hooks registered" "hooks/hooks.json has no UserPromptSubmit hook and no Read/Grep/Glob/MCP matcher"
    else
      while IFS=$'\t' read -r where why; do
        [ -n "$where" ] || continue
        record FAIL hooks "hot-path hook registered" "${where} — ${why}; hooks/hooks.json must keep the read path, MCP calls and prompts hook-free (S3.6)"
      done <<< "$HOT_PATH"
    fi
  fi
fi

# Hook liveness. Every registered hook refreshes a stamp in
# ${TMPDIR:-/tmp}/mtk-hook-seen-<uid>/<project root, sanitised>/<hook file name>
# (mtk_hook_seen in hooks/lib/hook-io.sh; the directory comes from the same
# helper, so the two cannot disagree on the path), and session-start counts each
# `startup` in <stamp dir>/.sessions (mtk_liveness_tick). The hook set is every
# command registered in hooks/hooks.json — no hand list to drift: SubagentStart
# hooks are event-rare (info only), every other hook fires in nearly every
# session. Once .sessions counts >= 5 sessions, a per-call hook with no stamp, or
# with a stamp more than 14 days older than the last session tick (the mtime of
# .sessions — not "now", so an idle repo whose hooks all ran in its last session
# is not stale), is WARNed — unregistered, crashing before its stamp, or
# switched off. A missing .sessions file counts as 0. No stamp
# directory (TMPDIR cleared or different from the hooks', or nothing has fired
# yet) is "unknown", and no python3 / unreadable hooks.json is "not checked" —
# never WARN.
LIVE_IO="$ROOT_DIR/hooks/lib/hook-io.sh"
LIVE_HJ="$ROOT_DIR/hooks/hooks.json"
LIVE_STALE_DAYS=14
LIVE_PER_CALL=() LIVE_RARE=()
live_why=""
if ! command -v python3 >/dev/null 2>&1; then
  live_why="python3 not found — the hook set is read from hooks/hooks.json"
elif [ ! -f "$LIVE_HJ" ]; then
  live_why="$LIVE_HJ not found"
else
  live_rc=0
  LIVE_SET="$(python3 - "$LIVE_HJ" <<'PY' 2>&1
import sys; sys.stdout.reconfigure(newline="\n")  # LF even on Windows python3: bash parses this output
import json, os
out, seen = [], set()
try:
    for event, entries in json.load(open(sys.argv[1]))["hooks"].items():
        for entry in entries:
            for h in entry.get("hooks", []):
                tok = str(h.get("command", "")).split()
                if tok and tok[0] in ("bash", "sh", "zsh"):
                    tok = tok[1:]
                base = os.path.basename(tok[0].strip("\"'")) if tok else ""
                if base and base not in seen:
                    seen.add(base)
                    out.append(("rare" if event == "SubagentStart" else "per-call") + "\t" + base)
except Exception as e:  # one readable line for the doctor, not a traceback
    print("%s: %s" % (type(e).__name__, e))
    sys.exit(1)
print("\n".join(out))
PY
)" || live_rc=$?
  if [ "$live_rc" -ne 0 ]; then
    live_why="could not read the hook set from $LIVE_HJ: $(awk 'NF { print; exit }' <<<"$LIVE_SET")"
  else
    while IFS=$'\t' read -r kind base; do
      [ -n "$base" ] || continue
      case "$kind" in
        rare) LIVE_RARE+=("$base") ;;
        *) LIVE_PER_CALL+=("$base") ;;
      esac
    done <<< "$LIVE_SET"
    [ "$(( ${#LIVE_PER_CALL[@]} + ${#LIVE_RARE[@]} ))" -gt 0 ] || live_why="$LIVE_HJ registers no hook command"
  fi
fi
LIVE_DIR=""
if [ -z "$live_why" ] && [ -f "$LIVE_IO" ]; then
  LIVE_DIR="$(cd "$DOCTOR_PROJECT_DIR" && CLAUDE_PROJECT_DIR="$DOCTOR_PROJECT_DIR" bash -c '. "$1" && mtk_hook_seen_dir' _ "$LIVE_IO" 2>/dev/null)" || LIVE_DIR=""
fi
if [ -n "$live_why" ]; then
  record PASS hooks "hook liveness not checked" "${live_why//$'\t'/ }"
elif [ -z "$LIVE_DIR" ] || [ ! -d "$LIVE_DIR" ]; then
  record PASS hooks "hook liveness unknown" "no stamp directory ${LIVE_DIR:-(unresolved)} — no hook has run under this TMPDIR yet, or it was cleared; not a failure"
else
  LIVE_SESSIONS=0
  if [ -f "$LIVE_DIR/.sessions" ]; then
    live_line=""
    { IFS= read -r live_line < "$LIVE_DIR/.sessions"; } 2>/dev/null || true
    case "$live_line" in
      ''|*[!0-9]*) LIVE_SESSIONS=0 ;;
      *) [ "${#live_line}" -le 9 ] && LIVE_SESSIONS=$((10#$live_line)) || LIVE_SESSIONS=0 ;;
    esac
  fi
  # Stamps refreshed within the window, measured back from the last session tick
  # (mtime of .sessions; now when there is none — the >= 5 gate cannot fire then
  # anyway). python3 is known present here: the hook set needed it. One call for
  # the whole directory, then a lookup per hook.
  live_age_ok=1
  live_found="$(python3 - "$LIVE_DIR" "$LIVE_STALE_DAYS" <<'PY' 2>/dev/null
import os, sys, time
d, days = sys.argv[1], float(sys.argv[2])
try:
    ref = os.stat(os.path.join(d, ".sessions")).st_mtime
except OSError:
    ref = time.time()
for n in os.listdir(d):
    p = os.path.join(d, n)
    if os.path.isfile(p) and os.stat(p).st_mtime >= ref - days * 86400:
        print(n)
PY
)" || { live_found=""; live_age_ok=0; }
  live_fresh=" "
  while IFS= read -r live_f; do
    if [ -n "$live_f" ]; then live_fresh="$live_fresh${live_f##*/} "; fi
  done <<< "$live_found"
  live_seen=() live_unseen=() live_stale=() rare_seen=() rare_unseen=()
  for h in ${LIVE_PER_CALL[@]+"${LIVE_PER_CALL[@]}"}; do
    case "$live_fresh" in
      *" $h "*) live_seen+=("${h%.sh}") ;;
      *)
        if [ ! -e "$LIVE_DIR/$h" ]; then live_unseen+=("${h%.sh}")
        elif [ "$live_age_ok" -eq 1 ]; then live_stale+=("${h%.sh}")
        else live_seen+=("${h%.sh}")   # age unknown: presence only, never stale
        fi ;;
    esac
  done
  for h in ${LIVE_RARE[@]+"${LIVE_RARE[@]}"}; do
    case "$live_fresh" in
      *" $h "*) rare_seen+=("${h%.sh}") ;;
      *) rare_unseen+=("${h%.sh}") ;;
    esac
  done
  if [ "$live_age_ok" -eq 0 ]; then
    record PASS hooks "hook stamp age not checked" "could not read stamp mtimes in $LIVE_DIR; stamps judged by presence only"
  fi
  if [ "${#LIVE_PER_CALL[@]}" -eq 0 ]; then
    record PASS hooks "per-call hooks: none registered" "hooks/hooks.json registers only SubagentStart hooks"
  elif [ "${#live_unseen[@]}" -eq 0 ] && [ "${#live_stale[@]}" -eq 0 ]; then
    record PASS hooks "per-call hooks alive" "all ${#live_seen[@]} per-call hooks registered in hooks/hooks.json left a liveness stamp in $LIVE_DIR within ${LIVE_STALE_DAYS} days of the last session"
  elif [ "$LIVE_SESSIONS" -ge 5 ]; then
    for h in ${live_unseen[@]+"${live_unseen[@]}"}; do
      record WARN hooks "hook not seen: $h" "no liveness stamp in $LIVE_DIR although $LIVE_DIR/.sessions counts ${LIVE_SESSIONS} sessions — check it is registered in hooks/hooks.json, not crashing, and not switched off"
    done
    for h in ${live_stale[@]+"${live_stale[@]}"}; do
      record WARN hooks "hook stale: $h" "its liveness stamp in $LIVE_DIR is more than ${LIVE_STALE_DAYS} days older than the last session tick ($LIVE_DIR/.sessions), which counts ${LIVE_SESSIONS} sessions — it stopped running: check it is still registered, not crashing, and not switched off"
    done
  else
    record PASS hooks "per-call hooks not seen yet" "not seen: ${live_unseen[*]:-none}; stale (> ${LIVE_STALE_DAYS} days before the last session): ${live_stale[*]:-none} — but $LIVE_DIR/.sessions counts only ${LIVE_SESSIONS} session(s) (< 5), too few to judge"
  fi
  if [ "${#LIVE_RARE[@]}" -gt 0 ]; then
    live_rare_note="seen: ${rare_seen[*]:-none}; not seen: ${rare_unseen[*]:-none} — SubagentStart hooks fire only when a subagent starts, so absence is not a failure"
    case " ${LIVE_RARE[*]} " in
      *" subagent-context.sh "*)
        live_rare_note="$live_rare_note. A subagent-context stamp proves the hook ran, not that the subagent saw its text: this check cannot tell 'not fired' from 'fired but invisible to the model' — confirm with the manual SubagentStart check in the PR that added subagent-context.sh" ;;
    esac
    record PASS hooks "event-rare hooks (info)" "$live_rare_note"
  fi
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
  .claude/references/domain-finance.md
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
# is `lessons refresh`'s job and always a human decision.
if [ -f tasks/lessons.md ] && [ -f scripts/lesson-anchors.sh ]; then
  ANCHOR_SUMMARY="$(bash scripts/lesson-anchors.sh 2>/dev/null | tail -1 || true)"
  case "$ANCHOR_SUMMARY" in
    *' 0 stale'*) record PASS integrity "lesson anchors live" "$ANCHOR_SUMMARY" ;;
    *stale*)      record WARN integrity "stale lesson anchors" "$ANCHOR_SUMMARY — run 'bash scripts/lesson-anchors.sh' for locations, then '/lessons refresh' to triage" ;;
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
# (CLAUDE.md + a loaded AGENTS.md + alwaysApply references + the project's MCP tool schemas).
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
    "~${ctx_tokens} tokens (${ctx_lines} lines / ${ctx_bytes} bytes): CLAUDE.md + ${CTX_AGENTS}${ALWAYSON_REFS} alwaysApply ref(s)"
else
  record PASS context "always-on context baseline" \
    "no always-on files found (CLAUDE.md / AGENTS.md absent — likely the source repo)"
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

# Instruction load: files a harness silently drops, truncates or ignores
# (scripts/check-instruction-load.sh — Codex byte cap, AGENTS.md shadowed by
# CLAUDE.md, Cursor `globs:` in Claude rules, CLAUDE.local.md not ignored). One
# WARN per finding. A missing script, exit 2 (bad env, resolver missing, or a
# sub-check that could not run with nothing found) or exit 1 with no finding
# printed is reported as "not checked" — never as a clean result — with the
# script's first stderr line as the reason. Exit 1 with a stderr line as well is
# findings plus a "partly not checked" row.
CIL="$ROOT_DIR/scripts/check-instruction-load.sh"
if [ ! -f "$CIL" ]; then
  record PASS context "instruction load not checked" "scripts/check-instruction-load.sh not found in $ROOT_DIR"
else
  cil_rc=0 CIL_ERR="" cil_err_f=""
  cil_err_f="$(mktemp "${TMPDIR:-/tmp}/mtk-doctor-cil.XXXXXX" 2>/dev/null)" || cil_err_f=""
  if [ -n "$cil_err_f" ]; then
    CIL_OUT="$(bash "$CIL" --root "$DOCTOR_PROJECT_DIR" 2>"$cil_err_f")" || cil_rc=$?
    CIL_ERR="$(awk 'NF { print; exit }' "$cil_err_f" 2>/dev/null)" || CIL_ERR=""
    rm -f "$cil_err_f"
  else
    CIL_OUT="$(bash "$CIL" --root "$DOCTOR_PROJECT_DIR" 2>/dev/null)" || cil_rc=$?
    CIL_ERR="(stderr not captured: mktemp failed)"
  fi
  CIL_ERR="${CIL_ERR//$'\t'/ }"
  case "$cil_rc" in
    0) record PASS context "instruction load" "no instruction file is dropped, truncated or ignored by a harness" ;;
    1)
      cil_n=0
      while IFS= read -r finding; do
        [ -n "$finding" ] || continue
        cil_n=$((cil_n + 1))
        record WARN context "instruction load: ${finding%% *}" "${finding#* }"
      done <<< "$CIL_OUT"
      if [ "$cil_n" -eq 0 ]; then
        record PASS context "instruction load not checked" "check-instruction-load.sh exited 1 but printed no finding${CIL_ERR:+: $CIL_ERR}"
      elif [ -n "$CIL_ERR" ]; then
        record PASS context "instruction load partly not checked" "$CIL_ERR"
      fi
      ;;
    *) record PASS context "instruction load not checked" "check-instruction-load.sh exited ${cil_rc}: ${CIL_ERR:-no stderr output}" ;;
  esac
fi

# ──────────────────────────────────────────────
# ENVIRONMENT
# ──────────────────────────────────────────────
# Structural checks answer "is MTK installed correctly". These answer "does this
# install fit the machine it is running on" — the class of problem where every
# file is present, every version matches, and the toolkit still misbehaves
# because a knob is calibrated for someone else's setup or a binary is absent.

# 1. Hook basename also wired in the user's global settings. Two different
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

# 1b. Hooks registered twice: plugin hooks/hooks.json + project
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

# 1c. Stale plugin-cache versions. installed_plugins.json records ONE installPath
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

# 2. Formatter present for the active stack. format-on-edit.sh never blocks and
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
# CONFIG — what is active (the old /mtk status report)
# ──────────────────────────────────────────────
# Report-only except for two WARNs: a stack or domain the project names with no
# skill or linter pack behind it silently loads nothing.
in_project
CFG_STACK=""
[ -f ".claude/tech-stack" ] && CFG_STACK="$(tr -d '[:space:]' < .claude/tech-stack)"
CFG_DOMAINS=""
[ -f ".claude/domains" ] && CFG_DOMAINS="$(grep -v '^[[:space:]]*#' .claude/domains | tr -d '[:blank:]' | grep -v '^$' || true)"
in_toolkit
count_rules() { grep -c '^[^#[:space:]]' "$1" 2>/dev/null || true; }
if [ -z "$CFG_STACK" ]; then
  record PASS config "tech stack not set" "no .claude/tech-stack — run /mtk-setup"
elif [ -f ".claude/skills/tech-stack-${CFG_STACK}/SKILL.md" ]; then
  record PASS config "tech stack ${CFG_STACK}" "skill tech-stack-${CFG_STACK} present"
else
  record WARN config "tech stack ${CFG_STACK} has no skill" "no .claude/skills/tech-stack-${CFG_STACK}/SKILL.md, so no stack context loads"
fi
for pack_dir in hooks/linter-patterns/core ${CFG_STACK:+hooks/linter-patterns/stack-$CFG_STACK}; do
  [ -d "$pack_dir" ] || continue
  for f in "$pack_dir"/*.txt; do
    [ -f "$f" ] && record PASS config "linter pack ${f#hooks/linter-patterns/}" "$(count_rules "$f") rules"
  done
done
if [ -n "$CFG_DOMAINS" ]; then
  while IFS= read -r d; do
    if [ -d "hooks/linter-patterns/domain-$d" ]; then
      for f in hooks/linter-patterns/domain-"$d"/*.txt; do
        [ -f "$f" ] && record PASS config "linter pack ${f#hooks/linter-patterns/}" "$(count_rules "$f") rules"
      done
    else
      record WARN config "domain ${d} has no linter pack" "listed in .claude/domains but hooks/linter-patterns/domain-${d}/ is missing"
    fi
  done <<< "$CFG_DOMAINS"
fi
for agent in .claude/agents/*.md; do
  [ -f "$agent" ] || continue
  a_model="$(grep -m1 '^model:' "$agent" | sed 's/model:[[:space:]]*//' || true)"
  record PASS config "agent $(basename "$agent" .md)" "model: ${a_model:-inherit}"
done

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
