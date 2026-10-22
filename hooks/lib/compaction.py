#!/usr/bin/env python3
"""Effective auto-compaction settings, resolved the way Claude Code resolves them.

Shared by hooks/context-guard.sh (nudge wording, telemetry window) and
scripts/mtk-doctor.sh (the auto-compaction line), so the precedence lives in
one place.

Usage: python3 hooks/lib/compaction.py <project root>
Prints one tab-separated line:
  enabled=<0|1> <TAB> enabled_source=<s> <TAB> window=<n|-> <TAB> window_source=<s>

enabled: DISABLE_AUTO_COMPACT or DISABLE_COMPACT (truthy) in the environment turns
it off. A variable missing from the process environment is looked up in the
settings files' `env` blocks (same order as below): a hook inherits that block
from Claude Code, but mtk-doctor run from a plain shell does not. Otherwise the first settings file that sets a boolean autoCompactEnabled
decides, highest precedence first: the managed policy file
(/Library/Application Support/ClaudeCode/managed-settings.json on macOS,
/etc/claude-code/managed-settings.json elsewhere), <root>/.claude/settings.local.json,
<root>/.claude/settings.json, ~/.claude/settings.json; then ~/.claude.json (the
/config store, read only when no settings file sets the key); default on.
window: CLAUDE_CODE_AUTO_COMPACT_WINDOW (environment, then `env` blocks), then the first settings file above with
a positive autoCompactWindow; none means the model default (about 967k on 1M
models), reported as "-".
MTK_MANAGED_SETTINGS overrides the managed policy path (tests point it at a
sandbox). Unreadable or malformed files are skipped, as Claude Code ignores an unparseable
settings file (mtk-doctor reports an invalid project settings.json separately).
Exits 0, or 2 on a usage error.
"""
import json
import os
import sys

TRUTHY = ("1", "true", "yes", "on")


def _load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            cfg = json.load(fh)
    except (OSError, ValueError):
        return None
    return cfg if isinstance(cfg, dict) else None


def _positive_int(v):
    if isinstance(v, bool):
        return None
    try:
        n = int(v) if isinstance(v, float) else int(str(v).strip())
    except (TypeError, ValueError, OverflowError):  # NaN / Infinity from json.load included
        return None
    return n if n > 0 else None


def settings_files(root):
    """(label, path) of the settings files Claude Code reads, highest precedence first."""
    home = os.path.expanduser("~")
    managed = ("/Library/Application Support/ClaudeCode/managed-settings.json" if sys.platform == "darwin"
               else "/etc/claude-code/managed-settings.json")
    return [
        ("managed-settings.json", os.environ.get("MTK_MANAGED_SETTINGS", managed)),
        (".claude/settings.local.json", os.path.join(root, ".claude", "settings.local.json")),
        (".claude/settings.json", os.path.join(root, ".claude", "settings.json")),
        ("~/.claude/settings.json", os.path.join(home, ".claude", "settings.json")),
    ]


def _env(root, name):
    """(value, source label) of an env var: the process environment, then the settings `env` blocks."""
    v = os.environ.get(name)
    if v is not None:
        return v, "env " + name
    for label, path in settings_files(root):
        cfg = _load(path)
        block = cfg.get("env") if cfg is not None else None
        if isinstance(block, dict) and isinstance(block.get(name), str):
            return block[name], "env %s (%s)" % (name, label)
    return "", ""


def window(root):
    """(window tokens or None, source label)."""
    raw, src = _env(root, "CLAUDE_CODE_AUTO_COMPACT_WINDOW")
    w = _positive_int(raw)
    if w:
        return w, src
    for label, path in settings_files(root):
        cfg = _load(path)
        if cfg is not None and "autoCompactWindow" in cfg:
            w = _positive_int(cfg.get("autoCompactWindow"))
            if w:
                return w, label
    return None, "default"


def enabled(root):
    """(auto-compaction on?, source label)."""
    for name in ("DISABLE_AUTO_COMPACT", "DISABLE_COMPACT"):
        raw, src = _env(root, name)
        if raw.strip().lower() in TRUTHY:
            return False, src
    for label, path in settings_files(root):
        cfg = _load(path)
        if cfg is not None and isinstance(cfg.get("autoCompactEnabled"), bool):
            return cfg["autoCompactEnabled"], label
    cfg = _load(os.path.join(os.path.expanduser("~"), ".claude.json"))
    if cfg is not None and isinstance(cfg.get("autoCompactEnabled"), bool):
        return cfg["autoCompactEnabled"], "~/.claude.json"
    return True, "default"


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: compaction.py <project root>\n")
        return 2
    root = argv[1]
    on, on_src = enabled(root)
    w, w_src = window(root)
    print("enabled=%d\tenabled_source=%s\twindow=%s\twindow_source=%s" % (1 if on else 0, on_src, w if w else "-", w_src))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
