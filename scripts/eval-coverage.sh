#!/usr/bin/env bash
set -euo pipefail

# eval-coverage.sh — offline report over MTK's behavioural eval cases (evals/<case>/).
#
# It reports eval COVERAGE: the skills under .claude/skills/ that no eval case
# exercises. It reads case files only: no results, no model calls, no writes.
#
# Coverage rule (a heuristic, checked from the case files):
#   a case exercises skill <skill> when any of these holds
#     tag     <skill> is one of the case's tags (prompt.md frontmatter, else case.yaml)
#     prompt  the prompt invokes it as /<skill>, /mtk <skill> or /mtk:<skill>
#             (the prompt.md body; the whole case.yaml when the case has no prompt.md)
#     grader  a grader names its path skills/<skill>/ (graders/*.md or case.yaml), or a
#             graders/*.md with `tool: Skill` names <skill> as a word (not as a `name:` prefix)
#   Prose mentions do not count, so a model-invoked skill that a case triggers
#   implicitly shows as uncovered. To declare coverage exactly, add the skill name
#   to the case's `tags:` (a documented field; prompt.md rejects unknown keys, so
#   do not add a `covers:` key).
#
# It reports no scores and no lift. The lift (with-plugin minus without-plugin) is
# in each run's result as cases[].aggregates.delta; scripts/eval-compare.sh compares
# two runs.
#
# Usage:
#   bash scripts/eval-coverage.sh [--json] [--evals-dir <dir>] [--skills-dir <dir>]
#     --json              machine-readable output
#     --evals-dir <dir>   eval cases (default: evals/ at the repo root)
#     --skills-dir <dir>  skills (default: .claude/skills/ at the repo root)
#     -h, --help          print this header
#
# Exit codes:
#   0  report printed (uncovered skills do not fail it)
#   2  usage or environment error (bad args, missing dir, no skills or cases, missing python3)

die() { echo "eval-coverage: $1" >&2; exit 2; }

# Repo root without external tools, so the python3 check below runs first.
here="${BASH_SOURCE[0]%/*}"
[ "$here" = "${BASH_SOURCE[0]}" ] && here="."
ROOT="$(cd "$here/.." && pwd)"

json=0
evals_dir="$ROOT/evals"
evals_label="evals/"
skills_dir="$ROOT/.claude/skills"
skills_label=".claude/skills/"
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json=1; shift ;;
    --evals-dir)  [ $# -ge 2 ] || die "--evals-dir needs a value";  evals_dir="$2";  evals_label="$2";  shift 2 ;;
    --skills-dir) [ $# -ge 2 ] || die "--skills-dir needs a value"; skills_dir="$2"; skills_label="$2"; shift 2 ;;
    -h|--help)
      # Render the header comment block (first '# ' line to the first non-comment line).
      awk '/^# /{f=1} f{ if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 is required (case parsing and report)"
[ -d "$skills_dir" ] || die "skills directory not found: $skills_dir"
[ -d "$evals_dir" ] || die "evals directory not found: $evals_dir"

python3 - "$evals_dir" "$skills_dir" "$json" "$evals_label" "$skills_label" <<'PY'
import json
import os
import re
import sys

evals_dir, skills_dir, as_json, evals_label, skills_label = sys.argv[1:6]
as_json = as_json == "1"

RULE = ("heuristic: a case exercises skill S when S is one of its tags, its prompt invokes "
        "/S, /mtk S or /mtk:S, or a grader names skills/S/ (or is a tool: Skill grader "
        "naming S); prose mentions do not count")


def die(msg):
    sys.stderr.write("eval-coverage: %s\n" % msg)
    sys.exit(2)


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def split_frontmatter(text):
    """(frontmatter, body); frontmatter is '' when the file has none."""
    m = re.match(r"\A---[ \t]*\r?\n(.*?)^---[ \t]*\r?$\n?", text, re.S | re.M)
    if not m:
        return "", text
    return m.group(1), text[m.end():]


def unquote(value):
    return value.split(" #")[0].strip().strip("\"'")


def top_scalar(text, key):
    m = re.search(r"^%s:[ \t]*(.+?)[ \t]*\r?$" % re.escape(key), text, re.M)
    return unquote(m.group(1)) if m else None


def top_list(text, key):
    """A top-level YAML list (flow `[a, b]`, block `- a`, or a lone scalar); None when absent."""
    m = re.search(r"^%s:[ \t]*(.*?)[ \t]*\r?$" % re.escape(key), text, re.M)
    if not m:
        return None
    rest = m.group(1)
    if rest.startswith("["):
        inner = rest[1:].split("]")[0]
        return [unquote(i) for i in inner.split(",") if unquote(i)]
    if rest and not rest.startswith("#"):
        return [unquote(rest)]
    items = []
    for line in text[m.end():].split("\n")[1:]:
        item = re.match(r"^[ \t]+-[ \t]*(.+?)[ \t]*\r?$", line)
        if item:
            items.append(unquote(item.group(1)))
        elif line.strip():
            break
    return items


# --- Skills: directories that hold a SKILL.md ----------------------------------
skills = sorted(d for d in os.listdir(skills_dir)
                if os.path.isfile(os.path.join(skills_dir, d, "SKILL.md")))
if not skills:
    die("no skills (directories with a SKILL.md) under %s" % skills_label)

# --- Cases: a directory with prompt.md or case.yaml; never descend into one ------
case_dirs = []
for root, dirs, files in os.walk(evals_dir):
    rel = os.path.relpath(root, evals_dir)
    if rel != "." and ("prompt.md" in files or "case.yaml" in files):
        case_dirs.append(rel)
        dirs[:] = []
        continue
    skip = {"results", "mocks"} if rel == "." else set()
    dirs[:] = sorted(d for d in dirs if d not in skip and not d.startswith("."))
case_dirs.sort()
if not case_dirs:
    die("no eval cases (directories with prompt.md or case.yaml) under %s; "
        "author one with: claude plugin eval init" % evals_label)

# Invocations start at a line start, whitespace, or an opening quote/bracket.
LEAD = r"(?<![^\s`'\"(\[])"

cases = []
for rel in case_dirs:
    cdir = os.path.join(evals_dir, rel)
    has_prompt = os.path.isfile(os.path.join(cdir, "prompt.md"))
    prompt_fm, prompt_body = split_frontmatter(read(os.path.join(cdir, "prompt.md")))
    yaml_text = read(os.path.join(cdir, "case.yaml"))

    name = top_scalar(prompt_fm, "name") or top_scalar(yaml_text, "name") or os.path.basename(rel)
    tags = top_list(prompt_fm, "tags")
    if tags is None:
        tags = top_list(yaml_text, "tags") or []
    prompt_text = prompt_body if has_prompt else yaml_text

    gdir = os.path.join(cdir, "graders")
    graders = []
    if os.path.isdir(gdir):
        graders = [read(os.path.join(gdir, g)) for g in sorted(os.listdir(gdir)) if g.endswith(".md")]
    skill_tool_graders = [g for g in graders
                          if re.search(r"^tool:[ \t]*[\"']?Skill[\"']?[ \t]*\r?$", split_frontmatter(g)[0], re.M)]

    evidence = {}
    for s in skills:
        e = re.escape(s)
        hits = []
        if s in tags:
            hits.append("tag")
        if (re.search(LEAD + "/" + e + r"(?![\w:-])", prompt_text)
                or re.search(LEAD + r"/mtk[ \t]+" + e + r"(?![\w-])", prompt_text)
                or re.search(LEAD + r"/mtk:" + e + r"(?![\w-])", prompt_text)):
            hits.append("prompt")
        path_re = re.compile(r"(?<![\w-])skills/" + e + "/")
        word_re = re.compile(r"(?<![\w-])" + e + r"(?![\w:-])")
        if (any(path_re.search(t) for t in graders + [yaml_text])
                or any(word_re.search(t) for t in skill_tool_graders)):
            hits.append("grader")
        if hits:
            evidence[s] = hits
    cases.append({"name": name, "path": rel.replace(os.sep, "/"),
                  "skills": sorted(evidence), "evidence": evidence})

covered = {}
for c in cases:
    for s in c["skills"]:
        covered.setdefault(s, []).append(c["name"])
covered = {s: sorted(set(covered[s])) for s in sorted(covered)}
uncovered = [s for s in skills if s not in covered]

if as_json:
    json.dump({
        "rule": RULE,
        "skills_dir": skills_label,
        "evals_dir": evals_label,
        "skills_total": len(skills),
        "cases_total": len(cases),
        "covered": covered,
        "uncovered": uncovered,
        "cases": cases,
        "lift": None,
    }, sys.stdout, indent=2)
    sys.stdout.write("\n")
    sys.exit(0)

width = max(len(s) for s in skills) + 2
print("eval coverage: %d skills, %d cases (skills: %s, cases: %s)"
      % (len(skills), len(cases), skills_label, evals_label))
print("rule (%s)" % RULE)
print("lift: not computed (the per-case with/without table is not built; see evals/README.md)")
print()
print("COVERED (%d)" % len(covered))
for s, names in covered.items():
    rows = []
    for n in names:
        c = next(c for c in cases if c["name"] == n and s in c["evidence"])
        rows.append("%s (%s)" % (n, ", ".join(c["evidence"][s])))
    print("  %s%s" % (s.ljust(width), ", ".join(rows)))
if not covered:
    print("  (none)")
print()
print("UNCOVERED (%d)" % len(uncovered))
for s in uncovered:
    print("  %s" % s)
if not uncovered:
    print("  (none)")
print()
print("summary: %d/%d skills covered, %d uncovered" % (len(covered), len(skills), len(uncovered)))
PY
