#!/usr/bin/env bash
set -euo pipefail

# mtk-savings.sh — report MTK's context-token footprint and the savings its
# architecture already delivers. Every number is derived from the installed
# files or the on-disk compression log — nothing is fabricated or estimated
# from telemetry MTK does not collect.
#
# Usage:
#   bash scripts/mtk-savings.sh          # human-readable report
#
# Token approximation is ~4 chars/token (labelled). This is for size awareness,
# not billing — mirrors the figure validate-toolkit.sh prints.

TOK() { echo $(( ${1:-0} / 4 )); }   # chars -> approx tokens

sum_bytes() { # sum -c bytes of the file list on stdin; 0 if none
  local total=0 f
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    total=$(( total + $(wc -c < "$f" | tr -d ' ') ))
  done
  echo "$total"
}

# ---- always-on: skill descriptions (load into EVERY session) ----
desc_chars=0; skill_count=0
if ls .claude/skills/*/SKILL.md >/dev/null 2>&1; then
  for skill in .claude/skills/*/SKILL.md; do
    desc="$(awk '/^description:/ { sub(/^description:[[:space:]]*/, ""); print; exit }' "$skill")"
    desc_chars=$(( desc_chars + ${#desc} ))
    skill_count=$(( skill_count + 1 ))
  done
fi

# ---- always-on: agent descriptions ----
agent_desc_chars=0
if ls .claude/agents/*.md >/dev/null 2>&1; then
  for a in .claude/agents/*.md; do
    # handle both single-line and folded (">") descriptions
    d="$(awk '
      /^description:[[:space:]]*>/ { fold=1; next }
      fold==1 && /^[[:space:]]+/   { sub(/^[[:space:]]+/,""); buf=buf $0 " "; next }
      fold==1                      { print buf; exit }
      /^description:/              { sub(/^description:[[:space:]]*/,""); print; exit }
    ' "$a")"
    agent_desc_chars=$(( agent_desc_chars + ${#d} ))
  done
fi

claude_chars=0;  [ -f CLAUDE.md ] && claude_chars=$(wc -c < CLAUDE.md | tr -d ' ')
index_chars=0;   [ -f .claude/rules/INDEX.md ] && index_chars=$(wc -c < .claude/rules/INDEX.md | tr -d ' ')

alwayson_chars=$(( desc_chars + agent_desc_chars + claude_chars + index_chars ))

# ---- deferred: kept OUT of always-on by progressive disclosure ----
ref_chars=$(find .claude/references -name '*.md' -type f 2>/dev/null | sum_bytes)
ref_count=$(find .claude/references -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
rulebody_chars=$(find .claude/rules -name '*.md' ! -name 'INDEX.md' 2>/dev/null | sum_bytes)
manifest_chars=0; [ -f .claude/manifest.json ] && manifest_chars=$(wc -c < .claude/manifest.json | tr -d ' ')
deferred_chars=$(( ref_chars + rulebody_chars + manifest_chars ))

# ---- review offload: agent bodies run in isolated context ----
agentbody_chars=$(find .claude/agents -name '*.md' -type f 2>/dev/null | sum_bytes)
agent_count=$(find .claude/agents -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')

# ---- on-demand skill bodies (one loads when its skill runs) ----
skillbody_chars=$(find .claude/skills -name 'SKILL.md' -type f 2>/dev/null | sum_bytes)

printf '\nMTK context footprint & savings  (approx, ~4 chars/token)\n'
printf '════════════════════════════════════════════════════════════\n'

printf '\nAlways-on — loaded into EVERY session:\n'
printf '  skill descriptions   %8d chars  ~%6d tok  (%d skills)\n' "$desc_chars" "$(TOK "$desc_chars")" "$skill_count"
printf '  CLAUDE.md            %8d chars  ~%6d tok\n' "$claude_chars" "$(TOK "$claude_chars")"
printf '  rules/INDEX.md       %8d chars  ~%6d tok\n' "$index_chars" "$(TOK "$index_chars")"
printf '  agent descriptions   %8d chars  ~%6d tok  (%d agents)\n' "$agent_desc_chars" "$(TOK "$agent_desc_chars")" "$agent_count"
printf '  ── always-on floor              ~%6d tok\n' "$(TOK "$alwayson_chars")"

printf '\nKept OUT of always-on by progressive disclosure (load only when relevant):\n'
printf '  references           %8d chars  ~%6d tok  (%d files, glob-gated)\n' "$ref_chars" "$(TOK "$ref_chars")" "$ref_count"
printf '  rule bodies          %8d chars  ~%6d tok  (path-gated)\n' "$rulebody_chars" "$(TOK "$rulebody_chars")"
printf '  manifest.json        %8d chars  ~%6d tok  (MCP-gated, never inlined)\n' "$manifest_chars" "$(TOK "$manifest_chars")"
printf '  ── deferred total               ~%6d tok  ← would be always-on if inlined into CLAUDE.md\n' "$(TOK "$deferred_chars")"

printf '\nReview offloaded to isolated subagent context:\n'
printf '  %d agent bodies       %8d chars  ~%6d tok  (never enters the main thread)\n' "$agent_count" "$agentbody_chars" "$(TOK "$agentbody_chars")"

printf '\nOn-demand skill bodies (one loads when its skill runs, not all at once):\n'
printf '  %d SKILL.md bodies    %8d chars  ~%6d tok\n' "$skill_count" "$skillbody_chars" "$(TOK "$skillbody_chars")"

# ---- output compression (real on-disk log) ----
COMP=".claude/observability/compression.jsonl"
printf '\nOutput compression (scripts/mtk-compress.sh):\n'
if [ -f "$COMP" ] && command -v python3 >/dev/null 2>&1; then
  python3 - "$COMP" "${CLAUDE_CODE_SESSION_ID:-}" <<'PY'
import json, sys
path, session = sys.argv[1], sys.argv[2]
ti=to=tr=0; si=so=sr=0
for line in open(path):
    line=line.strip()
    if not line: continue
    try: r=json.loads(line)
    except json.JSONDecodeError: continue
    ti+=r.get("in_chars",0); to+=r.get("out_chars",0); tr+=1
    if session and r.get("session")==session:
        si+=r.get("in_chars",0); so+=r.get("out_chars",0); sr+=1
def pct(o,i): return f"{(1-o/i)*100:.0f}%" if i else "0%"
print(f"  all-time   saved ~{(ti-to)//4:,} tok over {tr} runs (ratio {pct(to,ti)})")
if session:
    print(f"  session    saved ~{(si-so)//4:,} tok over {sr} runs (ratio {pct(so,si)})")
PY
else
  printf '  (no compression log yet at %s — pipe long output through mtk-compress to accrue)\n' "$COMP"
fi

printf '\nSummary: MTK keeps ~%d tok out of your always-on context (deferred + review offload),\n' "$(TOK $(( deferred_chars + agentbody_chars )))"
printf 'compresses tool output on demand, and holds the always-on floor to ~%d tok/session.\n\n' "$(TOK "$alwayson_chars")"
