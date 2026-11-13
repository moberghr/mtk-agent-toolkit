#!/usr/bin/env bash
set -euo pipefail

# routing-check.sh — offline check that skill descriptions route everyday prompts
# to the right skill and do not collide with each other.
#
# The model picks a skill from its frontmatter `name` and `description` alone.
# This script scores those two fields with a lexical proxy: each skill becomes a
# TF-IDF vector over stemmed words (name counted twice, description once, common
# words dropped), and cosine similarity compares skills with each other and with
# prompts. It is deterministic, uses only the python3 standard library, and makes
# no model calls. A pass here is necessary, not sufficient: live routing is
# semantic, and the behavioural evals under evals/ cover that.
#
# Checks:
#   collisions  every skill pair; WARN at >= --warn, FAIL at >= --fail, unless the
#               pair is on the prompts file's allow-list (each entry has a reason)
#   positive    a prompt passes when its expected skill is in the top --top-k;
#               rank 1 is reported. Ties count against the expected skill, and a
#               score of 0 is a miss.
#   negative    a prompt must not rank the `not` skill first (a tie counts as
#               first); when an `owner` is named, it must score strictly above it.
#               A negative whose `not` skill scores 0 cannot fail and warns.
#   name-free   a positive prompt that shares no word with its skill's name; it
#               reaches the skill through the description alone, so its rank-1
#               rate is reported on its own
#   coverage    each skill not on the exempt list needs min_positive_per_skill
#               positive prompts, min_name_free_per_skill of them name-free; an
#               exempt entry for a skill that meets both anyway warns
#   ratchets    the share of positive prompts ranked first must be >= --min-rank1,
#               and the share of name-free ones >= --min-rank1-name-free
#   frontmatter each SKILL.md needs a --- block with a readable description; a
#               value in a shape the reader does not handle fails the run
#
# The prompts file (JSON) holds the cases, the allow-list, the exempt list and the
# committed thresholds; a flag overrides the file, and the file overrides the
# built-in defaults (warn 0.50, fail 0.75, top-k 3, both ratchets 0, coverage 0).
#
# Usage:
#   bash scripts/routing-check.sh [--json] [--quiet] [--skills-dir <dir>] [--prompts <file>]
#                                 [--warn <0-1>] [--fail <0-1>] [--top-k <n>]
#                                 [--min-rank1 <percent>] [--min-rank1-name-free <percent>]
#     --json                     machine-readable report
#     --quiet                    print only failures, warnings and the summary line
#     --skills-dir <dir>         skills (default: .claude/skills/ at the repo root)
#     --prompts <file>           cases and config (default: tests/fixtures/skill-routing.json)
#     --warn <0-1>               pair similarity that warns
#     --fail <0-1>               pair similarity that fails
#     --top-k <n>                rank a positive prompt's skill must reach
#     --min-rank1 <pct>          minimum percentage of positive prompts ranked first
#     --min-rank1-name-free <pct> the same, over the name-free positive prompts
#     -h, --help                 print this header
#
# Exit codes:
#   0  every check passed (warnings do not fail it)
#   1  a check failed: a collision at or above --fail, a positive miss, a negative
#      hit, a skill short of prompts, a ratchet, a case naming an unknown skill, or
#      a SKILL.md whose frontmatter or description cannot be read
#   2  usage or environment error (bad args, a number that is not finite, missing
#      dir or file, invalid prompts file, no skills, missing python3)

die() { echo "routing-check: $1" >&2; exit 2; }

# Repo root without external tools, so the python3 check below runs first.
here="${BASH_SOURCE[0]%/*}"
[ "$here" = "${BASH_SOURCE[0]}" ] && here="."
ROOT="$(cd "$here/.." && pwd)"

json=0
quiet=0
skills_dir="$ROOT/.claude/skills"
skills_label=".claude/skills/"
prompts="$ROOT/tests/fixtures/skill-routing.json"
prompts_label="tests/fixtures/skill-routing.json"
warn_flag=""
fail_flag=""
topk_flag=""
rank1_flag=""
nf_rank1_flag=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json)  json=1; shift ;;
    --quiet) quiet=1; shift ;;
    --skills-dir) [ $# -ge 2 ] || die "--skills-dir needs a value"; skills_dir="$2"; skills_label="$2"; shift 2 ;;
    --prompts)    [ $# -ge 2 ] || die "--prompts needs a value";    prompts="$2";    prompts_label="$2"; shift 2 ;;
    --warn)       [ $# -ge 2 ] || die "--warn needs a value";       warn_flag="$2";  shift 2 ;;
    --fail)       [ $# -ge 2 ] || die "--fail needs a value";       fail_flag="$2";  shift 2 ;;
    --top-k)      [ $# -ge 2 ] || die "--top-k needs a value";      topk_flag="$2";  shift 2 ;;
    --min-rank1)  [ $# -ge 2 ] || die "--min-rank1 needs a value";  rank1_flag="$2"; shift 2 ;;
    --min-rank1-name-free) [ $# -ge 2 ] || die "--min-rank1-name-free needs a value"; nf_rank1_flag="$2"; shift 2 ;;
    -h|--help)
      # Render the header comment block (first '# ' line to the first non-comment line).
      awk '/^# /{f=1} f{ if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 is required (scoring and report)"
[ -d "$skills_dir" ] || die "skills directory not found: $skills_dir"
[ -f "$prompts" ] || die "prompts file not found: $prompts"

# -I: isolated mode, so no PYTHON* variable or stray module in the working
# directory changes how the report is computed.
python3 -I - "$skills_dir" "$prompts" "$skills_label" "$prompts_label" "$json" "$quiet" \
  "$warn_flag" "$fail_flag" "$topk_flag" "$rank1_flag" "$nf_rank1_flag" <<'PY'
import json
import math
import os
import re
import sys

(skills_dir, prompts_path, skills_label, prompts_label, as_json, quiet,
 warn_flag, fail_flag, topk_flag, rank1_flag, nf_rank1_flag) = sys.argv[1:12]
as_json = as_json == "1"
quiet = quiet == "1"
# The report itself is ASCII; prompt text the fixture supplies may not be, so a
# terminal that cannot encode a character gets an escape instead of a crash.
sys.stdout.reconfigure(errors="backslashreplace")

METHOD = ("lexical proxy: stemmed TF-IDF over each skill's name (counted twice) and "
          "description, cosine similarity; prompts are scored the same way")
DEFAULTS = {"warn": 0.50, "fail": 0.75, "top_k": 3, "min_rank1": 0.0,
            "min_rank1_name_free": 0.0, "min_positive_per_skill": 0,
            "min_name_free_per_skill": 0}
TOP_KEYS = {"id", "fixture_type", "description", "thresholds", "allow_pairs",
            "exempt", "positive", "negative"}


def die(msg):
    sys.stderr.write("routing-check: %s\n" % msg)
    sys.exit(2)


# --- Text model -----------------------------------------------------------------
# Function words, prompt filler, and the "Use when / before / after" template words
# that open many descriptions and would otherwise make them look alike.
STOPWORDS = frozenset("""
a about above after again all also am an and any are as at be been before being
below between both but by can could did do does doing don done during each either
else etc every few for from further had has have having he her here hers him his
how if in into is it its itself just let lets like may me might more most much must
my need needs no nor not now of off on once one only onto or other our ours out over
own per please same she should so some such than that the their theirs them then
there these they this those through to too two under until up upon us use used uses
using very via want wants was we were what when where whether which while who whom
whose why will with within without would yet you your yours ok okay hey hi thanks
pls aren couldn didn doesn hasn haven isn shouldn wasn won wouldn
""".split())

VOWELS = "aeiou"

# One derivational suffix is removed per word, first match wins; the number is the
# shortest stem the suffix may leave behind.
DERIVATIONAL = (
    ("ification", "ify", 2), ("ization", "ize", 3), ("ation", "", 4),
    ("ency", "", 4), ("ancy", "", 4), ("ence", "", 4), ("ance", "", 4),
    ("able", "", 4), ("ible", "", 4), ("ness", "", 3), ("ion", "", 4),
    ("ity", "", 4), ("ate", "", 4), ("al", "", 4), ("er", "", 4), ("ly", "", 4),
)


def has_vowel(s):
    return any(c in VOWELS for c in s)


def tidy_verb_stem(s):
    """After removing -ing/-ed: restore a dropped e, or undouble a final consonant."""
    if s.endswith(("at", "bl", "iz")):
        return s + "e"
    if len(s) >= 2 and s[-1] == s[-2] and s[-1] not in "aeioulsz":
        return s[:-1]
    return s


def stem(word):
    """A small suffix stripper: plural and verb endings, then one derivational
    suffix, then a final e or y. Deterministic and dictionary-free."""
    w = word
    if len(w) <= 3:
        return w
    if w.endswith("ies") and len(w) > 4:
        w = w[:-3] + "y"
    elif w.endswith("sses"):
        w = w[:-2]
    elif w.endswith(("ches", "shes", "xes", "zes")):
        w = w[:-2]
    elif w.endswith("s") and not w.endswith(("ss", "us", "is")):
        w = w[:-1]
    if w.endswith("ied") and len(w) > 4:
        w = w[:-3] + "y"
    elif w.endswith("ing") and len(w) - 3 >= 3 and has_vowel(w[:-3]):
        w = tidy_verb_stem(w[:-3])
    elif w.endswith("ed") and len(w) - 2 >= 3 and has_vowel(w[:-2]):
        w = tidy_verb_stem(w[:-2])
    for suffix, replacement, keep in DERIVATIONAL:
        if w.endswith(suffix) and len(w) - len(suffix) >= keep:
            w = w[:-len(suffix)] + replacement
            break
    if len(w) >= 4 and w.endswith("e"):
        w = w[:-1]
    if len(w) > 3 and w.endswith("y") and has_vowel(w[:-1]):
        w = w[:-1] + "i"
    return w


def tokens(text):
    # Contractions lose their tail ("doesn't" -> "doesn", "it's" -> "it"), then
    # anything that is not a letter or digit separates words.
    text = re.sub(r"['’][a-z]{1,2}\b", "", text.lower())
    # Spelling variants of one word: "set up" / "set-up" / "setup", likewise hand off.
    text = re.sub(r"\b(set|hand)[\s-]+(up|off)\b", r"\1\2", text)
    out = []
    for raw in re.split(r"[^a-z0-9]+", text):
        if len(raw) < 2 or raw.isdigit() or raw in STOPWORDS:
            continue
        out.append(stem(raw))
    return out


def counts(toks):
    tf = {}
    for t in toks:
        tf[t] = tf.get(t, 0) + 1
    return tf


# --- Skills ---------------------------------------------------------------------
def frontmatter(text):
    m = re.match(r"\A---[ \t]*\r?\n(.*?)^---[ \t]*\r?$", text, re.S | re.M)
    return m.group(1) if m else None


class FrontmatterError(Exception):
    """A frontmatter value in a shape this reader does not handle."""


# A block scalar header: | or >, then an optional chomping sign and indentation
# digit in either order, then an optional comment.
BLOCK_HEADER = re.compile(r"^([|>])(?:[+-]?[1-9]?|[1-9][+-])(?:[ \t]+#.*)?$")
DQ_ESCAPES = {"0": "\0", "a": "\a", "b": "\b", "t": "\t", "\t": "\t", "n": "\n",
              "v": "\v", "f": "\f", "r": "\r", "e": "\x1b", " ": " ", '"': '"',
              "/": "/", "\\": "\\", "N": "\x85", "_": "\xa0", "L": "\N{LINE SEPARATOR}",
              "P": "\N{PARAGRAPH SEPARATOR}"}


def unescape_double(text):
    def repl(m):
        e = m.group(1)
        if len(e) > 1:
            return chr(int(e[1:], 16))
        if e in DQ_ESCAPES:
            return DQ_ESCAPES[e]
        raise FrontmatterError("unknown escape \\%s in a double-quoted value" % e)
    return re.sub(r"\\(x[0-9A-Fa-f]{2}|u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8}|.)", repl, text, flags=re.S)


def fold(lines, double):
    """Fold the lines of a quoted scalar: a line break becomes a space, a blank
    line a newline; in double quotes a trailing backslash joins without a space."""
    out = ""
    glue = ""
    for i, line in enumerate(lines):
        piece = line if i == 0 else line.lstrip(" \t")
        piece = piece if i == len(lines) - 1 else piece.rstrip(" \t")
        if not piece and 0 < i < len(lines) - 1:
            glue = "\n"
            continue
        joined = False
        if double and i < len(lines) - 1:
            tail = len(piece) - len(piece.rstrip("\\"))
            if tail % 2 == 1:
                piece, joined = piece[:-1], True
        out += glue + piece
        glue = "" if joined else " "
    return out


def quoted(text, key):
    """A single- or double-quoted scalar that may span lines; text starts at the
    opening quote. Anything but a comment after the closing quote is an error."""
    q = text[0]
    i = 1
    while i < len(text):
        c = text[i]
        if q == '"' and c == "\\":
            i += 2
            continue
        if c == q:
            if q == "'" and text[i + 1:i + 2] == "'":
                i += 2
                continue
            break
        i += 1
    else:
        raise FrontmatterError("'%s' opens a %s-quoted value that never closes"
                               % (key, "double" if q == '"' else "single"))
    after = text[i + 1:].strip()
    if after and not after.startswith("#"):
        raise FrontmatterError("'%s' has text after its closing quote: %r" % (key, after[:40]))
    body = fold(text[1:i].split("\n"), q == '"')
    return unescape_double(body) if q == '"' else body.replace("''", "'")


def field(fm, key):
    """A top-level scalar from the frontmatter. Reads a plain value on one or more
    lines (continuation lines indented), a value that starts on the next indented
    line, a single- or double-quoted value (one or more lines), and a literal (|) or
    folded (>) block with an optional chomping sign and indentation digit. Returns
    None when the key is absent; raises FrontmatterError on any other shape, so a
    description is never read as silently empty or wrong."""
    lines = fm.replace("\r\n", "\n").split("\n")
    hits = [i for i, line in enumerate(lines) if re.match(r"%s:(?:[ \t]|$)" % re.escape(key), line)]
    if not hits:
        return None
    if len(hits) > 1:
        raise FrontmatterError("'%s' appears %d times" % (key, len(hits)))
    start = hits[0]
    inline = lines[start][len(key) + 1:].strip()
    cont = []
    for line in lines[start + 1:]:
        if line.strip() and line[:1] not in " \t":
            break
        if line.strip() and line[:1] == "\t":
            raise FrontmatterError("'%s' continues on a line indented with a tab" % key)
        cont.append(line)
    while cont and not cont[-1].strip():
        cont.pop()

    if inline[:1] in ("|", ">"):
        head = BLOCK_HEADER.match(inline)
        if not head:
            raise FrontmatterError("'%s' has a block header this reader does not handle: %r" % (key, inline))
        body = [line.strip() for line in cont if line.strip()]
        return ("\n" if head.group(1) == "|" else " ").join(body)
    if inline.startswith("#"):
        inline = ""                      # only a comment on the key line
    if inline[:1] in ("'", '"'):
        return quoted("\n".join([inline] + cont), key)

    rest = [line.strip() for line in cont]
    if not inline:
        first = next((line for line in rest if line), "")
        if not first:
            return ""
        if first[:1] in ("'", '"'):
            return quoted("\n".join(rest).strip(), key)
        if first[:1] in ("|", ">"):
            raise FrontmatterError("'%s' puts a block indicator on its own line; put it after the key" % key)
        if re.match(r"(?:-|\?)(?:[ \t]|$)", first) or re.match(r"[^\s#'\"][^:]*:(?:[ \t]|$)", first):
            raise FrontmatterError("'%s' holds a list or a mapping, not text" % key)

    words = []
    pieces = [inline] + rest if inline else rest
    for n, piece in enumerate(pieces):
        if not piece:
            continue
        comment = re.search(r"(?:^|[ \t])#", piece)
        if comment:
            piece = piece[:comment.start()].rstrip()
            if any(p for p in pieces[n + 1:]):
                raise FrontmatterError("'%s' continues after a comment line" % key)
        if not words and piece[:1] and piece[:1] in "[]{},&*!%@`-?:" and \
                (piece[:1] not in "-?:" or len(piece) == 1 or piece[1] in " \t"):
            raise FrontmatterError("'%s' starts with %r, which YAML does not read as plain text; quote the value"
                                   % (key, piece[:1]))
        if re.search(r":(?:[ \t]|$)", piece):
            raise FrontmatterError("'%s' has ': ' in an unquoted value, which YAML reads as a mapping; quote the value"
                                   % key)
        if piece:
            words.append(piece)
        if comment:
            break
    value = " ".join(words)
    return "" if value in ("~", "null", "Null", "NULL") else value


skill_names = sorted(d for d in os.listdir(skills_dir)
                     if os.path.isfile(os.path.join(skills_dir, d, "SKILL.md")))
if not skill_names:
    die("no skills (directories with a SKILL.md) under %s" % skills_label)

failures = []   # strings; any entry fails the run
warnings = []

skills = {}
for d in skill_names:
    with open(os.path.join(skills_dir, d, "SKILL.md"), encoding="utf-8", errors="replace") as fh:
        fm = frontmatter(fh.read())
    name, desc = d, ""
    if fm is None:
        failures.append("skill %s: SKILL.md has no frontmatter block (a --- line at the top and a closing ---)" % d)
    else:
        try:
            name = field(fm, "name") or d
            desc = field(fm, "description") or ""
            if not desc.strip():
                failures.append("skill %s has no description in its SKILL.md frontmatter" % d)
        except FrontmatterError as e:
            failures.append("skill %s: cannot read its frontmatter: %s" % (d, e))
    name_toks = tokens(name.replace("-", " "))
    skills[d] = {"name": name, "description": desc, "name_tokens": set(name_toks),
                 "tf": counts(name_toks + name_toks + tokens(desc))}

N = len(skills)
df = {}
for d in skill_names:
    for t in skills[d]["tf"]:
        df[t] = df.get(t, 0) + 1


def idf(term):
    # Smoothed inverse document frequency; a term no skill uses still gets a weight.
    return math.log((1.0 + N) / (1.0 + df.get(term, 0))) + 1.0


def vector(tf):
    return {t: tf[t] * idf(t) for t in sorted(tf)}


def norm(v):
    return math.sqrt(sum(v[t] * v[t] for t in sorted(v)))


def cosine(a, b, na, nb):
    if not na or not nb:
        return 0.0
    dot = sum(a[t] * b[t] for t in sorted(a) if t in b)
    # Rounded so a last-bit difference between platforms' libm cannot move a rank.
    return round(dot / (na * nb), 6)


for d in skill_names:
    skills[d]["vec"] = vector(skills[d]["tf"])
    skills[d]["norm"] = norm(skills[d]["vec"])


def rank_prompt(prompt):
    q = vector(counts(tokens(prompt)))
    nq = norm(q)
    scores = {d: cosine(q, skills[d]["vec"], nq, skills[d]["norm"]) for d in skill_names}
    order = sorted(skill_names, key=lambda d: (-scores[d], d))
    return scores, order


# --- Prompts file ---------------------------------------------------------------
def reject_constant(name):
    raise ValueError("%s is not a finite number" % name)


try:
    with open(prompts_path, encoding="utf-8") as fh:
        cfg = json.load(fh, parse_constant=reject_constant)
except (OSError, ValueError) as e:
    die("cannot read prompts file %s: %s" % (prompts_label, e))
if not isinstance(cfg, dict):
    die("prompts file %s must hold a JSON object" % prompts_label)
unknown_keys = sorted(set(cfg) - TOP_KEYS)
if unknown_keys:
    die("prompts file %s has unknown key(s): %s" % (prompts_label, ", ".join(unknown_keys)))


def need_list(key):
    v = cfg.get(key, [])
    if not isinstance(v, list) or not all(isinstance(x, dict) for x in v):
        die("prompts file: '%s' must be a list of objects" % key)
    return v


def need_text(obj, key, where):
    v = obj.get(key)
    if not isinstance(v, str) or not v.strip():
        die("prompts file: %s needs a non-empty '%s'" % (where, key))
    return v.strip()


th_cfg = cfg.get("thresholds", {})
if not isinstance(th_cfg, dict):
    die("prompts file: 'thresholds' must be an object")
bad_th = sorted(set(th_cfg) - set(DEFAULTS))
if bad_th:
    die("prompts file: unknown threshold(s): %s" % ", ".join(bad_th))


def number(raw, label):
    try:
        v = float(raw)
    except (TypeError, ValueError):
        die("%s must be a number, got %r" % (label, raw))
    if not math.isfinite(v):
        die("%s must be a finite number, got %r" % (label, raw))
    return v


th = dict(DEFAULTS)
for k, v in th_cfg.items():
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
        die("prompts file: threshold '%s' must be a finite number, got %r" % (k, v))
    th[k] = v
for flag, key in ((warn_flag, "warn"), (fail_flag, "fail"), (topk_flag, "top_k"),
                  (rank1_flag, "min_rank1"), (nf_rank1_flag, "min_rank1_name_free")):
    if flag != "":
        th[key] = number(flag, "--" + key.replace("_", "-"))
if not (0 < th["warn"] <= th["fail"] <= 1):
    die("thresholds must satisfy 0 < warn <= fail <= 1 (warn %s, fail %s)" % (th["warn"], th["fail"]))
for key in ("top_k", "min_positive_per_skill", "min_name_free_per_skill"):
    low = 1 if key == "top_k" else 0
    if th[key] != int(th[key]) or th[key] < low:
        die("%s must be a whole number >= %d, got %s" % ("top-k" if key == "top_k" else key, low, th[key]))
    th[key] = int(th[key])
for key in ("min_rank1", "min_rank1_name_free"):
    if not (0 <= th[key] <= 100):
        die("%s must be a percentage from 0 to 100, got %s" % (key.replace("_", "-"), th[key]))

unknown_refs = []


def known(skill, where):
    if skill not in skills:
        unknown_refs.append("%s names unknown skill %r" % (where, skill))
        return False
    return True


allowed = {}
for i, entry in enumerate(need_list("allow_pairs")):
    pair = entry.get("skills")
    if (not isinstance(pair, list) or len(pair) != 2
            or not all(isinstance(s, str) for s in pair) or pair[0] == pair[1]):
        die("prompts file: allow_pairs[%d] needs 'skills': two different skill names" % i)
    reason = need_text(entry, "reason", "allow_pairs[%d]" % i)
    if all(known(s, "allow_pairs[%d]" % i) for s in pair):
        allowed[tuple(sorted(pair))] = reason

exempt = {}
for i, entry in enumerate(need_list("exempt")):
    s = need_text(entry, "skill", "exempt[%d]" % i)
    reason = need_text(entry, "reason", "exempt[%d]" % i)
    if known(s, "exempt[%d]" % i):
        exempt[s] = reason

positives = []
for i, case in enumerate(need_list("positive")):
    prompt = need_text(case, "prompt", "positive[%d]" % i)
    s = need_text(case, "skill", "positive[%d]" % i)
    if known(s, "positive[%d] (%r)" % (i, prompt)):
        positives.append({"prompt": prompt, "skill": s})

negatives = []
for i, case in enumerate(need_list("negative")):
    prompt = need_text(case, "prompt", "negative[%d]" % i)
    not_skill = need_text(case, "not", "negative[%d]" % i)
    owner = case.get("owner")
    if owner is not None:
        owner = need_text(case, "owner", "negative[%d]" % i)
        if owner == not_skill:
            die("prompts file: negative[%d] names %r as both 'not' and 'owner'" % (i, owner))
    ok = known(not_skill, "negative[%d] (%r)" % (i, prompt))
    if owner is not None:
        ok = known(owner, "negative[%d] (%r)" % (i, prompt)) and ok
    if ok:
        negatives.append({"prompt": prompt, "not": not_skill, "owner": owner})

failures.extend(unknown_refs)

# --- Collisions -------------------------------------------------------------------
pairs = []
for i, a in enumerate(skill_names):
    for b in skill_names[i + 1:]:
        sim = cosine(skills[a]["vec"], skills[b]["vec"], skills[a]["norm"], skills[b]["norm"])
        level = "ok"
        if (a, b) in allowed:
            level = "allowed"
        elif sim >= th["fail"]:
            level = "fail"
        elif sim >= th["warn"]:
            level = "warn"
        entry = {"skills": [a, b], "similarity": sim, "level": level}
        if level == "allowed":
            entry["reason"] = allowed[(a, b)]
        pairs.append(entry)
pairs.sort(key=lambda p: (-p["similarity"], p["skills"]))
for p in pairs:
    label = "%s <-> %s (%.2f)" % (p["skills"][0], p["skills"][1], p["similarity"])
    if p["level"] == "fail":
        failures.append("collision %s >= fail %.2f" % (label, th["fail"]))
    elif p["level"] == "warn":
        warnings.append("collision %s >= warn %.2f" % (label, th["warn"]))
    elif p["level"] == "allowed" and p["similarity"] < th["warn"]:
        warnings.append("allow-list entry %s is below warn %.2f and can be removed" % (label, th["warn"]))


def top_list(scores, order, k):
    return [{"skill": d, "score": scores[d]} for d in order[:k]]


# --- Positive cases -----------------------------------------------------------------
# A prompt that shares a word with its skill's name scores partly on that echo,
# and the name is counted twice, so the rank-1 rate is also reported over the
# name-free prompts alone: those reach their skill through the description.
k = th["top_k"]
rank1_hits = 0
topk_hits = 0
nf_total = 0
nf_rank1_hits = 0
pos_report = []
for c in positives:
    scores, order = rank_prompt(c["prompt"])
    mine = scores[c["skill"]]
    # Pessimistic rank: a tie with another skill counts against the expected one.
    rank = None if mine <= 0 else 1 + sum(1 for d in skill_names if d != c["skill"] and scores[d] >= mine)
    hit = rank is not None and rank <= k
    name_free = not (set(tokens(c["prompt"])) & skills[c["skill"]]["name_tokens"])
    rank1_hits += 1 if rank == 1 else 0
    topk_hits += 1 if hit else 0
    nf_total += 1 if name_free else 0
    nf_rank1_hits += 1 if name_free and rank == 1 else 0
    row = {"prompt": c["prompt"], "skill": c["skill"], "rank": rank, "rank1": rank == 1,
           "pass": hit, "name_free": name_free, "score": mine, "top": top_list(scores, order, k)}
    pos_report.append(row)
    if not hit:
        failures.append("positive %r: %s is %s; top: %s" % (
            c["prompt"], c["skill"], "unscored" if rank is None else "rank %d" % rank,
            ", ".join("%s %.2f" % (t["skill"], t["score"]) for t in row["top"])))

# --- Negative cases -----------------------------------------------------------------
neg_report = []
neg_pass = 0
for c in negatives:
    scores, order = rank_prompt(c["prompt"])
    bad = scores[c["not"]]
    best_other = max(scores[d] for d in skill_names if d != c["not"])
    # A tie with the best other skill counts against the case, as for positives.
    not_first = bad <= 0 or best_other > bad
    owner_ok = c["owner"] is None or scores[c["owner"]] > bad
    ok = not_first and owner_ok
    neg_pass += 1 if ok else 0
    row = {"prompt": c["prompt"], "not": c["not"], "owner": c["owner"], "pass": ok,
           "not_score": bad, "owner_score": scores[c["owner"]] if c["owner"] else None,
           "top": top_list(scores, order, k)}
    neg_report.append(row)
    if not ok:
        why = "%s ranks first" % c["not"] if not not_first else \
              "owner %s (%.2f) does not outrank %s (%.2f)" % (c["owner"], scores[c["owner"]], c["not"], bad)
        failures.append("negative %r: %s; top: %s" % (
            c["prompt"], why, ", ".join("%s %.2f" % (t["skill"], t["score"]) for t in row["top"])))
    elif bad <= 0:
        warnings.append("negative %r: %s scores 0 on it, so the case cannot fail; use a prompt "
                        "that shares words with %s" % (c["prompt"], c["not"], c["not"]))

# --- Coverage -----------------------------------------------------------------------
per_skill = {d: 0 for d in skill_names}
nf_per_skill = {d: 0 for d in skill_names}
for r in pos_report:
    per_skill[r["skill"]] += 1
    nf_per_skill[r["skill"]] += 1 if r["name_free"] else 0
short = [d for d in skill_names
         if d not in exempt and per_skill[d] < th["min_positive_per_skill"]]
short_nf = [d for d in skill_names
            if d not in exempt and nf_per_skill[d] < th["min_name_free_per_skill"]]
for d in short:
    failures.append("coverage: %s has %d positive prompt(s), needs %d (or an exempt entry)"
                    % (d, per_skill[d], th["min_positive_per_skill"]))
for d in short_nf:
    failures.append("coverage: %s has %d name-free positive prompt(s), needs %d (or an exempt entry)"
                    % (d, nf_per_skill[d], th["min_name_free_per_skill"]))
for s in sorted(exempt):
    if per_skill[s] >= th["min_positive_per_skill"] and nf_per_skill[s] >= th["min_name_free_per_skill"]:
        warnings.append("exempt entry %s is not needed: it meets coverage with %d positive prompt(s), "
                        "%d name-free, and can be removed" % (s, per_skill[s], nf_per_skill[s]))

# --- Ratchets -----------------------------------------------------------------------
total = len(positives)


def ratchet(hits, n, floor, label, flag):
    rate = (100.0 * hits / n) if n else 0.0
    ok = (hits * 100.0 >= floor * n) if n else floor == 0
    if not ok:
        failures.append("ratchet: %s rate %.1f%% (%d/%d) is below %s %s%%"
                        % (label, rate, hits, n, flag, "%g" % floor))
    return rate


rate = ratchet(rank1_hits, total, th["min_rank1"], "rank-1", "min-rank1")
nf_rate = ratchet(nf_rank1_hits, nf_total, th["min_rank1_name_free"], "name-free rank-1",
                  "min-rank1-name-free")

collide_fail = sum(1 for p in pairs if p["level"] == "fail")
collide_warn = sum(1 for p in pairs if p["level"] == "warn")
collide_allowed = sum(1 for p in pairs if p["level"] == "allowed")
status = "fail" if failures else "pass"
summary = ("summary: %s - rank-1 %d/%d (%.1f%%, min %s%%), name-free rank-1 %d/%d (%.1f%%, min %s%%), "
           "top-%d %d/%d, negatives %d/%d, collisions %d fail / %d warn / %d allowed"
           % (status.upper(), rank1_hits, total, rate, "%g" % th["min_rank1"],
              nf_rank1_hits, nf_total, nf_rate, "%g" % th["min_rank1_name_free"],
              k, topk_hits, total, neg_pass, len(negatives),
              collide_fail, collide_warn, collide_allowed))

if as_json:
    json.dump({
        "method": METHOD,
        "skills_dir": skills_label,
        "prompts": prompts_label,
        "thresholds": th,
        "skills_total": N,
        "descriptions": {d: skills[d]["description"] for d in skill_names},
        "status": status,
        "rank1": {"hits": rank1_hits, "total": total, "rate": round(rate, 1)},
        "rank1_name_free": {"hits": nf_rank1_hits, "total": nf_total, "rate": round(nf_rate, 1)},
        "topk": {"k": k, "hits": topk_hits, "total": total},
        "negatives_passed": neg_pass,
        "negatives_total": len(negatives),
        "pairs": pairs,
        "positive": pos_report,
        "negative": neg_report,
        "coverage": per_skill,
        "coverage_name_free": nf_per_skill,
        "exempt": exempt,
        "short": short,
        "short_name_free": short_nf,
        "failures": failures,
        "warnings": warnings,
    }, sys.stdout, indent=2)
    sys.stdout.write("\n")
    sys.exit(1 if failures else 0)

if not quiet:
    print("routing check: %d skills, %d positive and %d negative prompts (skills: %s, prompts: %s)"
          % (N, total, len(negatives), skills_label, prompts_label))
    print("method (%s)" % METHOD)
    print()
    print("COLLISIONS (warn >= %.2f, fail >= %.2f; highest 8 and every flagged or allowed pair)"
          % (th["warn"], th["fail"]))
    shown = [p for i, p in enumerate(pairs) if i < 8 or p["level"] != "ok"]
    for p in shown:
        tail = "  (%s)" % p["reason"] if p["level"] == "allowed" else ""
        print("  %-7s %.2f  %s <-> %s%s" % (p["level"].upper(), p["similarity"],
                                           p["skills"][0], p["skills"][1], tail))
    print()
    print("POSITIVE (expected skill in top %d; * rank 1, x miss, n shares no word with the skill's name)" % k)
    for r in pos_report:
        mark = "*" if r["rank1"] else (" " if r["pass"] else "x")
        rank = "-" if r["rank"] is None else str(r["rank"])
        print("  %s %3s %s  %-30s %s" % (mark, rank, "n" if r["name_free"] else " ", r["skill"], r["prompt"]))
    print()
    print("NEGATIVE (the 'not' skill must not rank first; an owner must outrank it)")
    for r in neg_report:
        owner = (" < %s" % r["owner"]) if r["owner"] else ""
        print("  %s  not %s%s  %s" % ("ok  " if r["pass"] else "FAIL", r["not"], owner, r["prompt"]))
    if exempt:
        print()
        print("EXEMPT from positive coverage")
        for s in sorted(exempt):
            print("  %-30s %s" % (s, exempt[s]))
    print()

for w in warnings:
    print("WARN: %s" % w)
for f in failures:
    print("FAIL: %s" % f)
print(summary)
sys.exit(1 if failures else 0)
PY
