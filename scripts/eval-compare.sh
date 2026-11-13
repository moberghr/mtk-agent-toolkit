#!/usr/bin/env bash
set -euo pipefail

# eval-compare.sh — compares two `claude plugin eval --json` result files.
#
# Give it a baseline run and a candidate run of the same cases (for example the
# last release tag and the branch under review). Per case it prints the with-plugin
# score in each file, the delta (candidate minus baseline), and the plugin-fired
# indicator in each file. Then it prints totals: the mean score over the shared
# cases, and over the routing pairs the fires rate and the stays-quiet rate.
# It reads the two files only: no model calls, no writes.
#
# Fields read (schemaVersion 1, confirmed against a Claude Code 2.1.322 run):
#   schemaVersion, partial, partialReason, claudeVersion, costUsd,
#   suite.ablation, suite.modelOverride, suite.judgeModel, suite.plugins[].name/version,
#   aggregates.casesTotal,
#   cases[].name, cases[].aggregates.score,
#   cases[].graders[].name/type/config.arm/config.tool,
#   cases[].arms.with[].score/error/skippedPaidGraders,
#   cases[].arms.with[].graders[].name/passed/withOnly
#
# A case's score here is the mean score of its graded with-plugin runs. A run whose
# `error` is set (a timeout, an API error) is not graded: it is left out of the score,
# FIRED and both rates, and listed under WARNINGS. Its graders can pass on nothing
# done (a no-edit check, a stayed-quiet check), so counting it would turn a crash into
# a pass. A case whose runs all ended on an error makes the file incomplete (exit 2).
#
# FIRED is "graded runs in which the plugin fired / graded with-plugin runs":
#   fires case  (has a grader named routing-fired)  runs where routing-fired passed
#   quiet case  (has a grader named routing-quiet)  runs where routing-quiet failed,
#               so a quiet case should show 0
#   other case  runs where any indicator grader passed. An indicator is a grader the
#               run reports as withOnly, one with `arm: with-only`, or a
#               `tool_used: Skill` grader without `arm: both`. "-" when there is none.
# The fires rate is fired runs over the graded runs of the fires cases in both files;
# the stays-quiet rate is quiet runs over the graded runs of the quiet cases in both
# files.
#
# A regression (exit 1) is any of these:
#   - a case score that dropped by more than --noise, for a case in both files;
#   - a FIRED rate that dropped by more than --noise on a fires case, or rose by more
#     than --noise on a quiet case;
#   - a fires rate or stays-quiet rate that dropped by more than --noise;
#   - a case in the baseline that is missing from the candidate, since a case that
#     no longer runs measures nothing. Pass --allow-missing when a case was removed on
#     purpose. A case only in the candidate is listed and not compared.
# Run both files with the same --case/--tag filter.
#
# For a case that is neither fires nor quiet, the score is the measurement and the
# indicator is context. Its status comes from the score delta alone (regressed,
# improved, within noise or same). If its FIRED rate moved by more than --noise, in
# either direction, that is a note on the row ("note: workflow loaded 1.00 -> 0.50")
# and a line under NOTES after REGRESSIONS. A note never makes a regression or an
# improvement and does not change the exit code. In --json the row carries it as
# `note` (null when none) and the top level lists them as `notes`.
#
# --noise defaults to 0.2. Scores are means over runs, so at --runs 3 one grader
# verdict flipping in one run moves a two-grader case by 0.17 (noise), while a whole
# run going from pass to fail moves it by 0.33 (flagged). An indicator is one verdict
# per run, so at --runs 3 one run that stops firing (0.33) is flagged; pass a larger
# --noise to tolerate that.
#
# A file is refused (exit 2) unless it is a complete run: schemaVersion 1, `partial`
# false (a cost ceiling, interrupt or rejected credential sets it), cases present and
# counted in aggregates.casesTotal, unique case names, a numeric score per case, at
# least one graded with-plugin run per case, no run whose judge graders were skipped,
# and in every graded run a numeric score and a true or false verdict for each of
# the case's graders (a null or missing `passed` is a missing verdict, not a failed
# one). The two files must also share suite.ablation:
# `--ablation none` scores with-only graders, so its scores do not compare with a
# two-arm run. A different model, judge or Claude Code version is a warning, and so
# are a case whose grader definitions differ between the files and a case run a
# different number of times.
#
# Usage:
#   bash scripts/eval-compare.sh [--noise <delta>] [--allow-missing] [--json] <baseline.json> <candidate.json>
#     --noise <delta>  a drop larger than this is a regression (0..1, default 0.2)
#     --allow-missing  a case missing from the candidate is listed, not a regression
#     --json           machine-readable output
#     -h, --help       print this header
#
# Exit codes:
#   0  no regression
#   1  at least one regression
#   2  usage or environment error (bad args, missing file, missing python3), or a
#      file that is not a complete run, or two files that cannot be compared

die() { echo "eval-compare: $1" >&2; exit 2; }

json=0
allow_missing=0
noise="0.2"
files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json=1; shift ;;
    --allow-missing) allow_missing=1; shift ;;
    --noise) [ $# -ge 2 ] || die "--noise needs a value"; noise="$2"; shift 2 ;;
    -h|--help)
      # Render the header comment block (first '# ' line to the first non-comment line).
      awk '/^# /{f=1} f{ if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
      exit 0
      ;;
    -*) die "unknown argument: $1 (see --help)" ;;
    *) files+=("$1"); shift ;;
  esac
done

[ "${#files[@]}" -eq 2 ] || die "need exactly two result files: <baseline.json> <candidate.json> (see --help)"
command -v python3 >/dev/null 2>&1 || die "python3 is required (JSON parsing and report)"
for f in "${files[@]}"; do
  [ -f "$f" ] || die "result file not found: $f"
done

python3 -I - "${files[0]}" "${files[1]}" "$noise" "$json" "$allow_missing" <<'PY'
import json
import math
import sys

base_path, cand_path, noise_arg, as_json, allow_missing = sys.argv[1:6]
as_json = as_json == "1"
allow_missing = allow_missing == "1"
FIRES, QUIET = "routing-fired", "routing-quiet"


def die(msg):
    sys.stderr.write("eval-compare: %s\n" % msg)
    sys.exit(2)


def asc(text):
    return str(text).encode("ascii", "backslashreplace").decode("ascii")


try:
    noise = float(noise_arg)
except ValueError:
    die("--noise must be a number between 0 and 1, got %s" % asc(noise_arg))
if not math.isfinite(noise) or noise < 0 or noise > 1:
    die("--noise must be a number between 0 and 1, got %s" % asc(noise_arg))


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def load(path):
    """Parse one result document; exit 2 unless it is a complete run."""
    def bad(msg):
        die("%s: %s" % (asc(path), msg))

    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        bad("not a readable JSON file (%s)" % asc(exc))
    if not isinstance(doc, dict):
        bad("not a claude plugin eval result (top level is not an object)")
    if doc.get("schemaVersion") != 1:
        bad("unsupported schemaVersion %s (this script reads 1)" % asc(doc.get("schemaVersion")))
    if "partial" not in doc:
        bad("no 'partial' field, so completeness cannot be confirmed")
    if doc["partial"] is not False:
        bad("partial run (%s); rerun it to completion before comparing"
            % asc(doc.get("partialReason") or "no reason given"))
    cases = doc.get("cases")
    if not isinstance(cases, list) or not cases:
        bad("no cases in the result")
    total = (doc.get("aggregates") or {}).get("casesTotal")
    if total != len(cases):
        bad("aggregates.casesTotal is %s but %d case(s) are present; cases are missing"
            % (asc(total), len(cases)))

    out, notes = {}, []
    for case in cases:
        name = case.get("name") if isinstance(case, dict) else None
        if not isinstance(name, str) or not name:
            bad("a case has no name")
        if name in out:
            bad("case %s appears twice" % asc(name))
        score = (case.get("aggregates") or {}).get("score")
        if not is_num(score):
            bad("case %s has no numeric aggregates.score" % asc(name))
        runs = (case.get("arms") or {}).get("with")
        if not isinstance(runs, list) or not runs:
            bad("case %s has no with-plugin runs" % asc(name))

        defs = [g for g in case.get("graders") or [] if isinstance(g, dict)]
        def_names = {g.get("name") for g in defs}
        kind = None
        if FIRES in def_names and QUIET in def_names:
            bad("case %s has both %s and %s graders" % (asc(name), FIRES, QUIET))
        if FIRES in def_names:
            kind = "fires"
        elif QUIET in def_names:
            kind = "quiet"
        indicator_defs = set()
        for g in defs:
            cfg = g.get("config") or {}
            if cfg.get("arm") == "with-only" or (
                    g.get("type") == "tool_used" and cfg.get("tool") == "Skill" and cfg.get("arm") != "both"):
                indicator_defs.add(g.get("name"))

        fired = 0
        has_indicator = kind is not None
        scores, errors = [], []
        for i, run in enumerate(runs, 1):
            if not isinstance(run, dict):
                bad("case %s run %d is not an object" % (asc(name), i))
            err = run.get("error")
            if err is not None and err != "":
                # Not graded: its graders may pass on a run that did nothing.
                errors.append("run %d: %s" % (i, asc(err)))
                continue
            if not is_num(run.get("score")):
                bad("case %s run %d has no numeric score" % (asc(name), i))
            if run.get("skippedPaidGraders"):
                bad("case %s run %d skipped its judge graders (cost ceiling), so its score "
                    "is not comparable" % (asc(name), i))
            verdicts = [g for g in run.get("graders") or [] if isinstance(g, dict)]
            by_name = {}
            for g in verdicts:
                if not isinstance(g.get("passed"), bool):
                    bad("case %s run %d has no verdict for its %s grader (passed is %s)"
                        % (asc(name), i, asc(g.get("name")),
                           "missing" if "passed" not in g else asc(json.dumps(g.get("passed")))))
                by_name[g.get("name")] = g["passed"]
            for gname in sorted(n for n in def_names if isinstance(n, str)):
                if gname not in by_name:
                    bad("case %s run %d has no verdict for its %s grader" % (asc(name), i, asc(gname)))
            scores.append(float(run["score"]))
            if kind:
                grader = FIRES if kind == "fires" else QUIET
                fired += 1 if by_name[grader] == (kind == "fires") else 0
            else:
                inds = [g for g in verdicts if g.get("withOnly") is True or g.get("name") in indicator_defs]
                if inds:
                    has_indicator = True
                    fired += 1 if any(g["passed"] for g in inds) else 0
        if not scores:
            bad("every with-plugin run of case %s ended on an error (%s); rerun it"
                % (asc(name), "; ".join(errors)))
        graded = len(scores)
        mean = sum(scores) / graded
        if not errors and abs(mean - float(score)) > 1e-6:
            notes.append("case %s: aggregates.score %.4f differs from the mean of its runs %.4f; "
                         "using the mean" % (name, float(score), mean))
        if errors:
            notes.append("case %s: %d of %d run(s) ended on an error and are left out of its score "
                         "and rates (%s)" % (name, len(errors), len(runs), "; ".join(errors)))
        out[name] = {
            "score": mean,
            "runs": len(runs),
            "graded": graded,
            "errored": len(errors),
            "kind": kind,
            "fired": fired if has_indicator else None,
            "firedRate": (fired / float(graded)) if has_indicator else None,
            "graders": sorted(json.dumps([g.get("name"), g.get("type"), g.get("weight"), g.get("config")],
                                         sort_keys=True) for g in defs),
        }

    suite = doc.get("suite") or {}
    plugins = ", ".join("%s %s" % (p.get("name"), p.get("version"))
                        for p in suite.get("plugins") or [] if isinstance(p, dict)) or "no plugin"
    meta = {
        "file": path,
        "plugins": plugins,
        "claudeVersion": doc.get("claudeVersion"),
        "model": suite.get("modelOverride"),
        "judgeModel": suite.get("judgeModel"),
        "ablation": suite.get("ablation"),
        "costUsd": doc.get("costUsd"),
    }
    return meta, out, notes


base_meta, base, base_notes = load(base_path)
cand_meta, cand, cand_notes = load(cand_path)

if base_meta["ablation"] != cand_meta["ablation"]:
    die("the files were scored under different ablation modes (%s vs %s); with-only graders "
        "count only under 'none', so the scores do not compare. Rerun one of them."
        % (asc(base_meta["ablation"]), asc(cand_meta["ablation"])))

warnings = ["baseline " + n for n in base_notes] + ["candidate " + n for n in cand_notes]
for key, label in (("model", "model"), ("judgeModel", "judge model"), ("claudeVersion", "Claude Code version")):
    if base_meta[key] != cand_meta[key]:
        warnings.append("different %s: %s vs %s" % (label, base_meta[key], cand_meta[key]))


def r(x):
    """Round away float noise before comparing against --noise."""
    return round(x, 6)


shared = [n for n in sorted(base) if n in cand]
only_base = [n for n in sorted(base) if n not in cand]
only_cand = [n for n in sorted(cand) if n not in base]

SIDE_KEYS = ("score", "runs", "graded", "errored", "fired", "firedRate")
rows = []
regressions = []
notes = []
for name in only_base:
    if not allow_missing:
        regressions.append("%s: in the baseline but missing from the candidate" % name)
for name in shared:
    b, c = base[name], cand[name]
    kind = c["kind"]
    if b["kind"] != c["kind"]:
        warnings.append("case %s is %s in the baseline and %s in the candidate; using the candidate"
                        % (name, b["kind"] or "not a routing case", c["kind"] or "not a routing case"))
    if b["graders"] != c["graders"]:
        warnings.append("case %s has different graders in the two files, so its scores may not compare"
                        % name)
    if b["runs"] != c["runs"]:
        warnings.append("case %s has %d run(s) in the baseline and %d in the candidate"
                        % (name, b["runs"], c["runs"]))
    delta = r(c["score"] - b["score"])
    reasons, better, note = [], [], None
    if delta < -noise:
        reasons.append("score %+.2f" % delta)
    elif delta > noise:
        better.append("score %+.2f" % delta)
    if b["firedRate"] is not None and c["firedRate"] is not None:
        fdelta = r(c["firedRate"] - b["firedRate"])
        moved = "fired %.2f -> %.2f" % (b["firedRate"], c["firedRate"])
        if kind == "quiet":
            if fdelta > noise:
                reasons.append(moved + " (should stay quiet)")
            elif fdelta < -noise:
                better.append(moved)
        elif kind == "fires":
            if fdelta < -noise:
                reasons.append(moved)
            elif fdelta > noise:
                better.append(moved)
        elif abs(fdelta) > noise:
            # Any other case: the score is the measurement and the indicator is
            # context, so a move is a note and never changes the status.
            note = "workflow loaded %.2f -> %.2f" % (b["firedRate"], c["firedRate"])
            notes.append("%s: %s" % (name, note))
    if reasons:
        status = "regressed"
        regressions.append("%s: %s" % (name, "; ".join(reasons)))
    elif better:
        status = "improved"
    elif delta == 0 and (kind is None or b["firedRate"] == c["firedRate"]):
        status = "same"
    else:
        status = "within noise"
    rows.append({
        "name": name,
        "kind": kind,
        "baseline": {k: b[k] for k in SIDE_KEYS},
        "candidate": {k: c[k] for k in SIDE_KEYS},
        "delta": delta,
        "status": status,
        "reasons": reasons or better,
        "note": note,
    })


def rate(kind, side, quiet):
    pool = [side[n] for n in shared if cand[n]["kind"] == kind and side[n]["kind"] == kind]
    runs = sum(p["graded"] for p in pool)
    hits = sum((p["graded"] - p["fired"]) if quiet else p["fired"] for p in pool)
    return {"cases": len(pool), "runs": runs, "hits": hits,
            "rate": (hits / float(runs)) if runs else None}


totals = {"sharedCases": len(shared)}
for key, kind, quiet, label in (("firesRate", "fires", False, "fires rate"),
                                ("staysQuietRate", "quiet", True, "stays-quiet rate")):
    tb, tc = rate(kind, base, quiet), rate(kind, cand, quiet)
    d = r(tc["rate"] - tb["rate"]) if tb["rate"] is not None and tc["rate"] is not None else None
    totals[key] = {"baseline": tb, "candidate": tc, "delta": d}
    if d is not None and d < -noise:
        regressions.append("%s: %.2f -> %.2f" % (label, tb["rate"], tc["rate"]))
mb = sum(base[n]["score"] for n in shared) / len(shared) if shared else None
mc = sum(cand[n]["score"] for n in shared) / len(shared) if shared else None
totals["meanScore"] = {"baseline": mb, "candidate": mc,
                       "delta": r(mc - mb) if shared else None}
if not shared:
    warnings.append("the files share no case, so nothing was compared")

if as_json:
    json.dump({
        "baseline": base_meta,
        "candidate": cand_meta,
        "noise": noise,
        "allowMissing": allow_missing,
        "cases": rows,
        "onlyInBaseline": only_base,
        "onlyInCandidate": only_cand,
        "totals": totals,
        "regressions": regressions,
        "notes": notes,
        "warnings": warnings,
        "regressed": bool(regressions),
    }, sys.stdout, indent=2)
    sys.stdout.write("\n")
    sys.exit(1 if regressions else 0)


def fired_cell(side):
    return "-" if side["fired"] is None else "%d/%d" % (side["fired"], side["graded"])


def describe(meta):
    return "%s, Claude Code %s, model %s, judge %s, ablation %s" % (
        meta["plugins"], meta["claudeVersion"], meta["model"] or "default",
        meta["judgeModel"] or "default", meta["ablation"])


print("eval compare: %s -> %s" % (asc(base_path), asc(cand_path)))
print("  baseline:  %s" % asc(describe(base_meta)))
print("  candidate: %s" % asc(describe(cand_meta)))
print("  noise: %.2f (a drop larger than this is a regression)" % noise)
print("  FIRED: graded runs in which the plugin fired / graded with-plugin runs; a quiet case should show 0")
print()
width = max([len("CASE")] + [len(asc(n)) for n in shared]) + 2
print("%s%-7s%-6s%-6s%-7s%-9s%-9s%s" % ("CASE".ljust(width), "KIND", "BASE", "CAND", "DELTA",
                                        "FIRED-B", "FIRED-C", "STATUS"))
for row in rows:
    status = row["status"]
    if row["reasons"]:
        status += ": " + "; ".join(row["reasons"])
    if row["note"]:
        status += "; note: " + row["note"]
    print("%s%-7s%-6.2f%-6.2f%-+7.2f%-9s%-9s%s" % (
        asc(row["name"]).ljust(width), row["kind"] or "-", row["baseline"]["score"],
        row["candidate"]["score"], row["delta"], fired_cell(row["baseline"]),
        fired_cell(row["candidate"]), asc(status)))
if not rows:
    print("  (no shared cases)")

if only_base or only_cand:
    print()
    print("ONLY IN ONE FILE (not compared)")
    for n in only_base:
        print("  %s  baseline only (%s)" % (asc(n), "allowed by --allow-missing" if allow_missing
                                            else "missing from the candidate: a regression"))
    for n in only_cand:
        print("  %s  candidate only" % asc(n))

print()
print("TOTALS (cases in both files)")
if shared:
    print("  mean score        %.2f -> %.2f (%+.2f)" % (mb, mc, totals["meanScore"]["delta"]))
for key, label in (("firesRate", "fires rate      "), ("staysQuietRate", "stays-quiet rate")):
    t = totals[key]
    if t["baseline"]["rate"] is None or t["candidate"]["rate"] is None:
        print("  %s  n/a (no routing cases of this kind in both files)" % label)
        continue
    print("  %s  %d/%d (%.2f) -> %d/%d (%.2f), %d case(s)" % (
        label, t["baseline"]["hits"], t["baseline"]["runs"], t["baseline"]["rate"],
        t["candidate"]["hits"], t["candidate"]["runs"], t["candidate"]["rate"],
        t["candidate"]["cases"]))

if warnings:
    print()
    print("WARNINGS")
    for w in warnings:
        print("  %s" % asc(w))

counts = {}
for row in rows:
    counts[row["status"]] = counts.get(row["status"], 0) + 1
print()
print("summary: %d regression(s), %d improved, %d within noise, %d same, %d case(s) in one file only"
      % (len(regressions), counts.get("improved", 0), counts.get("within noise", 0),
         counts.get("same", 0), len(only_base) + len(only_cand)))
if regressions:
    print("REGRESSIONS")
    for line in regressions:
        print("  %s" % asc(line))
if notes:
    print("NOTES (not regressions; they do not change the exit code)")
    for line in notes:
        print("  %s" % asc(line))
sys.exit(1 if regressions else 0)
PY
