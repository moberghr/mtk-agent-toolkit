#!/usr/bin/env python3
"""Shared .mtk/sessions/ helpers for hooks/compact-archive.sh, hooks/session-start
and hooks/context-guard.sh. Stdlib only. Importable (insert hooks/lib on
sys.path) and runnable as a CLI:

  session_store.py ignored <root>
      exit 0 when <root>/.mtk/sessions/ may hold session data (a git repo that
      ignores .mtk/, or not a git repo); exit 3 when a git repo does NOT ignore
      it. Prints nothing.
  session_store.py dir <root> <session_id>
      print the sanitised session directory (nothing is created); exit 1 when
      the id is rejected (empty after sanitising, or dot-leading).
  session_store.py newest-archive <root> <branch> [max_age_seconds]
      print "<path>\\t<HH:MM YYYY-MM-DD>" (local time) of the newest
      .mtk/sessions/*/compact-*.md whose frontmatter `branch` equals <branch>
      and whose mtime is within max_age_seconds (default 86400); else nothing.
  session_store.py prune <root> [days]
      remove .mtk/sessions/* directories older than <days> (default 14), with
      `find -mtime +<days>` rounding; prints the number removed.

telemetry.json (written by hooks/context-guard.sh via telemetry_record, mode
0600, schema_version 1) is one JSON object with exactly these fields:
  schema_version  int, 1 (bump on any field change)
  session_id      the raw session id from the hook payload
  context_tokens  int, main-thread context size of the newest assistant usage
  window          int or null, the auto-compact window (env > settings files)
  pct             context_tokens / window rounded to 4 places, or null
  model           string or null
  workflow        active workflow uuid or null
  ts              UTC "YYYY-MM-DDTHH:MM:SSZ"

Usage errors exit 2. Session data is conversation-derived, so it is written
only where it cannot become committable (see `ignored`) and with mode 0600.
"""
import datetime
import glob
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True  # callers import siblings; never write hooks/lib/__pycache__

PRUNE_DAYS = 14
ARCHIVE_MAX_AGE = 86400


def sessions_root(root):
    return os.path.join(root, ".mtk", "sessions")


def mtk_ignored(root):
    """True when session data may be written under <root>/.mtk/: outside a git
    work tree, or inside one that git-ignores .mtk/sessions/x. Same rule as
    compact-archive.sh has always used; a missing git binary counts as not a
    repo."""
    try:
        inside = subprocess.run(["git", "-C", root, "rev-parse", "--is-inside-work-tree"],
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL).returncode == 0
    except OSError:
        return True
    if not inside:
        return True
    try:
        return subprocess.run(["git", "-C", root, "check-ignore", "-q", ".mtk/sessions/x"],
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0
    except OSError:
        return False


def sanitise_session_id(raw):
    """[^A-Za-z0-9._-] -> _; None when the result is empty or dot-leading."""
    sid = re.sub(r"[^A-Za-z0-9._-]", "_", str(raw or ""))
    if not sid or sid.startswith("."):
        return None
    return sid


def session_dir(root, raw_session_id):
    """<root>/.mtk/sessions/<sanitised id>, or None for a rejected id. Creates nothing."""
    sid = sanitise_session_id(raw_session_id)
    return os.path.join(sessions_root(root), sid) if sid else None


def newest_archive(root, branch, max_age=ARCHIVE_MAX_AGE):
    """(path, mtime) of the newest compact-*.md for `branch` within max_age seconds, or None."""
    best = None
    now = time.time()
    for f in glob.glob(os.path.join(sessions_root(root), "*", "compact-*.md")):
        try:
            m = os.path.getmtime(f)
            if now - m > max_age:
                continue
            b = None
            with open(f, encoding="utf-8", errors="replace") as fh:
                if fh.readline().strip() != "---":
                    continue
                for line in fh:
                    line = line.rstrip("\n")
                    if line.strip() == "---":
                        break
                    if line.startswith("branch:"):
                        b = line[7:].strip()
            if b == branch and (best is None or m > best[0]):
                best = (m, f)
        except Exception:
            continue
    return (best[1], best[0]) if best else None


def prune(root, days=PRUNE_DAYS):
    """Remove direct child directories of <root>/.mtk/sessions/ whose mtime is
    more than `days` whole days old (the rounding of `find -mtime +<days>`).
    A symlinked sessions dir is never followed, and symlinked or non-directory
    children are never touched. Returns the number of directories removed."""
    base = sessions_root(root)
    if os.path.islink(base) or not os.path.isdir(base):
        return 0
    now = time.time()
    removed = 0
    try:
        names = os.listdir(base)
    except OSError:
        return 0
    for name in names:
        path = os.path.join(base, name)
        try:
            st = os.lstat(path)
        except OSError:
            continue
        if not stat.S_ISDIR(st.st_mode):
            continue
        if int((now - st.st_mtime) // 86400) <= days:
            continue
        shutil.rmtree(path, ignore_errors=True)
        if not os.path.lexists(path):
            removed += 1
    return removed


TELEMETRY_SCHEMA_VERSION = 1


def telemetry_record(session_id, context_tokens, window, model, workflow, ts=None):
    """The one owner of telemetry.json's shape (see the module docstring).
    pct is computed here; ts defaults to the current UTC time."""
    pct = round(context_tokens / window, 4) if window else None
    if ts is None:
        ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {
        "schema_version": TELEMETRY_SCHEMA_VERSION,
        "session_id": session_id,
        "context_tokens": context_tokens,
        "window": window,
        "pct": pct,
        "model": model,
        "workflow": workflow,
        "ts": ts,
    }


def write_telemetry(root, raw_session_id, data):
    """Atomically write <session dir>/telemetry.json (mode 0600). Returns the
    path, or None for a rejected session id. The caller checks mtk_ignored()
    first; OSError propagates."""
    d = session_dir(root, raw_session_id)
    if not d:
        return None
    os.makedirs(d, mode=0o700, exist_ok=True)
    path = os.path.join(d, "telemetry.json")
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".telemetry.", suffix=".tmp")  # 0600, O_EXCL
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return path


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    args = argv[2:]
    try:
        if cmd == "ignored" and len(args) == 1:
            return 0 if mtk_ignored(args[0]) else 3
        if cmd == "dir" and len(args) == 2:
            d = session_dir(args[0], args[1])
            if not d:
                return 1
            print(d)
            return 0
        if cmd == "newest-archive" and len(args) in (2, 3):
            max_age = float(args[2]) if len(args) == 3 else ARCHIVE_MAX_AGE
            hit = newest_archive(args[0], args[1], max_age)
            if hit:
                sys.stdout.reconfigure(newline="\n")
                print("%s\t%s" % (hit[0], datetime.datetime.fromtimestamp(hit[1]).strftime("%H:%M %Y-%m-%d")))
            return 0
        if cmd == "prune" and len(args) in (1, 2):
            days = int(args[1]) if len(args) == 2 else PRUNE_DAYS
            print(prune(args[0], days))
            return 0
    except ValueError as exc:
        sys.stderr.write("session_store.py: bad argument: %s\n" % exc)
        return 2
    sys.stderr.write("usage: session_store.py ignored <root> | dir <root> <session_id> | "
                     "newest-archive <root> <branch> [max_age_s] | prune <root> [days]\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
