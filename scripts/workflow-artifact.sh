#!/usr/bin/env bash

set -euo pipefail

# workflow-artifact.sh — manage durable workflow state under .mtk/workflows/
#
# Subcommands:
#   init <type> [--goal "<text>"]    Create a new workflow artifact, print UUID
#   event <uuid> <type> [--data '<json>']  Append event to .events.jsonl
#   set <uuid> <key=value>...        Update top-level fields in {uuid}.json
#   read <uuid>                      Print {uuid}.json to stdout
#   list                             List active workflows (id, type, status, updated)
#   gate <uuid> <gate_name> <pass|fail> [--reason "<text>"]
#                                    Record gate decision as event + status update
#   criteria <uuid> <SCn=status>...  Set per-criterion verification status
#                                    Status values: pending | verified | re-armed
#                                    --rearm-all  Reset all verified → re-armed
#   remediation <uuid> <trigger> [--score N]  Record a remediation attempt; prints
#                                    ESCALATE when iterations >= MTK_MAX_REMEDIATION_ITERS
#                                    (default 3) or the score plateaus, else CONTINUE
#   seal <uuid> <path>...            Record a SHA-256 approval seal over the given
#                                    artifact bodies (spec/plan/todo) at approval time
#   verify-seal <uuid>               Re-check the recorded seal; exit 0 match,
#                                    1 stale (prints sealed=/current=), 2 uncheckable
#                                    (unexpected error), 3 no seal
#   abandon <uuid> [--reason "<text>"]  Mark workflow abandoned
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
    "memory_sync_gate": "pending",
    "skill_precedence_gate": "pending"
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
  while [ $# -gt 0 ]; do
    case "$1" in
      --data) data="${2-}"; [ -n "$data" ] || data="{}"; shift 2 ;;
      *) fail "unknown flag: $1" ;;
    esac
  done

  local now
  now="$(iso_now)"
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
  printf '%-44s %-7s %-10s %s\n' "UUID" "TYPE" "STATUS" "UPDATED"
  for f in "${WF_DIR}"/*.json; do
    python3 - "$f" <<'PY'
import json, sys
with open(sys.argv[1]) as f: d = json.load(f)
print(f"{d.get('workflow_uuid',''):<44} {d.get('workflow_type',''):<7} {d.get('status',''):<10} {d.get('updated_at','')}")
PY
  done
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
  case "$gate" in
    plan_trust_gate|phase_exit_gate|failure_stop_gate|memory_sync_gate|skill_precedence_gate) ;;
    *) fail "unknown gate: $gate (see .claude/references/orchestration-gates.md)" ;;
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

  local score=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --score)
        [ $# -ge 2 ] || fail "remediation: --score requires a value"
        score="$2"; shift 2 ;;
      *) fail "unknown flag: $1" ;;
    esac
  done
  case "$score" in ''|*[!0-9]*) [ -z "$score" ] || fail "remediation: --score must be a non-negative integer" ;; esac

  local max_iters="${MTK_MAX_REMEDIATION_ITERS:-3}"
  case "$max_iters" in ''|*[!0-9]*) fail "MTK_MAX_REMEDIATION_ITERS must be a positive integer" ;; esac

  # Record the attempt; decide ESCALATE when iterations hit the cap OR the score
  # stopped improving (plateau). Higher score = better, so a non-increasing latest
  # score means automated remediation is no longer converging.
  local verdict
  verdict="$(python3 - "${WF_DIR}/${uuid}.json" "$(iso_now)" "$trigger" "$score" "$max_iters" <<'PY'
import json, sys
path, now, trigger, score, max_iters = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
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
escalate = entry["iterations"] >= max_iters or plateau
doc["updated_at"] = now
with open(path, "w") as f: json.dump(doc, f, indent=2)
print("ESCALATE" if escalate else "CONTINUE")
print(entry["iterations"])
print("plateau" if plateau else "no-plateau")
PY
)"
  local decision iters plat
  decision="$(printf '%s\n' "$verdict" | sed -n '1p')"
  iters="$(printf '%s\n' "$verdict" | sed -n '2p')"
  plat="$(printf '%s\n' "$verdict" | sed -n '3p')"

  if [ "$decision" = "ESCALATE" ]; then
    local trigger_json
    trigger_json="$(printf '%s' "$trigger" | json_escape)"
    cmd_event "$uuid" "remediation_escalated" --data "{\"trigger\":${trigger_json},\"iterations\":${iters},\"plateau\":\"${plat}\"}" >/dev/null
  fi
  printf '%s\n' "$decision"
}

# Approval seal — bind the approved artifact bodies (spec/plan/todo) to a
# combined SHA-256 recorded on the workflow at Phase 2.5 approval time. The
# hash is derived from disk by this script, so the seal cannot be forged for a
# different body. `verify-seal` re-derives and compares (hashgate: "approve a
# state, not an intention").
cmd_seal() {
  local uuid="${1:-}"
  shift || true
  [ -n "$uuid" ] || fail "seal requires <uuid>"
  [ -f "${WF_DIR}/${uuid}.json" ] || fail "no artifact for $uuid"

  # With no explicit paths, derive the sealed set from the artifact's own
  # recorded canonical paths (results.spec_path/plan_path/todo_path) so the seal
  # binds what the workflow actually approved rather than a re-typed list.
  if [ $# -eq 0 ]; then
    local derived
    derived="$(python3 - "${WF_DIR}/${uuid}.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])).get("results", {})
for k in ("spec_path", "plan_path", "todo_path"):
    v = r.get(k)
    if v:
        print(v)
PY
)"
    if [ -n "$derived" ]; then
      local _oldifs="$IFS"; IFS='
'; set -- $derived; IFS="$_oldifs"
    fi
  fi
  [ $# -gt 0 ] || fail "seal requires <path>... or recorded results.spec_path/plan_path/todo_path on the artifact"

  local hash
  hash="$(python3 - "${WF_DIR}/${uuid}.json" "$ROOT_DIR" "$(iso_now)" "$@" <<'PY'
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
doc.setdefault("results", {})["approval_seal"] = {
    "hash": digest, "algo": "sha256", "files": files, "sealed_at": now
}
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
    if current == sealed and not changed:
        print("verify-seal: OK (%d file(s) match seal)" % len(seal.get("files", [])))
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

usage() {
  sed -n '4,26p' "$0"
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
    gate)     cmd_gate "$@" ;;
    seal)     cmd_seal "$@" ;;
    verify-seal) cmd_verify_seal "$@" ;;
    criteria) cmd_criteria "$@" ;;
    remediation) cmd_remediation "$@" ;;
    abandon)  cmd_abandon "$@" ;;
    ""|-h|--help) usage ;;
    *) fail "unknown subcommand: $sub" ;;
  esac
}

main "$@"
