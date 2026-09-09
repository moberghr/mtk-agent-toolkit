#!/usr/bin/env bash
set -euo pipefail

# build-context-pack.sh — write the per-run context pack every implementer and
# reviewer subagent reads INSTEAD of CLAUDE.md + the tech-stack skill + every
# coding-guideline file.
#
# Usage:
#   bash scripts/build-context-pack.sh <uuid> <sidecar.json> [--stack <name>] [--out <path>] [--dry-run] [--no-change-map]
#
# Writes .mtk/workflows/<uuid>/context-pack.md (project-anchored: $CLAUDE_PROJECT_DIR,
# else git top-level, else cwd) and prints `context-pack: <path> (<bytes> bytes)`.
# --dry-run prints the section inventory and byte count without writing.
#
# Contents, in order:
#   1. header (uuid, generated-at, sidecar path, stack)
#   2. build/test/format commands — the tech-stack skill's `## Build & Test Commands`
#      and `## Format Command` sections, verbatim
#   3. CLAUDE.md `## Critical Rules` verbatim; every other `##` heading as a one-line TOC
#   4. coding guidelines — the sections whose headings match the KIND of files in the
#      sidecar's change_manifest (handler/entity/test/api keyword table below), plus a
#      TOC of every guideline heading with its path so a subagent can pull one on demand
#   5. architecture-principles.md lines tagged [EXTRACTED]
#   6. tasks/lessons.md entries that mention a change_manifest path segment or stem (≤10)
#   7. change map — per manifest file, the symbols it declares (types, public methods,
#      defs, exports) and the tracked files that reference each (`git grep -w`, generated
#      and minified files excluded). Built once so reviewer lanes read one call graph
#      instead of each re-deriving it (a 2026-09 field run lost ~1/3 of reviewer tokens
#      to that duplication). `--no-change-map` or MTK_CONTEXT_PACK_CHANGE_MAP=0 omits it.
#
# Why: a fixed ~63k-char preamble re-read per implementer (and ~107k per compliance
# lane) was ~7% of a field run's tokens and most of each subagent's startup time.
# The pack is built once after the plan exists, when the change_manifest is known.
#
# Env:
#   MTK_HELPER_ROOT / CLAUDE_PLUGIN_ROOT  where MTK skills+references live when not in-project
#   MTK_CONTEXT_PACK_WARN_BYTES           warn threshold (default 30000)
#   MTK_CONTEXT_PACK_CHANGE_MAP           0 disables section 7 (default 1)

ROOT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WARN_BYTES="${MTK_CONTEXT_PACK_WARN_BYTES:-30000}"

fail() { printf 'build-context-pack: %s\n' "$1" >&2; exit 1; }

UUID="${1:-}"; SIDECAR="${2:-}"
[ -n "$UUID" ] || fail "usage: build-context-pack.sh <uuid> <sidecar.json> [--stack <name>] [--out <path>] [--dry-run]"
[ -n "$SIDECAR" ] || fail "sidecar path required"
[ -f "$SIDECAR" ] || fail "sidecar not found: $SIDECAR"
shift 2

STACK=""; OUT=""; DRY=0; CHANGE_MAP="${MTK_CONTEXT_PACK_CHANGE_MAP:-1}"
while [ $# -gt 0 ]; do
  case "$1" in
    --stack) STACK="${2:?--stack needs a value}"; shift 2 ;;
    --out) OUT="${2:?--out needs a value}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --no-change-map) CHANGE_MAP=0; shift ;;
    *) fail "unknown flag: $1" ;;
  esac
done

# MTK root: pinned checkout → project copy → plugin cache (same order as the skills).
MTK_ROOT=""
for cand in "${MTK_HELPER_ROOT:-}" "$ROOT_DIR" "${CLAUDE_PLUGIN_ROOT:-}" "$(cd "$SCRIPT_DIR/.." && pwd)"; do
  [ -n "$cand" ] && [ -d "$cand/.claude/skills" ] && { MTK_ROOT="$cand"; break; }
done
[ -n "$MTK_ROOT" ] || fail "cannot locate MTK skills (set MTK_HELPER_ROOT or CLAUDE_PLUGIN_ROOT)"

# Stack: flag → resolver → .claude/tech-stack
if [ -z "$STACK" ]; then
  if [ -x "$MTK_ROOT/scripts/resolve-tech-stack.sh" ]; then
    STACK="$(bash "$MTK_ROOT/scripts/resolve-tech-stack.sh" "$ROOT_DIR" 2>/dev/null || true)"
  fi
  if [ -z "$STACK" ] && [ -f "$ROOT_DIR/.claude/tech-stack" ]; then
    STACK="$(tr -d '[:space:]' < "$ROOT_DIR/.claude/tech-stack" || true)"
  fi
fi

[ -n "$OUT" ] || OUT="$ROOT_DIR/.mtk/workflows/$UUID/context-pack.md"

python3 - "$ROOT_DIR" "$MTK_ROOT" "$STACK" "$SIDECAR" "$UUID" "$OUT" "$DRY" "$WARN_BYTES" "$CHANGE_MAP" <<'PY'
import json, os, re, sys, datetime, subprocess

root, mtk, stack, sidecar_path, uuid, out, dry, warn_bytes, change_map = sys.argv[1:10]
dry = dry == "1"; warn_bytes = int(warn_bytes); change_map = change_map != "0"

def read(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as f: return f.read()
    except OSError: return ""

def sections(text):
    """Split markdown into [(level, heading, body)] on ## / ### headings."""
    out, cur = [], None
    for line in text.splitlines():
        m = re.match(r'^(#{2,3})\s+(.*)$', line)
        if m:
            if cur: out.append(cur)
            cur = (len(m.group(1)), m.group(2).strip(), [])
        elif cur:
            cur[2].append(line)
    if cur: out.append(cur)
    return [(l, h, "\n".join(b).strip()) for l, h, b in out]

def section(text, heading_prefix):
    for l, h, b in sections(text):
        if l == 2 and h.lower().startswith(heading_prefix.lower()):
            return h, b
    return None, ""

try:
    sidecar = json.load(open(sidecar_path))
except Exception as e:
    print(f"build-context-pack: sidecar is not valid JSON: {e}", file=sys.stderr); sys.exit(1)

manifest = sidecar.get("change_manifest") or []
paths = [m.get("path", m) if isinstance(m, dict) else str(m) for m in manifest]
paths = [p for p in paths if isinstance(p, str) and p]

parts, inventory = [], []
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
parts.append(f"# Context pack — {uuid}\n\nGenerated {now} from `{os.path.relpath(sidecar_path, root) if os.path.isabs(sidecar_path) else sidecar_path}` · stack `{stack or '(unresolved)'}` · {len(paths)} manifest paths.\n\nThis pack REPLACES reading CLAUDE.md, the tech-stack skill, and the full coding guidelines. Pull a guideline section from the TOC paths below only when the batch needs it.\n")

# 2. commands
skill_path = os.path.join(mtk, ".claude", "skills", f"tech-stack-{stack}", "SKILL.md") if stack else ""
skill = read(skill_path) if skill_path else ""
if skill:
    for pref in ("Build & Test Commands", "Format Command"):
        h, b = section(skill, pref)
        if b:
            parts.append(f"## {h}\n\n{b}\n"); inventory.append(f"commands: {h} ({len(b)} chars)")
else:
    parts.append("## Build & Test Commands\n\n_(tech stack unresolved — run `bash scripts/resolve-tech-stack.sh` or set `.claude/tech-stack`)_\n")
    inventory.append("commands: MISSING (stack unresolved)")

# 3. CLAUDE.md
claude = read(os.path.join(root, "CLAUDE.md"))
if claude:
    h, b = section(claude, "Critical Rules")
    toc = [hh for l, hh, _ in sections(claude) if l == 2]
    parts.append("## CLAUDE.md — Critical Rules\n\n" + (b if b else "_(no `## Critical Rules` section)_") + "\n\nOther CLAUDE.md sections (read on demand): " + " · ".join(f"`{t}`" for t in toc) + "\n")
    inventory.append(f"CLAUDE.md critical rules ({len(b)} chars) + TOC of {len(toc)} headings")
else:
    inventory.append("CLAUDE.md: MISSING")

# 4. coding guidelines, keyword-selected
KIND_TABLE = [
    (r'(Handler|Command|Query|Mediat|Request|Notification)', r'(mediat|handler|slice|cqrs|command|query|request|pipeline)'),
    (r'(Entity|Db|Migration|Repository|EF|Model|Snapshot)',   r'(ef|entity|migration|dbcontext|query|linq|repository|data)'),
    (r'(Test|Spec|Fixture|Mock)',                             r'(test|assert|mock|fixture|arrange|xunit|pytest|vitest|jest)'),
    (r'(Controller|Endpoint|Api|Route|Minimal)',              r'(api|controller|endpoint|http|route|dto|contract)'),
    (r'(Service|Client|Http|Integration)',                    r'(service|client|http|resilien|retry|integration)'),
]
wanted = set()
for p in paths:
    base = os.path.basename(p)
    for path_re, heading_re in KIND_TABLE:
        if re.search(path_re, base, re.I): wanted.add(heading_re)

guideline_files = []
if skill:
    _, refs = section(skill, "Reference Files")
    for m in re.finditer(r'\.claude/references/[A-Za-z0-9_./-]+\.md', refs):
        rel = m.group(0)
        for base in (root, mtk):
            cand = os.path.join(base, rel)
            if os.path.isfile(cand) and cand not in guideline_files:
                guideline_files.append(cand); break

sel_chars = 0; toc_lines = []
for gf in guideline_files:
    text = read(gf); rel = os.path.relpath(gf, root) if gf.startswith(root) else gf
    secs = sections(text)
    chosen = []
    for l, h, b in secs:
        if any(re.search(hr, h, re.I) for hr in wanted):
            chosen.append((l, h, b))
    if not chosen and secs and not wanted:
        chosen = [secs[0]]  # nothing to key on: give the opening section only
    for l, h, b in chosen:
        parts.append(f"{'#'*l} {h}  _(from `{rel}`)_\n\n{b}\n"); sel_chars += len(b)
    for l, h, _ in secs:
        toc_lines.append(f"- {'  ' if l == 3 else ''}`{rel}` → {h}")
if guideline_files:
    parts.append("## Coding-guideline table of contents (pull a section only when the batch needs it)\n\n" + "\n".join(toc_lines) + "\n")
    inventory.append(f"guidelines: {len(guideline_files)} file(s), {sel_chars} chars selected, TOC {len(toc_lines)} headings")
else:
    inventory.append("guidelines: none listed by the tech-stack skill")

# 5. architecture principles [EXTRACTED]
ap = read(os.path.join(root, ".claude", "references", "architecture-principles.md"))
if ap:
    ex = [l for l in ap.splitlines() if "[EXTRACTED]" in l]
    if ex:
        parts.append("## Architecture principles — [EXTRACTED] only\n\n" + "\n".join(ex) + "\n")
    inventory.append(f"architecture-principles: {len(ex)} EXTRACTED lines")

# 6. lessons touching the manifest
lessons = read(os.path.join(root, "tasks", "lessons.md"))
if lessons and paths:
    keys = set()
    for p in paths:
        stem = os.path.splitext(os.path.basename(p))[0]
        if len(stem) >= 4: keys.add(stem.lower())
        for seg in p.split("/")[:-1]:
            if len(seg) >= 4 and seg.lower() not in ("src", "test", "tests", "docs"): keys.add(seg.lower())
    hits = []
    for l, h, b in sections(lessons):
        blob = (h + "\n" + b).lower()
        if any(k in blob for k in keys):
            hits.append(f"{'#'*l} {h}\n\n{b}\n")
        if len(hits) >= 10: break
    if hits:
        parts.append("## Lessons that mention this change's paths\n\n" + "\n".join(hits))
    inventory.append(f"lessons: {len(hits)} matching entr{'y' if len(hits)==1 else 'ies'}")

# 7. change map — one shared call graph for every reviewer lane
# Declared-symbol shapes per extension. Deliberately shallow: types and public
# entry points, not every local. Private members are noise for a cross-file map.
SYMBOL_RES = {
    ".cs": [
        re.compile(r'^\s*(?:public|internal|protected)?\s*(?:static\s+|sealed\s+|abstract\s+|partial\s+|readonly\s+|ref\s+)*(?:class|interface|record(?:\s+struct|\s+class)?|struct|enum)\s+([A-Z]\w*)', re.M),
        re.compile(r'^\s*(?:public|internal)\s+(?:static\s+|virtual\s+|override\s+|async\s+|sealed\s+|abstract\s+|new\s+)*[\w<>\[\],?.]+\s+([A-Z]\w*)\s*[<(]', re.M),
    ],
    ".py": [re.compile(r'^(?:class|(?:async\s+)?def)\s+([A-Za-z]\w*)', re.M)],
    ".ts": [re.compile(r'^\s*export\s+(?:default\s+)?(?:declare\s+)?(?:async\s+)?(?:abstract\s+)?(?:function|class|const|let|var|interface|type|enum)\s+([A-Za-z_$]\w*)', re.M)],
    ".go": [re.compile(r'^func\s+(?:\([^)]*\)\s*)?([A-Z]\w*)', re.M), re.compile(r'^type\s+([A-Z]\w*)', re.M)],
    ".java": [re.compile(r'^\s*(?:public|protected)?\s*(?:static\s+|final\s+|abstract\s+)*(?:class|interface|record|enum)\s+([A-Z]\w*)', re.M)],
    ".rs": [re.compile(r'^\s*pub(?:\([^)]*\))?\s+(?:async\s+)?(?:fn|struct|enum|trait|type)\s+([A-Za-z_]\w*)', re.M)],
}
for alias, canon in ((".tsx", ".ts"), (".js", ".ts"), (".jsx", ".ts"), (".mjs", ".ts"), (".kt", ".java")):
    SYMBOL_RES[alias] = SYMBOL_RES[canon]
CS_KEYWORDS = {"Task", "Void", "String", "Int32", "Boolean", "Object", "List", "Dictionary", "IEnumerable", "IAsyncEnumerable", "ValueTask", "Main"}
GENERATED_EXCLUDES = [":(exclude)*.min.*", ":(exclude)*.lock", ":(exclude)package-lock.json", ":(exclude)yarn.lock",
                      ":(exclude)*.Designer.cs", ":(exclude)*.g.cs", ":(exclude)*.g.i.cs", ":(exclude)*.snap",
                      ":(exclude)*.map", ":(exclude)*Snapshot.cs", ":(exclude)*.bundle.js", ":(exclude)dist/*", ":(exclude)node_modules/*"]
MAX_SYMBOLS_PER_FILE, MAX_REFERRERS, MAX_SYMBOLS_TOTAL = 15, 8, 60

def declared_symbols(path):
    ext = os.path.splitext(path)[1].lower()
    res = SYMBOL_RES.get(ext)
    if not res: return None
    text = read(os.path.join(root, path))
    seen, syms = set(), []
    for r in res:
        for m in r.finditer(text):
            name = m.group(1)
            if len(name) < 3 or name in CS_KEYWORDS or name in seen: continue
            seen.add(name); syms.append(name)
    return syms[:MAX_SYMBOLS_PER_FILE]

def referrers(symbol, declaring):
    try:
        r = subprocess.run(["git", "grep", "-I", "-l", "-w", "-F", "--untracked", "-e", symbol, "--", "."] + GENERATED_EXCLUDES,
                           cwd=root, capture_output=True, text=True, timeout=20)
    except Exception:
        return None
    if r.returncode not in (0, 1): return None
    files = [f.strip() for f in r.stdout.splitlines() if f.strip() and os.path.normpath(f.strip()) != os.path.normpath(declaring)]
    return sorted(set(files))

if change_map and paths:
    lines, n_files, n_syms, n_edges, budget = [], 0, 0, 0, MAX_SYMBOLS_TOTAL
    for p in paths:
        n_files += 1
        full = os.path.join(root, p)
        if not os.path.isfile(full):
            lines.append(f"### `{p}`\n\n- _new file — not on disk yet, no symbols to map_\n"); continue
        syms = declared_symbols(p)
        if syms is None:
            lines.append(f"### `{p}`\n\n- _no symbol extractor for this file type_\n"); continue
        if not syms:
            lines.append(f"### `{p}`\n\n- _no top-level or public symbols found_\n"); continue
        rows = []
        for sname in syms:
            if budget <= 0: rows.append(f"- _… symbol budget ({MAX_SYMBOLS_TOTAL}) reached; re-derive the rest by hand_"); break
            budget -= 1; n_syms += 1
            refs = referrers(sname, p)
            if refs is None:
                rows.append(f"- `{sname}` ← _(git grep unavailable)_")
            elif not refs:
                rows.append(f"- `{sname}` ← _no other file references it_")
            else:
                n_edges += len(refs)
                shown = ", ".join(f"`{f}`" for f in refs[:MAX_REFERRERS])
                more = f" +{len(refs) - MAX_REFERRERS} more" if len(refs) > MAX_REFERRERS else ""
                rows.append(f"- `{sname}` ← {shown}{more}")
        lines.append(f"### `{p}`\n\n" + "\n".join(rows) + "\n")
    summary = f"change map: {n_files} manifest file(s), {n_syms} symbols, {n_edges} referrer edges"
    parts.append("## Change map (shared — read this instead of re-deriving the call graph)\n\n"
                 f"{summary}. Per manifest file: the symbols it declares and the tracked files that reference each "
                 "(`git grep -w`, minified/generated files excluded, declaring file omitted). Reviewer lanes start from "
                 "this map and re-derive only where a symbol shows `+N more`.\n\n" + "\n".join(lines))
    inventory.append(summary)
elif not change_map:
    inventory.append("change map: disabled (--no-change-map / MTK_CONTEXT_PACK_CHANGE_MAP=0)")

doc = "\n".join(parts)
size = len(doc.encode("utf-8"))
if dry:
    print(f"context-pack (dry-run): {out} would be {size} bytes")
    for line in inventory: print(f"  - {line}")
else:
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f: f.write(doc)
    print(f"context-pack: {out} ({size} bytes)")
if size > warn_bytes:
    print(f"build-context-pack: WARN pack is {size} bytes (> {warn_bytes}); tighten the guideline selection or the manifest", file=sys.stderr)
PY
