#!/usr/bin/env python3
"""Runtime-diet lock: report hooks.json registrations on the hot path.

The one classifier shared by scripts/validate-toolkit.sh (fails the build) and
scripts/mtk-doctor.sh (FAILs the install check), so the two can never disagree.

Usage: python3 hooks/lib/hot_path_matchers.py <hooks.json>
Prints one "<where>\t<why>" line per violation. Exit 0 clean, 1 violations,
2 unreadable or invalid JSON.

A violation is a UserPromptSubmit registration, or a tool-event matcher that can
fire on Read, Grep, Glob or any MCP tool. Matcher semantics follow Claude Code:
empty, missing or "*" matches every tool; a plain `A|B` list matches exactly
those names; anything else is a regex. Any matcher that names `mcp__` is MCP,
however it is scoped (`mcp__github__.*`, `Bash|mcp__memory__.*`); a regex that
could match an MCP tool name without spelling `mcp__` is caught by probing it
against sample MCP names. A regex that does not compile cannot be proved narrow.
"""
import json
import os
import re
import shlex
import sys

TOOL_EVENTS = ("PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest")
FILE_PROBES = ("Read", "Grep", "Glob")
MCP_PROBES = ("mcp__server__tool", "mcp__github__create_issue", "mcp__memory__read_graph")


def classify(matcher):
    """Return the hot-path tools a matcher covers ([] when it is narrow)."""
    if matcher in (None, "", "*"):
        return ["every tool"]
    hits = []
    if "mcp__" in matcher:
        hits.append("MCP calls")
    if re.fullmatch(r"[A-Za-z0-9_|]+", matcher):
        hits += [t for t in FILE_PROBES if t in matcher.split("|")]
        return hits
    try:
        rx = re.compile(matcher)
    except re.error:
        return ["every tool (matcher does not compile)"]
    hits += [t for t in FILE_PROBES if rx.search(t)]
    if "MCP calls" not in hits and any(rx.search(t) for t in MCP_PROBES):
        hits.append("MCP calls")
    return hits


def violations(hooks):
    out = []
    if hooks.get("UserPromptSubmit"):
        out.append(("UserPromptSubmit", "runs on every prompt"))
    for ev in TOOL_EVENTS:
        for block in hooks.get(ev) or []:
            m = block.get("matcher") if isinstance(block, dict) else None
            hit = classify(m)
            if hit:
                names = []
                for h in (block.get("hooks", []) if isinstance(block, dict) else []) or []:
                    try:
                        names.append(os.path.basename(shlex.split(h.get("command", ""))[0]))
                    except (ValueError, IndexError):
                        names.append("?")
                out.append(("%s matcher %r" % (ev, m if m is not None else ""),
                            "covers %s (%s)" % (", ".join(hit), ", ".join(names) or "no hooks")))
    return out


def main(argv):
    if len(argv) != 2:
        sys.stderr.write(__doc__ or "")
        return 2
    try:
        doc = json.load(open(argv[1]))
    except (OSError, ValueError) as exc:
        print("hooks.json\tunreadable or invalid JSON (%s)" % exc)
        return 2
    hooks = doc.get("hooks", {}) if isinstance(doc, dict) else {}
    found = violations(hooks if isinstance(hooks, dict) else {})
    for where, why in found:
        print("%s\t%s" % (where, why))
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
