#!/usr/bin/env python3
"""The one reader of hooks/hooks.json handlers.

Shared by scripts/validate-toolkit.sh, scripts/mtk-doctor.sh and
tests/hooks/test-hooks-wiring.sh, so they cannot disagree on how a registered
command is split (shlex, a leading bash/sh/zsh dropped, quotes around the path).

Usage: python3 hooks/lib/hook_registry.py <hooks.json>
Prints one TSV line per handler:
  rarity<TAB>event<TAB>matcher<TAB>if<TAB>script<TAB>args<TAB>timeout<TAB>async
Absent matcher / if / timeout are empty fields; async is "true" or "false".
Exit 0 on success, 1 (one stderr line, no traceback) when the file is unreadable,
is not JSON or has no "hooks" object. A command that cannot be shlex-split is
skipped with a stderr warning (validate-toolkit's executable check reports it).

rarity is "rare" for a SubagentStart handler or a handler with an `if` filter
(neither fires in nearly every session), else "per-call".
"""
import json
import os
import shlex
import sys

SHELLS = ("bash", "sh", "zsh")


def handlers(path):
    """Yield one dict per handler in the hooks.json at `path`. Raises
    ValueError (one readable message) when the file cannot be used."""
    try:
        with open(path) as f:
            events = list(json.load(f)["hooks"].items())
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
        raise ValueError("%s: %s: %s" % (path, type(e).__name__, e))
    for event, blocks in events:
        for block in blocks if isinstance(blocks, list) else []:
            if not isinstance(block, dict):
                continue
            for h in block.get("hooks") or []:
                cmd = h.get("command") if isinstance(h, dict) else None
                if not cmd:
                    continue
                try:
                    argv = shlex.split(cmd)
                except ValueError as e:
                    print("hook_registry: skipping %s command %r: %s" % (event, cmd, e), file=sys.stderr)
                    continue
                if argv and argv[0] in SHELLS:
                    argv = argv[1:]
                if not argv:
                    continue
                cond = str(h.get("if") or "")
                timeout = h.get("timeout")
                yield {
                    "event": event,
                    "matcher": str(block.get("matcher") or ""),
                    "if": cond,
                    "script": os.path.basename(argv[0]),
                    "exe": argv[0],  # as registered, ${CLAUDE_PLUGIN_ROOT} unexpanded
                    "args": " ".join(argv[1:]),
                    "timeout": "" if timeout is None else str(timeout),
                    "async": h.get("async") is True,
                    "rarity": "rare" if event == "SubagentStart" or cond else "per-call",
                }


def main(argv):
    if len(argv) != 2:
        print("usage: hook_registry.py <hooks.json>", file=sys.stderr)
        return 1
    sys.stdout.reconfigure(newline="\n")  # LF even on Windows python3: bash parses this output
    try:
        rows = list(handlers(argv[1]))
    except ValueError as e:
        print("hook_registry: %s" % str(e).replace("\n", " "), file=sys.stderr)
        return 1
    for r in rows:
        print("\t".join([r["rarity"], r["event"], r["matcher"], r["if"], r["script"],
                         r["args"], r["timeout"], "true" if r["async"] else "false"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
