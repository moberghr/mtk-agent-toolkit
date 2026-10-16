#!/usr/bin/env bash

set -euo pipefail

# workflow-artifact.sh — manage durable workflow state under .mtk/workflows/
#
# Subcommands:
#   init <type> [--goal "<text>"]    Create a new workflow artifact, print UUID
#   event <uuid> <type> [--data '<json>'] [--ts <iso8601>]
#                                    Append event to .events.jsonl. --ts replays a
#                                    timestamp captured elsewhere (e.g. a dynamic
#                                    workflow's per-batch dispatch/return times);
#                                    default is now.
#   batch <uuid> <op...> [-- <op...>]... Run several set/event/gate/criteria ops in
#                                    ONE invocation, separated by a bare `--`, so a
#                                    checkpoint's bookkeeping rides in the same
#                                    shell call as the checkpoint itself. With no
#                                    ops on argv, reads one JSON array per line
#                                    from stdin (["event","phase_started","--data","{}"]).
#   set <uuid> <key=value>...        Update top-level fields in {uuid}.json
#   read <uuid>                      Print {uuid}.json to stdout
#   list                             List active workflows (id, type, status, updated)
#   gate <uuid> <gate_name> <pass|fail> [--reason "<text>"]
#                                    gate_name one of: plan_trust_gate |
#                                    phase_exit_gate | failure_stop_gate |
#                                    memory_sync_gate.
#                                    Record gate decision as event + status update
#   criteria <uuid> <SCn=status>...  Set per-criterion verification status
#                                    Status values: pending | verified | re-armed
#                                    --rearm-all  Reset all verified → re-armed
#   remediation <uuid> <trigger> [--score N] [--open N | --findings <file.json>]
#                                    Record a remediation attempt; line 1 is always
#                                    the verdict: ESCALATE when iterations >=
#                                    MTK_MAX_REMEDIATION_ITERS (default 3), the
#                                    score plateaus (higher is better), or the
#                                    open-finding count stalls (--open N, lower is
#                                    better: two calls without a decrease add a
#                                    "reason: stalled" line), else CONTINUE.
#                                    --findings reads a JSON array of findings or a
#                                    lane result with findings[], gives each a
#                                    stable F-<10 hex> UID (file|rule|snippet),
#                                    prints FIXED / STILL_OPEN / NEW lines against
#                                    the previous call and feeds its open count as N.
#                                    Unparseable --findings file: exit 2.
#   review-input <uuid> --record|--check
#                                    Bind a review to the tree it read: --record
#                                    stores the working-tree fingerprint (.mtk/
#                                    excluded); --check exits 0 unchanged (also
#                                    after committing that tree), 1 changed (prints
#                                    recorded=/current=), 2 nothing recorded or
#                                    fingerprint not computable
#   seal <uuid> <path>...            Record a SHA-256 approval seal over the given
#                                    artifact bodies (spec/plan) at approval time,
#                                    plus a hash of the spec sidecar's frozen
#                                    success_criteria block (id/observable/
#                                    evidence_channel) when the sidecar exists
#   verify-seal <uuid>               Re-check the recorded seal and criteria hash;
#                                    exit 0 match, 1 stale (prints sealed=/current=),
#                                    2 uncheckable (unexpected error), 3 no seal
#   abandon <uuid> [--reason "<text>"]  Mark workflow abandoned
#   prune --older-than <days> [--dry-run] [--force]
#                                    Delete workflows of any status not updated
#                                    within <days> (minimum 1; 0 needs --force),
#                                    with their event log, .artifact.md and
#                                    per-uuid directory. Never touches an active
#                                    workflow updated within <days>.
#   trap add <uuid> --title "<t>" [--body "<b>"] [--phase p] [--severity warn|high]
#                                    Record a carried-forward trap (a written,
#                                    specific gotcha) in results.trap_list —
#                                    idempotent by title; batchable.
#   trap list <uuid>                 Print recorded traps, ready to paste into the
#                                    next phase's or implementer's brief.
#
# Storage: .mtk/workflows/{uuid}.json + .mtk/workflows/{uuid}.events.jsonl
# Artifacts live OUTSIDE .claude/ to avoid Claude Code's sensitive-file gate.
# Add `.mtk/` to .gitignore in target repos (not committed by default).

ROOT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
WF_DIR="${ROOT_DIR}/.mtk/workflows"

fail() { printf 'workflow-artifact: %s\n' "$1" >&2; exit 1; }

ensure_dir() {
  mkdir -p "$WF_DIR"
}

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

new_uuid() {
  # Compact ULID-like id: timestamp + 6 random hex chars. No external deps.
  local stamp rand
  stamp="$(date -u +"%Y%m%dT%H%M%SZ")"
  rand="$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 6 || true)"
  if [ -z "$rand" ]; then
    rand="$(printf '%06x' "$$")"
  fi
  printf 'wf-%s-%s' "$stamp" "$rand"
}

json_escape() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))'
}

cmd_init() {
  local wf_type="${1:-}"
  shift || true
  [ -n "$wf_type" ] || fail "init requires <type> (BUILD|DEBUG|REVIEW|PLAN|FIX|setup-audit|setup-bootstrap)"
  case "$wf_type" in BUILD|DEBUG|REVIEW|PLAN|FIX|setup-audit|setup-bootstrap) ;; *) fail "unknown workflow type: $wf_type" ;; esac

  local goal=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --goal) goal="${2:-}"; shift 2 ;;
      *) fail "unknown flag: $1" ;;
    esac
  done

  ensure_dir
  local uuid created
  uuid="$(new_uuid)"
  created="$(iso_now)"

  local goal_json
  goal_json="$(printf '%s' "$goal" | json_escape)"

  cat > "${WF_DIR}/${uuid}.json" <<EOF
{
  "workflow_uuid": "${uuid}",
  "workflow_type": "${wf_type}",
  "schema_version": 1,
  "created_at": "${created}",
  "updated_at": "${created}",
  "status": "active",
  "phase_cursor": "phase-0",
  "intent": { "goal": ${goal_json} },
  "gates": {
    "plan_trust_gate": "pending",
    "phase_exit_gate": "pending",
    "failure_stop_gate": "pending",
    "memory_sync_gate": "pending"
  },
  "results": {},
  "remediation_history": []
}
EOF

  : > "${WF_DIR}/${uuid}.events.jsonl"
  cmd_event "$uuid" "workflow_started" --data "{\"workflow_type\":\"${wf_type}\"}" >/dev/null

  printf '%s\n' "$uuid"
}

cmd_event() {
  local uuid="${1:-}"
  local etype="${2:-}"
  shift 2 || true
  [ -n "$uuid" ] || fail "event requires <uuid>"
  [ -n "$etype" ] || fail "event requires <type>"
  [ -f "${WF_DIR}/${uuid}.events.jsonl" ] || fail "no event log for $uuid (run init first)"

  local data="{}"
  local now=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --data) data="${2-}"; [ -n "$data" ] || data="{}"; shift 2 ;;
      --ts)
        now="${2-}"
        # bash regex, not a pipe into grep -q (S3.17)
        [[ "$now" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$ ]] \
          || fail "event: --ts must be ISO-8601 (got: $now)"
        shift 2 ;;
      *) fail "unknown flag: $1" ;;
    esac
  done

  [ -n "$now" ] || now="$(iso_now)"
  python3 - "$uuid" "$etype" "$now" "$data" >> "${WF_DIR}/${uuid}.events.jsonl" <<'PY'
import json, sys
uuid, etype, now, data_raw = sys.argv[1:5]
try:
    data = json.loads(data_raw) if data_raw else {}
except json.JSONDecodeError as e:
    print(f"workflow-artifact: invalid --data JSON: {e}", file=sys.stderr)
    sys.exit(1)
sys.stdout.write(json.dumps({
    "ts": now,
    "workflow_uuid": uuid,
    "event": etype,
    "data": data
}, separators=(",", ":")) + "\n")
PY

  # Bump updated_at on the main artifact, and advance phase_cursor when this
  # event is a phase_started marker carrying a phase. The event log is the
  # source of truth; the cursor is derived from it so a resume driven off
  # phase_cursor alone never restarts at phase-0 after progress was made.
  python3 - "${WF_DIR}/${uuid}.json" "$now" "$etype" "$data" <<'PY'
import json, sys
path, now, etype, data_raw = sys.argv[1:5]
with open(path) as f: doc = json.load(f)
doc["updated_at"] = now
if etype == "phase_started":
    try:
        phase = json.loads(data_raw).get("phase") if data_raw else None
    except json.JSONDecodeError:
        phase = None
    if phase:
        doc["phase_cursor"] = phase
with open(path, "w") as f: json.dump(doc, f, indent=2)
PY

  # Confirm on stdout (internal callers redirect stdout to /dev/null, so only
  # a top-level `event` invocation surfaces this).
  printf 'workflow-artifact: recorded %s for %s\n' "$etype" "$uuid"
}

cmd_set() {
  local uuid="${1:-}"
  shift || true
  [ -n "$uuid" ] || fail "set requires <uuid>"
  [ -f "${WF_DIR}/${uuid}.json" ] || fail "no artifact for $uuid"
  [ $# -gt 0 ] || fail "set requires at least one key=value"

  python3 - "${WF_DIR}/${uuid}.json" "$(iso_now)" "$@" <<'PY'
import json, sys
path = sys.argv[1]
now = sys.argv[2]
pairs = sys.argv[3:]
with open(path) as f: doc = json.load(f)
for pair in pairs:
    if "=" not in pair:
        print(f"workflow-artifact: bad pair: {pair}", file=sys.stderr); sys.exit(1)
    k, v = pair.split("=", 1)
    # Dotted path: gates.plan_trust_gate=pass
    parts = k.split(".")
    target = doc
    for p in parts[:-1]:
        target = target.setdefault(p, {})
    # Try JSON-decode value (numbers, bools, arrays); else string.
    try: parsed = json.loads(v)
    except json.JSONDecodeError: parsed = v
    target[parts[-1]] = parsed
doc["updated_at"] = now
with open(path, "w") as f: json.dump(doc, f, indent=2)
PY
  cmd_event "$uuid" "field_updated" --data "{\"keys\":$(printf '%s\n' "$@" | python3 -c 'import sys, json; print(json.dumps([l.split("=",1)[0] for l in sys.stdin.read().splitlines() if l]))')}" >/dev/null
  printf 'workflow-artifact: set %s on %s\n' "$*" "$uuid"
}

cmd_read() {
  local uuid="${1:-}"
  [ -n "$uuid" ] || fail "read requires <uuid>"
  [ -f "${WF_DIR}/${uuid}.json" ] || fail "no artifact for $uuid"
  cat "${WF_DIR}/${uuid}.json"
}

cmd_list() {
  ensure_dir
  if ! ls "${WF_DIR}"/*.json >/dev/null 2>&1; then
    printf '(no workflows)\n'
    return 0
  fi
  # One python3 pass over every artifact (was one interpreter per file).
  python3 - "${WF_DIR}" <<'PY'
import glob, json, os, sys
print(f"{'UUID':<44} {'TYPE':<7} {'STATUS':<10} UPDATED")
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.json"))):
    try:
        with open(path) as f: d = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"{os.path.basename(path):<44} (unreadable: {e})", file=sys.stderr); continue
    print(f"{d.get('workflow_uuid',''):<44} {d.get('workflow_type',''):<7} {d.get('status',''):<10} {d.get('updated_at','')}")
PY
}

# batch <uuid> <op...> [-- <op...>]...  — several ops, one invocation.
# Each op is a normal subcommand argv WITHOUT the uuid: `set k=v`, `event t --data j`,
# `gate g pass --reason r`, `criteria SC1=verified`, `remediation trig --score n`.
# Ops run in order; the first failure stops the batch (earlier ops stay applied,
# each already logged its own event). With no ops on argv, one JSON array per
# stdin line is read instead — same argv shape.
cmd_batch() {
  local uuid="${1:-}"
  shift || true
  [ -n "$uuid" ] || fail "batch requires <uuid>"
  [ -f "${WF_DIR}/${uuid}.json" ] || fail "no artifact for $uuid"

  local -a ops_json=()
  if [ $# -gt 0 ]; then
    # Split argv on bare `--` into JSON arrays so both input shapes share one loop.
    local -a cur=()
    local tok
    for tok in "$@" "--"; do
      if [ "$tok" = "--" ]; then
        if [ ${#cur[@]} -gt 0 ]; then
          ops_json+=("$(printf '%s\0' "${cur[@]}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().split("\0")[:-1]))')")
          cur=()
        fi
      else
        cur+=("$tok")
      fi
    done
  else
    local line
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      ops_json+=("$line")
    done
  fi
  [ ${#ops_json[@]} -gt 0 ] || fail "batch: no ops given (argv ops separated by --, or JSON arrays on stdin)"

  local op_json n=0
  for op_json in "${ops_json[@]}"; do
    local -a argv=()
    # Decode the JSON array back to argv, NUL-delimited so values may hold spaces/newlines.
    while IFS= read -r -d '' tok; do argv+=("$tok"); done < <(
      printf '%s' "$op_json" | python3 -c '
import json, sys
try:
    items = json.loads(sys.stdin.read())
except json.JSONDecodeError as e:
    print(f"workflow-artifact: batch: bad op JSON: {e}", file=sys.stderr); sys.exit(1)
if not isinstance(items, list) or not items or not all(isinstance(i, str) for i in items):
    print("workflow-artifact: batch: each op must be a non-empty JSON array of strings", file=sys.stderr); sys.exit(1)
sys.stdout.write("\0".join(items) + "\0")'
    )
    [ ${#argv[@]} -gt 0 ] || fail "batch: op $((n+1)) is empty or malformed"
    local sub="${argv[0]}"
    case "$sub" in
      set|event|gate|criteria|remediation|seal) main "$sub" "$uuid" "${argv[@]:1}" ;;
      # trap takes <add|list> before the uuid: `trap add --title …` in a batch op.
      trap) [ ${#argv[@]} -ge 2 ] || fail "batch: op $((n+1)): trap needs <add|list>"
            main trap "${argv[1]}" "$uuid" "${argv[@]:2}" ;;
      *) fail "batch: op $((n+1)): '$sub' is not batchable (allowed: set event gate criteria remediation seal trap)" ;;
    esac
    n=$((n+1))
  done
  printf 'workflow-artifact: batch applied %d op(s) to %s\n' "$n" "$uuid"
}

cmd_criteria() {
  local uuid="${1:-}"
  shift || true
  [ -n "$uuid" ] || fail "criteria requires <uuid>"
  [ -f "${WF_DIR}/${uuid}.json" ] || fail "no artifact for $uuid"
  [ $# -gt 0 ] || fail "criteria requires at least one SCn=status or --rearm-all"

  local rearm_all=0
  local pairs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --rearm-all) rearm_all=1; shift ;;
      *) pairs+=("$1"); shift ;;
    esac
  done

  local valid_statuses="pending verified re-armed"
  for pair in "${pairs[@]:-}"; do
    [ -z "$pair" ] && continue
    [[ "$pair" == *=* ]] || fail "criteria: expected SCn=status, got: $pair"
    local key val
    key="${pair%%=*}"
    val="${pair#*=}"
    case " $valid_statuses " in
      *" $val "*) ;;
      *) fail "criteria: invalid status '$val' — must be one of: $valid_statuses" ;;
    esac
  done

  python3 - "${WF_DIR}/${uuid}.json" "$(iso_now)" "$rearm_all" "${pairs[@]:-}" <<'PY'
import json, sys
path = sys.argv[1]
now = sys.argv[2]
rearm_all = sys.argv[3] == "1"
pairs = [a for a in sys.argv[4:] if a]
with open(path) as f: doc = json.load(f)
if "criteria_status" not in doc:
    doc["criteria_status"] = {}
cs = doc["criteria_status"]
if rearm_all:
    for k in list(cs.keys()):
        if cs[k] == "verified":
            cs[k] = "re-armed"
for pair in pairs:
    k, v = pair.split("=", 1)
    cs[k] = v
doc["updated_at"] = now
with open(path, "w") as f: json.dump(doc, f, indent=2)
PY

  if [ "$rearm_all" -eq 1 ]; then
    cmd_event "$uuid" "field_updated" --data '{"keys":["criteria_status"],"reason":"re-arm-all"}' >/dev/null
  elif [ ${#pairs[@]} -gt 0 ]; then
    local keys_json
    keys_json="$(printf '%s\n' "${pairs[@]}" | python3 -c 'import sys, json; print(json.dumps([l.split("=",1)[0] for l in sys.stdin.read().splitlines() if l]))')"
    cmd_event "$uuid" "field_updated" --data "{\"keys\":${keys_json},\"context\":\"criteria_status\"}" >/dev/null
  fi
}

cmd_abandon() {
  local uuid="${1:-}"
  shift || true
  [ -n "$uuid" ] || fail "abandon requires <uuid>"
  [ -f "${WF_DIR}/${uuid}.json" ] || fail "no artifact for $uuid"

  local reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) reason="${2:-}"; shift 2 ;;
      *) fail "unknown flag: $1" ;;
    esac
  done

  cmd_set "$uuid" "status=abandoned" >/dev/null
  local reason_json
  reason_json="$(printf '%s' "$reason" | json_escape)"
  cmd_event "$uuid" "workflow_failed" --data "{\"reason\":${reason_json}}" >/dev/null
  printf 'workflow %s -> abandoned\n' "$uuid"
}

cmd_gate() {
  local uuid="${1:-}"
  local gate="${2:-}"
  local result="${3:-}"
  shift 3 || true
  [ -n "$uuid" ] && [ -n "$gate" ] && [ -n "$result" ] || fail "gate requires <uuid> <gate_name> <pass|fail>"
  case "$result" in pass|fail) ;; *) fail "gate result must be 'pass' or 'fail'" ;; esac
  # skill_precedence_gate was dropped: no skill ever recorded it. Old artifacts
  # that still carry the key load fine (nothing validates gates on read); it
  # just cannot be written any more.
  local valid_gates="plan_trust_gate phase_exit_gate failure_stop_gate memory_sync_gate"
  case " $valid_gates " in
    *" $gate "*) ;;
    *) fail "unknown gate: $gate — must be one of: $valid_gates (see .claude/references/orchestration-gates.md)" ;;
  esac

  local reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) reason="${2:-}"; shift 2 ;;
      *) fail "unknown flag: $1" ;;
    esac
  done

  cmd_set "$uuid" "gates.${gate}=${result}" >/dev/null
  local reason_json
  reason_json="$(printf '%s' "$reason" | json_escape)"
  cmd_event "$uuid" "gate_decided" --data "{\"gate\":\"${gate}\",\"result\":\"${result}\",\"reason\":${reason_json}}" >/dev/null
  printf 'gate %s -> %s\n' "$gate" "$result"
}

cmd_remediation() {
  local uuid="${1:-}"
  shift || true
  local trigger="${1:-}"
  shift || true
  [ -n "$uuid" ] || fail "remediation requires <uuid>"
  [ -n "$trigger" ] || fail "remediation requires <trigger>"
  [ -f "${WF_DIR}/${uuid}.json" ] || fail "no artifact for $uuid"

  local score="" open="" findings=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --score)
        [ $# -ge 2 ] || fail "remediation: --score requires a value"
        score="$2"; shift 2 ;;
      --open)
        [ $# -ge 2 ] || fail "remediation: --open requires a value"
        open="$2"; shift 2 ;;
      --findings)
        [ $# -ge 2 ] && [ -n "${2:-}" ] || fail "remediation: --findings requires a file"
        findings="$2"; shift 2 ;;
      *) fail "unknown flag: $1" ;;
    esac
  done
  case "$score" in ''|*[!0-9]*) [ -z "$score" ] || fail "remediation: --score must be a non-negative integer" ;; esac
  case "$open" in ''|*[!0-9]*) [ -z "$open" ] || fail "remediation: --open must be a non-negative integer" ;; esac
  # --findings derives N itself; a second, hand-typed N could only disagree with it.
  if [ -n "$open" ] && [ -n "$findings" ]; then
    fail "remediation: --open and --findings are mutually exclusive (--findings computes the open count)"
  fi

  local max_iters="${MTK_MAX_REMEDIATION_ITERS:-3}"
  case "$max_iters" in ''|*[!0-9]*) fail "MTK_MAX_REMEDIATION_ITERS must be a positive integer" ;; esac

  # Record the attempt; decide ESCALATE when iterations hit the cap, the score
  # stopped improving (plateau), or the open-finding count stopped falling
  # (stalled). Two separate series: scores are higher-is-better, opens are
  # lower-is-better, so a non-increasing score or a non-decreasing open count
  # means automated remediation is no longer converging.
  local verdict rc=0
  verdict="$(python3 - "${WF_DIR}/${uuid}.json" "$(iso_now)" "$trigger" "$score" "$max_iters" "$open" "$findings" <<'PY'
import sys; sys.stdout.reconfigure(newline="\n")  # LF even on Windows python3: bash parses this output
import hashlib, json
path, now, trigger, score, max_iters, open_n, findings_path = sys.argv[1:8]
max_iters = int(max_iters)

# Finding UID = F- + sha1(file|rule|normalised snippet)[:10]. The line number is
# deliberately left out, so a finding keeps its UID when unrelated edits move it.
# Snippet: the first non-empty of snippet/evidence/code (linters and analyzers
# emit these); review-finding-schema.md has no snippet field, so AI findings fall
# back to rationale (then description/title/message).
SNIPPET_FIELDS = ("snippet", "evidence", "code", "rationale", "description", "title", "message")
def finding_uid(f):
    snippet = next((f[k] for k in SNIPPET_FIELDS if isinstance(f.get(k), str) and f[k].strip()), "")
    key = "%s|%s|%s" % (str(f.get("file") or "").strip(), str(f.get("rule") or "").strip(),
                        " ".join(snippet.split()))
    return "F-" + hashlib.sha1(key.encode("utf-8")).hexdigest()[:10]

current = None
if findings_path:
    try:
        with open(findings_path, encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError) as e:
        print(f"workflow-artifact: remediation: cannot read --findings {findings_path}: {e}", file=sys.stderr)
        sys.exit(2)
    items = raw.get("findings") if isinstance(raw, dict) else raw
    if not isinstance(items, list) or not all(isinstance(i, dict) for i in items):
        print(f"workflow-artifact: remediation: --findings {findings_path} is not a JSON array of finding "
              "objects or an object with findings[]", file=sys.stderr)
        sys.exit(2)
    current = []
    for f in items:
        u = finding_uid(f)
        if u not in current:  # duplicates (same file/rule/snippet) are one open finding
            current.append(u)

with open(path) as f: doc = json.load(f)
results = doc.setdefault("results", {})
rem = results.setdefault("remediation", {})
entry = rem.setdefault(trigger, {"iterations": 0, "scores": [], "plateau": False})
entry["iterations"] = int(entry.get("iterations", 0)) + 1
if score != "":
    # Bash guard (case "$score" in ''|*[!0-9]*) already guarantees an integer here.
    entry.setdefault("scores", []).append(int(score))
scores = [s for s in entry.get("scores", []) if isinstance(s, int)]
plateau = len(scores) >= 2 and scores[-1] <= scores[-2]
entry["plateau"] = plateau

reconcile = None
if current is not None:
    prev = entry.get("findings", {}).get("open", []) if isinstance(entry.get("findings"), dict) else []
    prev = prev if isinstance(prev, list) else []
    reconcile = {
        "FIXED": [u for u in prev if u not in current],
        "STILL_OPEN": [u for u in current if u in prev],
        "NEW": [u for u in current if u not in prev],
    }
    entry["findings"] = {"open": current, "last": reconcile}
    open_n = str(len(current))
if open_n != "":
    entry.setdefault("opens", []).append(int(open_n))
stalled = False
if "opens" in entry:
    # Only a trigger that ever reported an open count carries the stall flag, so
    # score-only artifacts keep their exact old shape.
    opens = [o for o in entry["opens"] if isinstance(o, int)]
    stalled = len(opens) >= 2 and opens[-1] >= opens[-2]
    entry["stalled"] = stalled

escalate = entry["iterations"] >= max_iters or plateau or stalled
doc["updated_at"] = now
with open(path, "w") as f: json.dump(doc, f, indent=2)
print("ESCALATE" if escalate else "CONTINUE")
print(entry["iterations"])
print("plateau" if plateau else "no-plateau")
print("stalled" if stalled else "no-stalled")
# Lines 5+ are passed through after the verdict line.
if stalled:
    print("reason: stalled")
if reconcile is not None:
    for k in ("FIXED", "STILL_OPEN", "NEW"):
        print(" ".join([k, str(len(reconcile[k]))] + reconcile[k]))
PY
)" || rc=$?
  # 2 = unreadable --findings (nothing was written); anything else is a crash.
  [ "$rc" -ne 2 ] || exit 2
  [ "$rc" -eq 0 ] || fail "remediation: tracker update failed (python exit $rc)"
  local decision iters plat stall extra
  decision="$(printf '%s\n' "$verdict" | sed -n '1p')"
  iters="$(printf '%s\n' "$verdict" | sed -n '2p')"
  plat="$(printf '%s\n' "$verdict" | sed -n '3p')"
  stall="$(printf '%s\n' "$verdict" | sed -n '4p')"
  extra="$(printf '%s\n' "$verdict" | sed -n '5,$p')"

  if [ "$decision" = "ESCALATE" ]; then
    local trigger_json reason="cap" stalled_json="false"
    trigger_json="$(printf '%s' "$trigger" | json_escape)"
    [ "$plat" != "plateau" ] || reason="plateau"
    if [ "$stall" = "stalled" ]; then reason="stalled"; stalled_json="true"; fi
    cmd_event "$uuid" "remediation_escalated" --data "{\"trigger\":${trigger_json},\"iterations\":${iters},\"plateau\":\"${plat}\",\"stalled\":${stalled_json},\"reason\":\"${reason}\"}" >/dev/null
  fi
  printf '%s\n' "$decision"
  [ -z "$extra" ] || printf '%s\n' "$extra"
}

# review-input — bind a review to the tree it read. --record stores the
# working-tree fingerprint at lane dispatch; --check (before aggregating the
# lanes) recomputes it against the RECORDED base commit, so committing exactly
# the reviewed tree still reads as unchanged while any edit, deletion or new
# untracked file does not. The fingerprint is hook-io's mtk_tree_fingerprint —
# the same one the Stop hook binds evidence with — sourced lazily so no other
# subcommand depends on hooks/lib being present. Exit: 0 unchanged, 1 changed,
# 2 nothing recorded / hook-io absent / fingerprint not computable.
load_hook_io() {
  local self_dir d
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for d in "$self_dir/../hooks/lib" "${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/hooks/lib}"; do
    [ -n "$d" ] && [ -f "$d/hook-io.sh" ] || continue
    # shellcheck source=../hooks/lib/hook-io.sh
    . "$d/hook-io.sh"
    declare -F mtk_tree_fingerprint >/dev/null && return 0
  done
  return 1
}

# Fingerprint as seen from ROOT_DIR: hook-io resolves the root from
# CLAUDE_PROJECT_DIR before git, so pin it to ours and drop any memoized root.
review_fingerprint() {
  _MTK_REPO_ROOT=""
  CLAUDE_PROJECT_DIR="$ROOT_DIR" mtk_tree_fingerprint "$@"
}

cmd_review_input() {
  local uuid="${1:-}" mode="${2:-}"
  [ -n "$uuid" ] || fail "review-input requires <uuid>"
  [ -f "${WF_DIR}/${uuid}.json" ] || fail "no artifact for $uuid"
  case "$mode" in --record|--check) ;; *) fail "review-input requires --record or --check" ;; esac
  [ $# -le 2 ] || fail "review-input: unexpected argument: $3"

  if ! load_hook_io; then
    printf 'workflow-artifact: review-input: hooks/lib/hook-io.sh not found (looked beside this script and under CLAUDE_PLUGIN_ROOT) — cannot fingerprint the tree\n' >&2
    return 2
  fi

  local fp="" rc=0
  if [ "$mode" = "--record" ]; then
    fp="$(review_fingerprint)" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$fp" ]; then
      printf 'workflow-artifact: review-input: cannot fingerprint %s (not a git work tree, or a file is unreadable)\n' "$ROOT_DIR" >&2
      return 2
    fi
    python3 - "${WF_DIR}/${uuid}.json" "$(iso_now)" "$fp" <<'PY'
import json, sys
path, now, fp = sys.argv[1:4]
with open(path) as f: doc = json.load(f)
review = doc.setdefault("results", {}).setdefault("review", {})
review["input_fingerprint"] = fp
review["recorded_at"] = now
doc["updated_at"] = now
with open(path, "w") as f: json.dump(doc, f, indent=2)
PY
    cmd_event "$uuid" "review_input_recorded" --data "{\"input_fingerprint\":$(printf '%s' "$fp" | json_escape)}" >/dev/null
    printf 'review-input: recorded %s\n' "$fp"
    return 0
  fi

  local recorded
  recorded="$(python3 - "${WF_DIR}/${uuid}.json" <<'PY'
import sys; sys.stdout.reconfigure(newline="\n")  # LF even on Windows python3: bash parses this output
import json
review = json.load(open(sys.argv[1])).get("results", {}).get("review", {})
fp = review.get("input_fingerprint") if isinstance(review, dict) else None
print(fp if isinstance(fp, str) else "")
PY
)"
  if [ -z "$recorded" ]; then
    printf 'workflow-artifact: review-input: no input fingerprint recorded for %s (run --record at lane dispatch)\n' "$uuid" >&2
    return 2
  fi
  fp="$(review_fingerprint "${recorded%% *}")" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$fp" ]; then
    printf 'workflow-artifact: review-input: cannot fingerprint %s (not a git work tree, or a file is unreadable)\n' "$ROOT_DIR" >&2
    return 2
  fi
  if [ "$fp" = "$recorded" ]; then
    printf 'review-input: unchanged (%s)\n' "$fp"
    return 0
  fi
  printf 'review-input: CHANGED — the tree differs from the one the review read\n'
  printf '  recorded=%s\n' "$recorded"
  printf '  current=%s\n' "$fp"
  return 1
}

# Approval seal — bind the approved SCOPE artifacts (spec + plan) to a
# combined SHA-256 recorded on the workflow at Phase 2.5 approval time. The
# todo file is deliberately NOT sealed: it is progress state designed to mutate
# as batches complete, so sealing it would flip the seal STALE on the first
# checkbox tick — a false tamper signal. Scope lives in spec + plan; progress
# lives in todo. The
# hash is derived from disk by this script, so the seal cannot be forged for a
# different body. `verify-seal` re-derives and compares (hashgate: "approve a
# state, not an intention").
cmd_seal() {
  local uuid="${1:-}"
  shift || true
  [ -n "$uuid" ] || fail "seal requires <uuid>"
  [ -f "${WF_DIR}/${uuid}.json" ] || fail "no artifact for $uuid"

  # With no explicit paths, derive the sealed set from the artifact's own
  # recorded canonical scope paths (results.spec_path/plan_path) so the seal
  # binds what the workflow actually approved rather than a re-typed list.
  # todo_path is intentionally excluded — it is mutable progress state, not
  # scope (see the cmd_seal header comment above).
  if [ $# -eq 0 ]; then
    local derived
    derived="$(python3 - "${WF_DIR}/${uuid}.json" <<'PY'
import sys; sys.stdout.reconfigure(newline="\n")  # LF even on Windows python3: bash parses this output
import json, sys
r = json.load(open(sys.argv[1])).get("results", {})
for k in ("spec_path", "plan_path"):
    v = r.get(k)
    if v:
        print(v)
PY
)"
    if [ -n "$derived" ]; then
      # Split with `read`, never `set -- $derived`: an unquoted expansion also
      # pathname-expands (issue #99's class), and a stray CR from a Windows
      # python3 (issue #96) must not survive into the path.
      local _p; local -a _paths=()
      while IFS= read -r _p || [ -n "$_p" ]; do
        _p="${_p%$'\r'}"
        [ -n "$_p" ] && _paths+=("$_p")
      done <<< "$derived"
      set -- "${_paths[@]}"
    fi
  fi
  [ $# -gt 0 ] || fail "seal requires <path>... or recorded results.spec_path/plan_path on the artifact"

  local hash
  hash="$(python3 - "${WF_DIR}/${uuid}.json" "$ROOT_DIR" "$(iso_now)" "$@" <<'PY'
import sys; sys.stdout.reconfigure(newline="\n")  # LF even on Windows python3: bash parses this output
import json, sys, os, hashlib
artifact, root, now = sys.argv[1], sys.argv[2], sys.argv[3]
paths = sorted(set(sys.argv[4:]))
combined = hashlib.sha256()
files = []
for p in paths:
    fp = os.path.join(root, p)
    if not os.path.isfile(fp):
        print(f"workflow-artifact: seal target not found: {p}", file=sys.stderr)
        sys.exit(1)
    with open(fp, "rb") as fh:
        body = fh.read()
    files.append({"path": p, "sha256": hashlib.sha256(body).hexdigest()})
    combined.update(p.encode("utf-8")); combined.update(b"\0")
    combined.update(body); combined.update(b"\0")
digest = combined.hexdigest()
with open(artifact) as f:
    doc = json.load(f)
seal = {"hash": digest, "algo": "sha256", "files": files, "sealed_at": now}
# Criteria seal: target repos gitignore docs/specs/* (only baseline/ is tracked),
# so there is no committed sidecar to diff. Hash just the frozen
# success_criteria fields of the sidecar (id, observable, evidence_channel); the rest of the
# sidecar (the change manifest, amended in Phase 3.5) stays free to change.
def criteria_digest(body):
    crit = json.loads(body).get("success_criteria")
    if not isinstance(crit, list):
        return None, 0
    frozen = sorted(
        ({k: c.get(k) for k in ("id", "observable", "evidence_channel")} for c in crit if isinstance(c, dict)),
        key=lambda c: str(c.get("id")))
    canon = json.dumps(frozen, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canon.encode("utf-8")).hexdigest(), len(frozen)
spec_candidates = [doc.get("results", {}).get("spec_path")] + [p for p in paths if p.endswith(".md")]
for sp in spec_candidates:
    if not sp or not sp.endswith(".md"):
        continue
    sidecar = sp[:-3] + ".json"
    sfp = os.path.join(root, sidecar)
    if not os.path.isfile(sfp):
        continue
    try:
        with open(sfp, "rb") as fh:
            cdig, count = criteria_digest(fh.read())
    except (ValueError, OSError):
        continue
    if cdig:
        seal["criteria"] = {"path": sidecar, "sha256": cdig, "count": count}
        break
doc.setdefault("results", {})["approval_seal"] = seal
doc["updated_at"] = now
with open(artifact, "w") as f:
    json.dump(doc, f, indent=2)
print(digest)
PY
)"
  cmd_event "$uuid" "approval_sealed" --data "{\"hash\":\"${hash}\",\"file_count\":$#}" >/dev/null
  printf '%s\n' "$hash"
}

cmd_verify_seal() {
  local uuid="${1:-}"
  [ -n "$uuid" ] || fail "verify-seal requires <uuid>"
  [ -f "${WF_DIR}/${uuid}.json" ] || fail "no artifact for $uuid"

  # exit 0 = match, 1 = stale, 2 = uncheckable (unexpected error — corrupt/
  # malformed artifact), 3 = no seal recorded. Guarded so set -e does not abort
  # before we can propagate the code to callers (hook / verify-completion). The
  # distinct code 2 stops a crash from masquerading as STALE (python's default
  # exit-1-on-unhandled-exception would otherwise look like a real mismatch).
  local rc=0
  python3 - "${WF_DIR}/${uuid}.json" "$ROOT_DIR" <<'PY' || rc=$?
import json, sys, os, hashlib, traceback
def run():
    artifact, root = sys.argv[1], sys.argv[2]
    with open(artifact) as f:
        doc = json.load(f)
    seal = doc.get("results", {}).get("approval_seal")
    if not seal:
        print("verify-seal: no approval seal recorded", file=sys.stderr)
        sys.exit(3)
    combined = hashlib.sha256()
    changed = []
    for entry in sorted(seal.get("files", []), key=lambda e: e.get("path", "")):
        p = entry.get("path")
        if not p:
            continue
        old = entry.get("sha256", "")
        fp = os.path.join(root, p)
        if not os.path.isfile(fp):
            changed.append(p + " (missing)")
            combined.update(p.encode("utf-8")); combined.update(b"\0"); combined.update(b"\0")
            continue
        with open(fp, "rb") as fh:
            body = fh.read()
        if hashlib.sha256(body).hexdigest() != old:
            changed.append(p)
        combined.update(p.encode("utf-8")); combined.update(b"\0")
        combined.update(body); combined.update(b"\0")
    current = combined.hexdigest()
    sealed = seal.get("hash", "")
    crit = seal.get("criteria")
    crit_note = ""
    if crit:
        cp = crit.get("path", "")
        cfp = os.path.join(root, cp)
        if not os.path.isfile(cfp):
            changed.append("success_criteria (%s missing)" % cp)
        else:
            with open(cfp) as fh:
                items = json.load(fh).get("success_criteria")
            frozen = sorted(
                ({k: c.get(k) for k in ("id", "observable", "evidence_channel")} for c in (items or []) if isinstance(c, dict)),
                key=lambda c: str(c.get("id")))
            canon = json.dumps(frozen, sort_keys=True, separators=(",", ":"))
            if hashlib.sha256(canon.encode("utf-8")).hexdigest() != crit.get("sha256"):
                changed.append("success_criteria (%s)" % cp)
            else:
                crit_note = ", %d frozen criteria intact" % len(frozen)
    else:
        crit_note = ", success_criteria not sealed"
    if current == sealed and not changed:
        print("verify-seal: OK (%d file(s) match seal%s)" % (len(seal.get("files", [])), crit_note))
        sys.exit(0)
    print("verify-seal: STALE — approval no longer matches the approved bytes")
    print("  sealed=%s" % sealed)
    print("  current=%s" % current)
    print("  changed=%s" % (", ".join(changed) if changed else "(combined mismatch)"))
    sys.exit(1)
try:
    run()
except SystemExit:
    raise
except Exception:
    traceback.print_exc()
    print("verify-seal: uncheckable — unexpected error reading the seal/artifact", file=sys.stderr)
    sys.exit(2)
PY
  return $rc
}

# Trap list — a written, specific gotcha a phase learned the hard way (a stale
# generated contract, an analyzer that fires only under `format`, a fixture that
# silently seeds the wrong state), carried into every later phase and implementer
# brief. A 2026-09 six-phase field run found this hand-carried list was the one
# mechanism that demonstrably worked (the final phase had zero repair cycles) —
# and that it survived only because whoever drove remembered to paste it. Persisted
# on the artifact it survives compaction, crash, and handoff. Orchestrator-owned:
# implementers REPORT candidate traps in their result; the orchestrator records them.
cmd_trap() {
  local action="${1:-}"
  shift || true
  case "$action" in
    add)  cmd_trap_add "$@" ;;
    list) cmd_trap_list "$@" ;;
    *)    fail "trap requires <add|list>" ;;
  esac
}

cmd_trap_add() {
  local uuid="${1:-}"
  shift || true
  [ -n "$uuid" ] || fail "trap add requires <uuid>"
  [ -f "${WF_DIR}/${uuid}.json" ] || fail "no artifact for $uuid"

  local title="" body="" phase="" severity="warn"
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)    title="${2:-}"; shift 2 ;;
      --body)     body="${2:-}"; shift 2 ;;
      --phase)    phase="${2:-}"; shift 2 ;;
      --severity) severity="${2:-}"; shift 2 ;;
      *) fail "unknown flag: $1" ;;
    esac
  done
  [ -n "$title" ] || fail "trap add requires --title"
  case "$severity" in warn|high) ;; *) fail "trap severity must be 'warn' or 'high'" ;; esac

  local tid
  tid="$(python3 - "${WF_DIR}/${uuid}.json" "$(iso_now)" "$title" "$body" "$phase" "$severity" <<'PY'
import sys; sys.stdout.reconfigure(newline="\n")  # LF even on Windows python3: bash parses this output
import json, sys
path, now, title, body, phase, severity = sys.argv[1:7]
with open(path) as f: doc = json.load(f)
traps = doc.setdefault("results", {}).setdefault("trap_list", [])
# Idempotent by title: a re-run of the same phase refreshes the entry, it does not stack.
existing = next((t for t in traps if t.get("title") == title), None)
if existing:
    existing.update({"body": body, "phase": phase, "severity": severity, "added_at": now})
    tid = existing["id"]
else:
    tid = "trap-%03d" % (len(traps) + 1)
    traps.append({"id": tid, "title": title, "body": body, "phase": phase,
                  "severity": severity, "added_at": now})
doc["updated_at"] = now
with open(path, "w") as f: json.dump(doc, f, indent=2)
print(tid)
PY
)"
  local title_json
  title_json="$(printf '%s' "$title" | json_escape)"
  cmd_event "$uuid" "trap_added" --data "{\"id\":\"${tid}\",\"title\":${title_json},\"severity\":\"${severity}\"}" >/dev/null
  printf '%s\n' "$tid"
}

cmd_trap_list() {
  local uuid="${1:-}"
  [ -n "$uuid" ] || fail "trap list requires <uuid>"
  [ -f "${WF_DIR}/${uuid}.json" ] || fail "no artifact for $uuid"
  python3 - "${WF_DIR}/${uuid}.json" <<'PY'
import json, sys
traps = json.load(open(sys.argv[1])).get("results", {}).get("trap_list", [])
if not traps:
    print("(no traps recorded)"); sys.exit(0)
for t in traps:
    line = "- [%s] %s" % (t.get("severity", "warn").upper(), t.get("title", ""))
    if t.get("phase"):
        line += " (from %s)" % t["phase"]
    print(line)
    if t.get("body"):
        print("  " + t["body"])
PY
}

# prune — workflow expiry. Without it .mtk/workflows/ keeps one JSON + one
# event log per run forever, and `list` / compaction recovery wade through
# every finished run. A workflow is prunable only when its updated_at (file
# mtime if absent) is older than <days> — whatever its status. Finished runs are
# not deleted on sight: implement runs prune before every init, and a run that
# finished an hour ago is still the receipt the engineer reviews. <days> must be
# at least 1; `--older-than 0` (delete everything) needs --force. Each pruned
# uuid is also printed to stderr, so a caller that discards stdout still leaves
# a trace. Only files whose workflow_uuid matches their own name are
# considered, so unrelated files under .mtk/workflows/ (e.g. dashboard/) survive.
cmd_prune() {
  local days="" dry=0 force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --older-than) days="${2:-}"; [ $# -ge 2 ] && shift 2 || shift ;;
      --dry-run) dry=1; shift ;;
      --force) force=1; shift ;;
      *) fail "unknown flag: $1" ;;
    esac
  done
  case "$days" in ''|*[!0-9]*) fail "prune requires --older-than <days> (a whole number of days, at least 1)" ;; esac
  if [ "$days" -lt 1 ] && [ "$force" -ne 1 ]; then
    fail "prune --older-than $days would delete every workflow; use at least 1, or add --force"
  fi
  if [ ! -d "$WF_DIR" ]; then
    printf 'workflow-artifact: pruned 0 workflow(s) (no %s)\n' "$WF_DIR"
    return 0
  fi

  python3 - "$WF_DIR" "$days" "$dry" <<'PY'
import sys; sys.stdout.reconfigure(newline="\n")  # LF even on Windows python3
import datetime, glob, json, os, shutil
wf_dir, days, dry = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1"
now = datetime.datetime.now(datetime.timezone.utc)
cutoff = now - datetime.timedelta(days=days)
pruned = 0
for path in sorted(glob.glob(os.path.join(wf_dir, "*.json"))):
    stem = os.path.basename(path)[:-5]
    try:
        with open(path) as f:
            d = json.load(f)
    except (OSError, ValueError) as e:
        print(f"workflow-artifact: prune: skipping unreadable {os.path.basename(path)}: {e}", file=sys.stderr)
        continue
    if not isinstance(d, dict) or d.get("workflow_uuid") != stem:
        continue
    status = d.get("status", "")
    try:
        updated = datetime.datetime.strptime(d.get("updated_at", ""), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except (TypeError, ValueError):
        updated = datetime.datetime.fromtimestamp(os.path.getmtime(path), datetime.timezone.utc)
    if updated >= cutoff:
        continue
    why = f"{status or 'unknown'}, not updated for {(now - updated).days} day(s)"
    print(f"{'would prune' if dry else 'pruned'} {stem} ({why})")
    print(f"workflow-artifact: {'would prune' if dry else 'pruned'} {stem} ({why})", file=sys.stderr)
    pruned += 1
    if dry:
        continue
    for extra in (path, os.path.join(wf_dir, stem + ".events.jsonl"), os.path.join(wf_dir, stem + ".artifact.md")):
        if os.path.isfile(extra):
            os.remove(extra)
    if os.path.isdir(os.path.join(wf_dir, stem)):
        shutil.rmtree(os.path.join(wf_dir, stem))
print(f"workflow-artifact: {'would prune' if dry else 'pruned'} {pruned} workflow(s)")
PY
}

usage() {
  # Sentinel range, not fixed line numbers: print from line 4 to the first
  # blank line, so adding header lines never truncates --help again.
  sed -n '4,/^$/p' "$0"
}

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    init)     cmd_init "$@" ;;
    event)    cmd_event "$@" ;;
    set)      cmd_set "$@" ;;
    read)     cmd_read "$@" ;;
    list)     cmd_list ;;
    batch)    cmd_batch "$@" ;;
    gate)     cmd_gate "$@" ;;
    seal)     cmd_seal "$@" ;;
    verify-seal) cmd_verify_seal "$@" ;;
    criteria) cmd_criteria "$@" ;;
    remediation) cmd_remediation "$@" ;;
    review-input) cmd_review_input "$@" ;;
    trap)     cmd_trap "$@" ;;
    abandon)  cmd_abandon "$@" ;;
    prune)    cmd_prune "$@" ;;
    ""|-h|--help) usage ;;
    *) fail "unknown subcommand: $sub" ;;
  esac
}

main "$@"
