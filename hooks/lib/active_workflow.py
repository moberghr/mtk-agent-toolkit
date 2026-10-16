#!/usr/bin/env python3
"""Active-workflow selector shared by hooks/session-start and hooks/subagent-context.sh.

Usage: python3 hooks/lib/active_workflow.py <wf_dir> <days> <field>...
Fields: path | type | phase | pack.

Selects at most ONE workflow: the newest <wf_dir>/*.json whose `status`
(case-insensitive) is `active` and whose `updated_at` (%Y-%m-%dT%H:%M:%SZ, UTC)
is within <days> (float). Unreadable, non-dict and bad-timestamp files are
skipped. On a match prints ONE tab-separated line of the requested fields
(type/phase default "?", pack is the results.context_pack string when it is
non-empty and single-line, else empty). No match prints nothing, exit 0.
An unknown field or a bad <days> prints one stderr line and exits 2.
"""
import datetime
import glob
import json
import os
import sys

FIELDS = ("path", "type", "phase", "pack")


def select(wf_dir, days):
    """Return (path, doc) of the newest active workflow within `days`, or None."""
    now = datetime.datetime.now(datetime.timezone.utc)
    best = None
    for path in glob.glob(os.path.join(wf_dir, "*.json")):
        try:
            with open(path) as fh:
                doc = json.load(fh)
        except Exception:
            continue
        if not isinstance(doc, dict):
            continue
        if str(doc.get("status", "")).lower() != "active":
            continue
        try:
            ts = datetime.datetime.strptime(str(doc.get("updated_at", "")), "%Y-%m-%dT%H:%M:%SZ")
            ts = ts.replace(tzinfo=datetime.timezone.utc)
        except ValueError:
            continue
        if (now - ts).total_seconds() > days * 86400:
            continue
        if best is None or ts > best[0]:
            best = (ts, path, doc)
    return (best[1], best[2]) if best else None


def field_value(name, path, doc):
    if name == "path":
        return path
    if name == "type":
        return str(doc.get("workflow_type") or "?")
    if name == "phase":
        return str(doc.get("phase_cursor") or "?")
    results = doc.get("results")
    pack = results.get("context_pack") if isinstance(results, dict) else None
    if isinstance(pack, str) and pack.strip() and "\n" not in pack:
        return pack.strip()
    return ""


def main(argv):
    if len(argv) < 4:
        sys.stderr.write("usage: active_workflow.py <wf_dir> <days> <field>...\n")
        return 2
    wf_dir, days_raw, fields = argv[1], argv[2], argv[3:]
    try:
        days = float(days_raw)
    except ValueError:
        sys.stderr.write("active_workflow.py: bad days value: %s\n" % days_raw)
        return 2
    for name in fields:
        if name not in FIELDS:
            sys.stderr.write("active_workflow.py: unknown field: %s\n" % name)
            return 2
    sel = select(wf_dir, days)
    if sel:
        sys.stdout.reconfigure(newline="\n")
        print("\t".join(field_value(n, sel[0], sel[1]) for n in fields))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
