#!/usr/bin/env bash

set -euo pipefail

# workflow-dashboard.sh — render a read-only HTML dashboard from .mtk/workflows/
#
# Reads the durable workflow artifacts written by scripts/workflow-artifact.sh
# ({uuid}.json + {uuid}.events.jsonl) and renders a single self-contained HTML
# page: per-workflow status, phase, gate decisions, results, and an event
# timeline. No server framework, no build step, no runtime dependencies beyond
# python3 (already required by workflow-artifact.sh) and — for --watch — the
# stdlib http.server.
#
# Usage:
#   workflow-dashboard.sh                 Render once -> .mtk/workflows/dashboard/index.html, open it
#   workflow-dashboard.sh --watch [secs]  Regenerate every <secs> (default 5) and serve over HTTP
#   workflow-dashboard.sh --out <path>    Write the HTML to a custom path
#   workflow-dashboard.sh --port <n>      Server port for --watch (default 8787)
#   workflow-dashboard.sh --no-open       Don't try to open a browser
#
# Sharing with non-CLI stakeholders: run with --watch, then expose the served
# port with the ngrok-expose or cfd (Cloudflare Tunnel) skill. This script does
# not embed a tunnel — it stays a self-contained static renderer.

ROOT_DIR="$(pwd)"
WF_DIR="${ROOT_DIR}/.mtk/workflows"
OUT_DIR_DEFAULT="${WF_DIR}/dashboard"

WATCH=0
INTERVAL=5
PORT=8787
OPEN=1
OUT=""

fail() { printf 'workflow-dashboard: %s\n' "$1" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --watch)   WATCH=1; if [ "${2:-}" ] && printf '%s' "${2:-}" | grep -qE '^[0-9]+$'; then INTERVAL="$2"; shift; fi; shift ;;
    --port)    PORT="${2:-}"; [ -n "$PORT" ] || fail "--port requires a number"; shift 2 ;;
    --out)     OUT="${2:-}"; [ -n "$OUT" ] || fail "--out requires a path"; shift 2 ;;
    --no-open) OPEN=0; shift ;;
    -h|--help) sed -n '5,30p' "$0"; exit 0 ;;
    *) fail "unknown flag: $1" ;;
  esac
done

command -v python3 >/dev/null 2>&1 || fail "python3 is required (same dependency as workflow-artifact.sh)"

# Resolve output path. In --watch mode we always serve a directory, so the file
# must be index.html inside a served dir.
if [ -n "$OUT" ]; then
  OUT_FILE="$OUT"
else
  OUT_FILE="${OUT_DIR_DEFAULT}/index.html"
fi
OUT_PARENT="$(dirname "$OUT_FILE")"

render() {
  mkdir -p "$OUT_PARENT"
  REFRESH_SECS="$1" python3 - "$WF_DIR" "$OUT_FILE" <<'PY'
import html, json, os, sys

wf_dir, out_file = sys.argv[1], sys.argv[2]
refresh = os.environ.get("REFRESH_SECS", "0")

def esc(v):
    return html.escape(str(v), quote=True)

workflows = []
if os.path.isdir(wf_dir):
    for name in sorted(os.listdir(wf_dir)):
        if not name.endswith(".json") or name == "dashboard":
            continue
        path = os.path.join(wf_dir, name)
        try:
            with open(path) as f:
                doc = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        events = []
        ev_path = path[:-5] + ".events.jsonl"
        if os.path.isfile(ev_path):
            with open(ev_path) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        events.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
        workflows.append((doc, events))

# Most-recently-updated first.
workflows.sort(key=lambda we: we[0].get("updated_at", ""), reverse=True)

STATUS_COLOR = {"active": "#2563eb", "complete": "#16a34a", "completed": "#16a34a",
                "failed": "#dc2626", "halted": "#d97706", "archived": "#6b7280"}
GATE_COLOR = {"pass": "#16a34a", "fail": "#dc2626", "pending": "#9ca3af"}

def gate_chip(name, val):
    c = GATE_COLOR.get(val, "#9ca3af")
    label = name.replace("_gate", "").replace("_", " ")
    return f'<span class="gate" style="border-color:{c};color:{c}">{esc(label)}: {esc(val)}</span>'

def card(doc, events):
    uuid = doc.get("workflow_uuid", "?")
    status = doc.get("status", "?")
    sc = STATUS_COLOR.get(status, "#6b7280")
    wtype = doc.get("workflow_type", "?")
    phase = doc.get("phase_cursor", "?")
    goal = (doc.get("intent") or {}).get("goal", "") or "(no goal recorded)"
    updated = doc.get("updated_at", "")
    created = doc.get("created_at", "")
    gates = doc.get("gates") or {}
    results = doc.get("results") or {}

    gate_html = "".join(gate_chip(k, v) for k, v in gates.items()) or '<span class="muted">no gates</span>'

    if results:
        res_rows = "".join(
            f'<tr><td>{esc(k)}</td><td>{esc(json.dumps(v) if isinstance(v,(dict,list)) else v)}</td></tr>'
            for k, v in results.items())
        res_html = f'<table class="kv">{res_rows}</table>'
    else:
        res_html = '<span class="muted">no results yet</span>'

    # Timeline — newest last, capped at 40 most recent.
    ev_items = []
    for ev in events[-40:]:
        ts = ev.get("ts", "")
        etype = ev.get("event", "")
        data = ev.get("data") or {}
        detail = ""
        if data:
            if etype == "gate_decided":
                detail = f'{data.get("gate","")} → {data.get("result","")}'
                if data.get("reason"):
                    detail += f' ({data["reason"]})'
            else:
                detail = json.dumps(data, separators=(",", ":"))
        ev_items.append(
            f'<li><span class="ts">{esc(ts)}</span> '
            f'<span class="etype">{esc(etype)}</span> '
            f'<span class="muted">{esc(detail)}</span></li>')
    timeline = f'<ul class="timeline">{"".join(ev_items)}</ul>' if ev_items else '<span class="muted">no events</span>'

    return f'''<section class="wf">
  <header>
    <span class="badge" style="background:{sc}">{esc(status)}</span>
    <span class="type">{esc(wtype)}</span>
    <code class="uuid">{esc(uuid)}</code>
    <span class="phase">phase: {esc(phase)}</span>
  </header>
  <p class="goal">{esc(goal)}</p>
  <div class="gates">{gate_html}</div>
  <div class="cols">
    <div><h4>Results</h4>{res_html}</div>
    <div><h4>Timeline <span class="muted">({len(events)} events)</span></h4>{timeline}</div>
  </div>
  <footer class="muted">created {esc(created)} · updated {esc(updated)}</footer>
</section>'''

cards = "\n".join(card(d, e) for d, e in workflows) or '<p class="empty">No workflows found under <code>.mtk/workflows/</code>.</p>'
refresh_tag = f'<meta http-equiv="refresh" content="{esc(refresh)}">' if refresh and refresh != "0" else ""
count = len(workflows)

page = f'''<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{refresh_tag}
<title>MTK Workflows ({count})</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ font: 14px/1.5 -apple-system, system-ui, sans-serif; margin: 0; background: #f6f7f9; color: #111827; }}
  .top {{ padding: 16px 24px; border-bottom: 1px solid #e5e7eb; background: #fff; display:flex; align-items:baseline; gap:12px; }}
  .top h1 {{ font-size: 16px; margin: 0; }}
  .top .muted {{ font-size: 12px; }}
  main {{ padding: 20px 24px; max-width: 1100px; margin: 0 auto; }}
  .wf {{ background: #fff; border: 1px solid #e5e7eb; border-radius: 10px; padding: 16px 18px; margin-bottom: 18px; }}
  .wf header {{ display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }}
  .badge {{ color: #fff; font-size: 11px; font-weight: 600; padding: 2px 8px; border-radius: 999px; text-transform: uppercase; letter-spacing: .03em; }}
  .type {{ font-weight: 600; }}
  .uuid {{ font-size: 12px; color: #6b7280; }}
  .phase {{ font-size: 12px; color: #6b7280; margin-left: auto; }}
  .goal {{ margin: 10px 0; font-size: 15px; }}
  .gates {{ display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 12px; }}
  .gate {{ font-size: 11px; border: 1px solid; border-radius: 6px; padding: 2px 8px; }}
  .cols {{ display: grid; grid-template-columns: 1fr 1fr; gap: 18px; }}
  @media (max-width: 720px) {{ .cols {{ grid-template-columns: 1fr; }} .phase {{ margin-left: 0; }} }}
  h4 {{ margin: 0 0 6px; font-size: 12px; text-transform: uppercase; letter-spacing: .04em; color: #6b7280; }}
  table.kv {{ border-collapse: collapse; width: 100%; }}
  table.kv td {{ border-bottom: 1px solid #f0f1f3; padding: 3px 6px; vertical-align: top; }}
  table.kv td:first-child {{ color: #6b7280; white-space: nowrap; }}
  .timeline {{ list-style: none; margin: 0; padding: 0; max-height: 260px; overflow: auto; font-size: 13px; }}
  .timeline li {{ padding: 2px 0; border-bottom: 1px solid #f5f6f7; }}
  .ts {{ color: #9ca3af; font-variant-numeric: tabular-nums; font-size: 11px; }}
  .etype {{ font-weight: 600; }}
  .muted {{ color: #9ca3af; }}
  footer.muted {{ margin-top: 12px; font-size: 11px; }}
  .empty {{ color: #6b7280; }}
  code {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }}
</style>
</head><body>
  <div class="top"><h1>MTK Workflows</h1><span class="muted">{count} workflow(s) · read-only view of .mtk/workflows/</span></div>
  <main>
  {cards}
  </main>
</body></html>'''

with open(out_file, "w") as f:
    f.write(page)
print(out_file)
PY
}

open_browser() {
  [ "$OPEN" = "1" ] || return 0
  # Respect CI / headless: only attempt when a URL/file opener exists.
  local target="$1"
  if command -v open >/dev/null 2>&1; then
    open "$target" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$target" >/dev/null 2>&1 || true
  fi
}

if [ "$WATCH" = "1" ]; then
  if [ -n "$OUT" ]; then
    fail "--out is incompatible with --watch (watch serves a directory)"
  fi
  SERVE_DIR="$OUT_PARENT"
  render "$INTERVAL" >/dev/null
  # Start the static server in the served dir, bound to localhost.
  ( cd "$SERVE_DIR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
  SERVER_PID=$!
  trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT INT TERM
  URL="http://127.0.0.1:${PORT}/"
  printf 'Serving %s at %s (refresh every %ss). Ctrl-C to stop.\n' "$SERVE_DIR" "$URL" "$INTERVAL"
  printf 'Share with stakeholders: expose port %s via the ngrok-expose or cfd skill.\n' "$PORT"
  open_browser "$URL"
  while kill -0 "$SERVER_PID" 2>/dev/null; do
    render "$INTERVAL" >/dev/null
    sleep "$INTERVAL"
  done
else
  render 0 >/dev/null
  printf 'Wrote %s\n' "$OUT_FILE"
  open_browser "$OUT_FILE"
fi
