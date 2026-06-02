#!/usr/bin/env bash
set -euo pipefail

# coverage.sh — Behavioral-eval coverage + sprawl report across all skills.
#
# As the skill count grows, track which skills have
# behavioral evals (not just structural validation) and flag likely-overlapping
# skills (a cheap "sprawl" signal) so the set stays curated.
#
# Coverage: a skill is "covered" if evals/<skill>/ contains >=1 eval-*.md
#           scenario OR a prompts.jsonl (the aggregate-runner format).
# Overlap : pairwise Jaccard similarity of skill `description:` word sets; pairs
#           at/above THRESHOLD are flagged as sprawl candidates (advisory only).
#
# Usage:
#   bash scripts/skill-eval/coverage.sh            # human-readable report
#   bash scripts/skill-eval/coverage.sh --json     # machine-readable (CI)
#
# Exit status is always 0 — this report is advisory, never a gate.

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

SKILLS_DIR=".claude/skills"
EVALS_DIR="evals"
THRESHOLD="${COVERAGE_OVERLAP_THRESHOLD:-0.45}"

MODE="human"
[ "${1:-}" = "--json" ] && MODE="json"

command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 2; }

# Collect: name<TAB>description (description from frontmatter, single line).
facts="$(mktemp)"
for d in "$SKILLS_DIR"/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  skill_file="$d/SKILL.md"
  [ -f "$skill_file" ] || continue
  desc="$(awk '
    NR==1 && $0!="---"{exit}
    /^---[[:space:]]*$/{fm++; if(fm==2)exit; next}
    fm==1 && /^description:[[:space:]]*/{ sub(/^description:[[:space:]]*/,""); print; exit }
  ' "$skill_file")"
  printf '%s\t%s\n' "$name" "$desc" >> "$facts"
done

total="$(wc -l < "$facts" | tr -d ' ')"

# Coverage per skill.
cov="$(mktemp)"
covered=0
while IFS=$'\t' read -r name _; do
  if ls "$EVALS_DIR/$name"/eval-*.md >/dev/null 2>&1 || [ -f "$EVALS_DIR/$name/prompts.jsonl" ]; then
    printf '%s\t1\n' "$name" >> "$cov"; covered=$((covered+1))
  else
    printf '%s\t0\n' "$name" >> "$cov"
  fi
done < "$facts"

# Overlap via Jaccard on description word sets (stopwords stripped).
overlaps="$(mktemp)"
awk -F'\t' -v thr="$THRESHOLD" '
  BEGIN{
    split("the a an to and or of for when use used uses using in on with this that is are be as not no your you it its skill before after into per via from each any all set get run", sw, " ");
    for(i in sw) stop[sw[i]]=1;
  }
  {
    name[NR]=$1; raw=tolower($2); gsub(/[^a-z0-9 ]/," ",raw);
    n=split(raw,w," "); delete seen;
    for(i=1;i<=n;i++){ t=w[i]; if(t=="" || stop[t] || length(t)<3) continue; seen[t]=1 }
    cnt=0; for(t in seen){ words[NR,cnt++]=t } size[NR]=cnt;
    # store set as string keys
    for(t in seen) has[NR,t]=1;
    rows=NR;
  }
  END{
    for(a=1;a<=rows;a++) for(b=a+1;b<=rows;b++){
      inter=0;
      for(k=0;k<size[a];k++){ t=words[a,k]; if((b,t) in has) inter++ }
      uni=size[a]+size[b]-inter;
      if(uni==0) continue;
      j=inter/uni;
      if(j>=thr) printf "%s\t%s\t%.2f\n", name[a], name[b], j;
    }
  }
' "$facts" | sort -t$'\t' -k3 -rn > "$overlaps"

pct=0
[ "$total" -gt 0 ] && pct=$(( covered * 100 / total ))

if [ "$MODE" = "json" ]; then
  jq -n \
    --arg total "$total" --arg covered "$covered" --arg pct "$pct" --arg thr "$THRESHOLD" \
    --slurpfile c <(jq -R 'split("\t")|{skill:.[0],covered:(.[1]=="1")}' "$cov" | jq -s '.') \
    --slurpfile o <(jq -R 'split("\t")|{a:.[0],b:.[1],jaccard:(.[2]|tonumber)}' "$overlaps" | jq -s '.') \
    '{total:($total|tonumber), covered:($covered|tonumber),
      coverage_pct:($pct|tonumber), overlap_threshold:($thr|tonumber),
      skills:$c[0], overlap_candidates:$o[0]}'
else
  echo "Skill-eval coverage: $covered / $total skills ($pct%) have behavioral evals."
  echo
  echo "Uncovered skills (no evals/<skill>/eval-*.md):"
  awk -F'\t' '$2=="0"{print "  - "$1}' "$cov"
  echo
  ocount="$(wc -l < "$overlaps" | tr -d ' ')"
  echo "Sprawl candidates (description Jaccard >= $THRESHOLD) — advisory, $ocount pair(s):"
  if [ "$ocount" -eq 0 ]; then
    echo "  (none)"
  else
    awk -F'\t' '{printf "  - %s  ~  %s  (%.2f)\n", $1, $2, $3}' "$overlaps"
  fi
fi

rm -f "$facts" "$cov" "$overlaps"
