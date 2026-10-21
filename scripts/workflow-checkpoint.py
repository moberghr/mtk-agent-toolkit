#!/usr/bin/env python3
"""workflow-checkpoint.py — the canonical checkpoint of one workflow.

Called by scripts/workflow-artifact.sh (`checkpoint` and `resume`), which
passes the project root and the workflow directory so both scripts read the
same files. Not meant to be run by hand. Stdlib only.

  workflow-checkpoint.py --root <dir> --wf-dir <dir> checkpoint <uuid> [flags]
  workflow-checkpoint.py --root <dir> --wf-dir <dir> resume <uuid> [--offline] [--porcelain]

checkpoint — stores the model's flags on the artifact (the source of truth),
then re-renders docs/handoffs/<slug>.md from it in full. The path is computed
once (spec slug, else the workflow uuid) and kept in results.checkpoint_path,
so every later checkpoint rewrites that one file. Before writing it:
  * the validator refuses (exit 3, nothing written) a --next or --next-command
    that names a unit the plan sidecar already counts as done;
  * the note is kept out of git: a self-ignoring docs/handoffs/.gitignore ('*')
    when the directory tracks nothing, else one stderr warning;
  * the working tree is snapshotted into refs/mtk/checkpoints/<uuid> through a
    temporary index, so HEAD, the branch, the real index and the worktree are
    never touched (MTK_CHECKPOINT_SNAPSHOT=0 or --no-snapshot turn it off;
    untracked files over MTK_CHECKPOINT_MAX_FILE_MB, default 5, are left out).
Flags: --next T · --decision T (repeatable) · --needs-user "Q | default: D"
(repeatable) · --no-needs-user · --next-command C · --verify "CMD => RESULT" ·
--wait-until ISO-8601 · --close · --offline (no gh) · --no-snapshot.

resume — strictly read-only: prints the four-line RESUME block (drift against
results.checkpoint, plus the PR state from gh unless --offline). --porcelain
prints stable key=value lines instead (uuid type phase status note drift
pr_checked next_command needs_user); consumers parse those, never the block.

Exit: 0 ok · 1 unknown workflow or bad flag · 3 validator rejection.
"""
import copy
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.stdout.reconfigure(newline="\n")  # LF even on Windows python3

PROG = "workflow-artifact"
GH_TIMEOUT = 8
REF_PREFIX = "refs/mtk/checkpoints/"
STANDING_ORDERS = "Historical snapshot, not standing orders: the user's latest message wins."
FLAG_TAKES_VALUE = ("--next", "--decision", "--needs-user", "--next-command", "--verify", "--wait-until")
ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$")


class Fail(Exception):
    """Exit 1: unknown workflow or bad flag."""


def warn(msg):
    sys.stderr.write("%s: %s\n" % (PROG, msg))


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def iso(ts):
    return ts.strftime("%Y-%m-%dT%H:%M:%SZ")


def one_line(value):
    # Frontmatter values are single lines; handoff-state.sh reads them line by line.
    return " ".join(str(value).split())


def base_env():
    env = dict(os.environ)
    # Read-only git calls (status) must not opportunistically rewrite the real index.
    env["GIT_OPTIONAL_LOCKS"] = "0"
    env["GIT_TERMINAL_PROMPT"] = "0"
    env.pop("GIT_INDEX_FILE", None)
    return env


def git(cwd, *args, env=None, data=None):
    """Run git; return (rc, stdout, stderr). rc 127 when git cannot start."""
    try:
        p = subprocess.run(
            ["git", "-C", cwd, *args],
            input=data if data is not None else None,
            stdin=None if data is not None else subprocess.DEVNULL,
            capture_output=True, text=True, env=env or base_env())
    except OSError as e:
        return 127, "", str(e)
    return p.returncode, p.stdout, p.stderr


def first_line(text, limit=160):
    for line in (text or "").splitlines():
        line = line.strip()
        if line:
            return line[:limit]
    return ""


# ---------------------------------------------------------------- artifact --

def load_doc(wf_dir, uuid):
    path = os.path.join(wf_dir, uuid + ".json")
    if not uuid or not os.path.isfile(path):
        raise Fail("no artifact for %s" % (uuid or "<missing uuid>"))
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as e:
        raise Fail("cannot read %s: %s" % (path, e))
    if not isinstance(doc, dict):
        raise Fail("%s is not a JSON object" % path)
    if not isinstance(doc.get("results"), dict):
        doc["results"] = {}
    return path, doc


def write_json_atomic(path, doc):
    tmp = path + ".tmp-%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
    os.replace(tmp, path)


def append_event(wf_dir, uuid, now, etype, data):
    # Same line shape as workflow-artifact.sh cmd_event writes.
    line = json.dumps({"ts": now, "workflow_uuid": uuid, "event": etype, "data": data},
                      separators=(",", ":"))
    with open(os.path.join(wf_dir, uuid + ".events.jsonl"), "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def note_relpath(doc, uuid):
    results = doc["results"]
    stored = results.get("checkpoint_path")
    if isinstance(stored, str) and stored:
        return stored
    spec = results.get("spec_path")
    if isinstance(spec, str) and spec.strip():
        slug = os.path.splitext(os.path.basename(spec.strip()))[0]
    else:
        # Workflow uuids already carry the wf- prefix; never double it.
        slug = uuid if uuid.startswith("wf-") else "wf-" + uuid
    return "docs/handoffs/%s.md" % slug


def default_next_command(doc, note_rel):
    wf_type = doc.get("workflow_type")
    if wf_type == "BUILD":
        return "/mtk:implement"
    if wf_type == "FIX":
        return "/mtk:batch-fix"
    return "read %s and continue" % note_rel


def as_list(value):
    return value if isinstance(value, list) else []


# ------------------------------------------------------------------- units --

def load_units(root, doc):
    """Return (rows, reason). rows: [(id, title, status)]; reason set when no sidecar."""
    results = doc["results"]
    spec = results.get("spec_path")
    if not isinstance(spec, str) or not spec.strip():
        return None, "results.spec_path not set"
    spec = spec.strip()
    stem, ext = os.path.splitext(spec)
    if ext == ".md":
        sidecar = stem + ".json"
    elif ext == ".json":
        sidecar = spec
    else:
        sidecar = spec + ".json"
    path = sidecar if os.path.isabs(sidecar) else os.path.join(root, sidecar)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return None, "%s not found" % sidecar
    except (OSError, ValueError) as e:
        return None, "%s unreadable: %s" % (sidecar, e)
    plan = data.get("plan") if isinstance(data, dict) else None
    batches = plan.get("batches") if isinstance(plan, dict) else None
    if not isinstance(batches, list):
        return None, "%s has no plan.batches" % sidecar
    units = [(b["id"], str(b.get("title") or "")) for b in batches
             if isinstance(b, dict) and isinstance(b.get("id"), str) and b["id"]]
    impl = data.get("implement") if isinstance(data, dict) else None
    completed = as_list(impl.get("completed_batches")) if isinstance(impl, dict) else []
    if completed:
        # Batches can finish out of plan order: when the sidecar names them, it alone decides.
        done = set()
        for entry in completed:
            if isinstance(entry, str) and entry:
                done.add(entry)
            elif isinstance(entry, dict) and isinstance(entry.get("batch_id"), str):
                done.add(entry["batch_id"])
            else:
                warn("checkpoint: %s: ignoring a completed_batches entry with no batch id" % sidecar)
    else:
        # The inline path never writes completed_batches: count the first N in plan order.
        n = results.get("batches_completed")
        n = n if isinstance(n, int) and not isinstance(n, bool) and n > 0 else 0
        done = {uid for uid, _ in units[:n]}
    rows, next_set = [], False
    for uid, title in units:
        if uid in done:
            status = "done"
        elif not next_set:
            status, next_set = "next", True
        else:
            status = "pending"
        rows.append((uid, title, status))
    return rows, None


def names_done(text, done_ids):
    if not isinstance(text, str) or not text:
        return []
    return [uid for uid in done_ids if re.search(r"(?<!\w)%s(?!\w)" % re.escape(uid), text)]


# --------------------------------------------------------------------- git --

def git_state(root):
    rc, top, _ = git(root, "rev-parse", "--show-toplevel")
    if rc != 0 or not top.strip():
        return None
    st = {"toplevel": top.strip()}
    rc, out, _ = git(root, "symbolic-ref", "--short", "-q", "HEAD")
    st["branch"] = out.strip() if rc == 0 else ""
    rc, out, _ = git(root, "rev-parse", "-q", "--verify", "HEAD")
    st["sha"] = out.strip() if rc == 0 else ""
    st["short"] = ""
    if st["sha"]:
        rc, out, _ = git(root, "rev-parse", "--short", st["sha"])
        st["short"] = out.strip() if rc == 0 else st["sha"][:7]
    rc, out, _ = git(root, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    st["upstream"] = out.strip() if rc == 0 else ""
    st["ahead"] = st["behind"] = "-"
    st["pushed"] = "unknown"
    if st["upstream"] and st["sha"]:
        rc, out, _ = git(root, "rev-list", "--left-right", "--count", "HEAD...@{u}")
        parts = out.split()
        if rc == 0 and len(parts) == 2:
            st["ahead"], st["behind"] = parts
        rc, _, _ = git(root, "merge-base", "--is-ancestor", "HEAD", "@{u}")
        st["pushed"] = "true" if rc == 0 else ("false" if rc == 1 else "unknown")
    rc, out, _ = git(root, "status", "--porcelain")
    st["dirty"] = len([l for l in out.splitlines() if l.strip()]) if rc == 0 else None
    return st


def ensure_ignored(root, note_rel):
    """R1.3. Returns a short outcome word; warns once on stderr when the note is committable."""
    rc, _, err = git(root, "check-ignore", "-q", "--", note_rel)
    if rc == 0:
        return "ignored"
    if rc != 1:
        warn("checkpoint: git check-ignore failed (%s); %s may be committable" % (first_line(err) or rc, note_rel))
        return "unknown"
    note_dir = os.path.dirname(note_rel) or "."
    rc, tracked, _ = git(root, "ls-files", "-z", "--", note_dir)
    if rc == 0 and tracked.strip("\0"):
        warn("checkpoint: %s is not git-ignored and %s/ tracks files — the note is committable" % (note_rel, note_dir))
        return "tracked"
    gitignore = os.path.join(root, note_dir, ".gitignore")
    if os.path.exists(gitignore):
        warn("checkpoint: %s is not git-ignored and %s/.gitignore exists — left as is; the note is committable" % (note_rel, note_dir))
        return "not-ignored"
    os.makedirs(os.path.dirname(gitignore), exist_ok=True)
    with open(gitignore, "w", encoding="utf-8") as fh:
        fh.write("*\n")  # ignores itself and every note beside it
    return "self-ignored"


def max_file_bytes():
    raw = os.environ.get("MTK_CHECKPOINT_MAX_FILE_MB", "") or "5"
    try:
        mb = float(raw)
        if mb <= 0:
            raise ValueError
    except ValueError:
        warn("checkpoint: MTK_CHECKPOINT_MAX_FILE_MB=%s is not a positive number; using 5" % raw)
        mb = 5.0
    return mb, int(mb * 1024 * 1024)


def message_key(message):
    # The `updated:` stamp changes every second; it must not count as a message change.
    return "\n".join(l for l in message.split("\n") if not l.startswith("updated: "))


def snapshot(st, uuid, message):
    """R1.5. Never touches HEAD, the branch, the real index or the worktree."""
    top = st["toplevel"]
    ref = REF_PREFIX + uuid
    mb, limit = max_file_bytes()
    tmpd = tempfile.mkdtemp(prefix="mtk-checkpoint-")
    try:
        env = base_env()
        idx_env = dict(env, GIT_INDEX_FILE=os.path.join(tmpd, "index"))

        def step(what, rc_out_err):
            rc, out, err = rc_out_err
            if rc != 0:
                raise RuntimeError("%s failed: %s" % (what, first_line(err) or "exit %d" % rc))
            return out.strip()

        step("read-tree", git(top, "read-tree", *([st["sha"]] if st["sha"] else ["--empty"]), env=idx_env))
        # Untracked = absent from the REAL index (read-only listing); oversized ones stay out.
        untracked = step("ls-files", git(top, "ls-files", "--others", "--exclude-standard", "-z", env=env))
        big = []
        for rel in untracked.split("\0"):
            if not rel:
                continue
            try:
                if os.lstat(os.path.join(top, rel)).st_size > limit:
                    big.append(rel)
            except OSError:
                continue
        if big:
            spec_file = os.path.join(tmpd, "pathspec")
            with open(spec_file, "w", encoding="utf-8") as fh:
                fh.write(".\0" + "".join(":(exclude,literal)%s\0" % rel for rel in big))
            step("add", git(top, "add", "-A", "--pathspec-from-file=" + spec_file, "--pathspec-file-nul", env=idx_env))
        else:
            step("add", git(top, "add", "-A", env=idx_env))
        tree = step("write-tree", git(top, "write-tree", env=idx_env))
        info = {"ref": ref, "tree": tree, "skipped_large": len(big), "max_file_mb": mb}
        rc, prev_tree, _ = git(top, "rev-parse", "-q", "--verify", ref + "^{tree}", env=env)
        if rc == 0 and prev_tree.strip() == tree:
            rc, prev, _ = git(top, "rev-parse", "-q", "--verify", ref, env=env)
            rc_m, raw, _ = git(top, "cat-file", "commit", ref, env=env)
            old_msg = raw.split("\n\n", 1)[1] if rc_m == 0 and "\n\n" in raw else None
            if old_msg is not None and message_key(old_msg) == message_key(message):
                info.update(commit=prev.strip(), moved=False)
                return info
            # Same tree, new message (a changed --next, decision, ...): the ref moves to a
            # fresh commit on that tree so the fallback message stays current.
            info["refreshed"] = True
        cenv = dict(env)
        rc_n, name, _ = git(top, "config", "user.name", env=env)
        rc_e, email, _ = git(top, "config", "user.email", env=env)
        if rc_n != 0 or not name.strip() or rc_e != 0 or not email.strip():
            for who in ("AUTHOR", "COMMITTER"):
                cenv["GIT_%s_NAME" % who] = "MTK checkpoint"
                cenv["GIT_%s_EMAIL" % who] = "mtk@localhost"
        parents = ["-p", st["sha"]] if st["sha"] else []
        commit = step("commit-tree", git(top, "commit-tree", "--no-gpg-sign", tree, *parents, env=cenv, data=message))
        step("update-ref", git(top, "update-ref", "-m", "mtk checkpoint", ref, commit, env=env))
        info.update(commit=commit, moved=True)
        return info
    except (RuntimeError, OSError) as e:
        # Never fatal: the note still gets written, and says the snapshot failed.
        warn("checkpoint: snapshot skipped — %s" % e)
        return {"ref": ref, "error": str(e)}
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)


# ---------------------------------------------------------------------- gh --

def gh_pr(root, branch, fields, offline):
    if offline:
        return {"checked": False, "reason": "--offline"}
    if not branch:
        return {"checked": False, "reason": "no branch"}
    exe = shutil.which("gh")
    if not exe:
        return {"checked": False, "reason": "gh not found"}
    env = dict(os.environ, GH_PROMPT_DISABLED="1", GH_PAGER="cat", NO_COLOR="1")
    try:
        p = subprocess.run([exe, "pr", "view", branch, "--json", fields], cwd=root, env=env,
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=GH_TIMEOUT)
    except subprocess.TimeoutExpired:
        return {"checked": False, "reason": "gh timed out after %ds" % GH_TIMEOUT}
    except OSError as e:
        return {"checked": False, "reason": "gh failed to start: %s" % e}
    if p.returncode != 0:
        msg = first_line(p.stderr) or first_line(p.stdout)
        if "no pull requests found" in msg.lower():
            return {"checked": True, "none": True}
        return {"checked": False, "reason": "gh exited %d: %s" % (p.returncode, msg or "no output")}
    try:
        data = json.loads(p.stdout)
        if not isinstance(data, dict):
            raise ValueError("not an object")
    except ValueError:
        return {"checked": False, "reason": "gh returned unparseable JSON"}
    out = {"checked": True, "number": data.get("number"), "state": data.get("state"),
           "url": data.get("url"), "isDraft": data.get("isDraft"), "base": data.get("baseRefName")}
    if "statusCheckRollup" in data:
        passed = failed = pending = 0
        failing = []
        for c in as_list(data.get("statusCheckRollup")):
            if not isinstance(c, dict):
                continue
            verdict = str(c.get("conclusion") or c.get("state") or "").upper()
            if verdict in ("SUCCESS", "NEUTRAL", "SKIPPED"):
                passed += 1
            elif verdict in ("FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"):
                failed += 1
                failing.append(str(c.get("name") or c.get("context") or "?"))
            else:
                pending += 1
        out["checks"] = {"passed": passed, "failed": failed, "pending": pending, "failing": failing}
    return out


# -------------------------------------------------------------- checkpoint --

def parse_checkpoint_flags(args):
    f = {"next": None, "decisions": [], "needs_user": [], "no_needs_user": False, "next_command": None,
         "verify": None, "wait_until": None, "close": False, "offline": False, "no_snapshot": False}
    i = 0
    while i < len(args):
        a = args[i]
        if a in FLAG_TAKES_VALUE:
            if i + 1 >= len(args):
                raise Fail("checkpoint: %s needs a value" % a)
            v = args[i + 1]
            i += 2
            if a == "--next":
                f["next"] = v
            elif a == "--decision":
                f["decisions"].append(v)
            elif a == "--needs-user":
                m = re.match(r"^(.*?)\s*\|\s*default:\s*(.*)$", v, re.S)
                q, d = (m.group(1), m.group(2)) if m else (v, "")
                if not q.strip():
                    raise Fail("checkpoint: --needs-user needs a question (\"<question> | default: <default>\")")
                f["needs_user"].append({"question": one_line(q), "default": one_line(d)})
            elif a == "--next-command":
                f["next_command"] = v
            elif a == "--verify":
                if " => " not in v:
                    raise Fail("checkpoint: --verify expects \"<cmd> => <result>\" (got: %s)" % v)
                cmd, result = v.rsplit(" => ", 1)
                f["verify"] = (cmd.strip(), result.strip())
            elif a == "--wait-until":
                if not ISO_RE.match(v):
                    raise Fail("checkpoint: --wait-until must be ISO-8601 (got: %s)" % v)
                f["wait_until"] = v
            continue
        if a == "--no-needs-user":
            f["no_needs_user"] = True
        elif a == "--close":
            f["close"] = True
        elif a == "--offline":
            f["offline"] = True
        elif a == "--no-snapshot":
            f["no_snapshot"] = True
        else:
            raise Fail("unknown flag: %s" % a)
        i += 1
    if f["no_needs_user"] and f["needs_user"]:
        raise Fail("checkpoint: --needs-user and --no-needs-user are mutually exclusive")
    return f


def render_frontmatter(fm):
    keys = ("state", "branch", "worktree", "workflow", "sha", "pushed", "ahead", "behind",
            "next_command", "needs_user", "wait_until", "expires", "updated")
    return "---\n" + "".join("%s: %s\n" % (k, fm[k]) for k in keys) + "---\n"


def render_next(results, next_command):
    body = results.get("next_notes")
    body = body.strip() if isinstance(body, str) and body.strip() else "(no next step recorded — pass --next)"
    return "## Next\n\n%s\n\nnext_command: `%s`\n\n%s\n" % (body, one_line(next_command), STANDING_ORDERS)


def bullet_list(items, empty):
    return "".join("- %s\n" % i for i in items) if items else "%s\n" % empty


def render_note(doc, uuid, fm, st, snap, pr, rows, units_reason, next_command):
    r = doc["results"]
    goal = (doc.get("intent") or {}).get("goal") if isinstance(doc.get("intent"), dict) else None
    out = [render_frontmatter(fm), "\n",
           "# Checkpoint — %s\n\n" % one_line(goal or uuid),
           "<!-- Rendered by `workflow-artifact.sh checkpoint %s` from .mtk/workflows/%s.json. "
           "Every checkpoint rewrites this file in full: change the workflow through checkpoint flags, "
           "not by editing this note. -->\n\n" % (uuid, uuid)]

    out.append("## Goal\n\n%s\n\n" % (goal.strip() if isinstance(goal, str) and goal.strip() else "(no goal recorded)"))
    out.append(render_next(r, next_command) + "\n")

    questions = ["%s — default: %s" % (q.get("question", ""), q.get("default") or "(none given)")
                 for q in as_list(r.get("needs_user")) if isinstance(q, dict)]
    out.append("## Open questions\n\n" + bullet_list(questions, "none") + "\n")

    out.append("## Units\n\n")
    if rows is None:
        out.append("no plan sidecar (%s)\n\n" % units_reason)
    elif not rows:
        out.append("no units in the plan sidecar\n\n")
    else:
        out.append("| Unit | Title | Status |\n|---|---|---|\n")
        out.extend("| %s | %s | %s |\n" % (uid, title.replace("|", "\\|"), status) for uid, title, status in rows)
        out.append("\n")

    decisions = [one_line(d) for d in as_list(r.get("decisions")) if isinstance(d, str)]
    out.append("## Decisions\n\n" + bullet_list(decisions, "none recorded") + "\n")

    traps = ["[%s] %s" % (str(t.get("severity", "warn")).upper(), t.get("title", ""))
             for t in as_list(r.get("trap_list")) if isinstance(t, dict)]
    out.append("## Traps\n\n" + bullet_list(traps, "none recorded") + "\n")

    lv = r.get("last_verify")
    if isinstance(lv, dict) and lv.get("cmd"):
        out.append("## Last verify\n\n`%s` => %s (sha %s, %s)\n\n" % (lv.get("cmd"), lv.get("result") or "(no result)",
                                                                   lv.get("sha") or "-", lv.get("at") or "-"))
    else:
        out.append("## Last verify\n\nnone recorded\n\n")

    out.append("## Git\n\n")
    if st is None:
        out.append("not a git repository\n\n")
    else:
        up = ("upstream `%s` (ahead %s, behind %s)" % (st["upstream"], st["ahead"], st["behind"])
              if st["upstream"] else "no upstream")
        out.append("- branch `%s` · sha `%s` · %s\n" % (st["branch"] or "(detached)", st["short"] or "(no commits)", up))
        out.append("- dirty paths: %s\n" % ("unknown" if st["dirty"] is None else st["dirty"]))
        out.append("- worktree: `%s`\n" % st["toplevel"])
        if snap.get("commit"):
            if snap.get("refreshed"):
                extra = " (message refreshed, tree unchanged)"
            else:
                extra = "" if snap.get("moved") else " (unchanged since the previous checkpoint)"
            out.append("- snapshot: `%s` @ `%s`%s — restore the code with `git restore --source=%s -- .`\n"
                       % (snap["ref"], snap["commit"][:12], extra, snap["ref"]))
            if snap.get("skipped_large"):
                out.append("- snapshot left out %d untracked file(s) over %g MB\n" % (snap["skipped_large"], snap["max_file_mb"]))
        elif snap.get("error"):
            out.append("- snapshot: failed — %s\n" % snap["error"])
        else:
            out.append("- snapshot: skipped (%s)\n" % snap.get("skipped", "disabled"))
        out.append("\n")

    out.append("## PRs and CI\n\n")
    if not pr.get("checked"):
        out.append("not checked (%s)\n" % pr.get("reason"))
    elif pr.get("none"):
        out.append("no pull request for `%s`\n" % (st or {}).get("branch", ""))
    else:
        draft = " (draft)" if pr.get("isDraft") else ""
        out.append("- PR #%s %s%s → `%s` — %s\n" % (pr.get("number"), pr.get("state"), draft, pr.get("base"), pr.get("url")))
        ch = pr.get("checks")
        if ch:
            line = "- checks: %d passed, %d failed, %d pending" % (ch["passed"], ch["failed"], ch["pending"])
            if ch["failing"]:
                line += " (failing: %s)" % ", ".join(ch["failing"])
            out.append(line + "\n")
    return "".join(out)


def cmd_checkpoint(root, wf_dir, uuid, args):
    art_path, doc = load_doc(wf_dir, uuid)
    flags = parse_checkpoint_flags(args)
    now_dt = utc_now()
    now = iso(now_dt)
    new = copy.deepcopy(doc)
    r = new["results"]
    st = git_state(root)

    # 1. Flags onto the artifact (in memory; nothing is written before the validator passes).
    if flags["next"] is not None:
        r["next_notes"] = flags["next"]
    if flags["decisions"]:
        decisions = [d for d in as_list(r.get("decisions")) if isinstance(d, str)]
        for d in flags["decisions"]:
            if d.strip() and d.strip() not in decisions:
                decisions.append(d.strip())
        r["decisions"] = decisions
    if flags["no_needs_user"]:
        r["needs_user"] = []
    elif flags["needs_user"]:
        r["needs_user"] = flags["needs_user"]
    if flags["next_command"] is not None:
        r["next_command"] = flags["next_command"]
    if flags["verify"]:
        r["last_verify"] = {"cmd": flags["verify"][0], "result": flags["verify"][1],
                            "sha": (st or {}).get("short") or "-", "at": now}
    if flags["wait_until"]:
        r["wait_until"] = flags["wait_until"]

    # 2. Validator: a Resume step must not send the next session back to finished work.
    rows, units_reason = load_units(root, new)
    if rows is None and (isinstance(r.get("spec_path"), str) and r["spec_path"].strip()
                         or new.get("workflow_type") in ("BUILD", "FIX")):
        warn("checkpoint: done-unit validator inactive — %s; a --next naming finished work will not be caught"
             % units_reason)
    done_ids = [uid for uid, _, status in (rows or []) if status == "done"]
    problems = []
    hit = names_done(r.get("next_notes"), done_ids)
    if hit:
        src = "--next" if flags["next"] is not None else "results.next_notes (carried from an earlier checkpoint)"
        problems.append("%s names done unit(s) %s" % (src, ", ".join(hit)))
    hit = names_done(r.get("next_command"), done_ids)
    if hit:
        src = "--next-command" if flags["next_command"] is not None else "results.next_command (carried)"
        problems.append("%s names done unit(s) %s" % (src, ", ".join(hit)))
    if problems:
        nxt = next((uid for uid, _, status in rows if status == "next"), None)
        warn("checkpoint rejected: %s — the next unit is %s; fix it and re-run checkpoint (nothing was written)"
             % ("; ".join(problems), nxt or "none (every unit is done)"))
        return 3

    # 3. Render inputs.
    note_rel = note_relpath(new, uuid)
    note_abs = note_rel if os.path.isabs(note_rel) else os.path.join(root, note_rel)
    explicit_cmd = r.get("next_command") if isinstance(r.get("next_command"), str) and r.get("next_command") else None
    next_command = explicit_cmd or default_next_command(new, note_rel)
    state = "closed" if flags["close"] or new.get("status") != "active" else "open"
    needs = ["%s | default: %s" % (q.get("question", ""), q.get("default", ""))
             for q in as_list(r.get("needs_user")) if isinstance(q, dict)]
    fm = {
        "state": state,
        "branch": (st["branch"] or "-") if st else "-",
        "worktree": st["toplevel"] if st else os.path.abspath(root),
        "workflow": uuid,
        "sha": (st["short"] or "-") if st else "-",
        "pushed": st["pushed"] if st else "unknown",
        "ahead": st["ahead"] if st else "-",
        "behind": st["behind"] if st else "-",
        "next_command": one_line(next_command),
        "needs_user": json.dumps(needs, ensure_ascii=False),
        "wait_until": one_line(r.get("wait_until")) if r.get("wait_until") else "-",
        "expires": (now_dt + datetime.timedelta(days=14)).strftime("%Y-%m-%d"),
        "updated": now,
    }

    # 4. Keep the note out of git, then snapshot, then write the note.
    ignore = ensure_ignored(root, note_rel) if st else "outside-git"
    if st is None:
        snap = {"skipped": "not a git repository"}
    elif flags["no_snapshot"]:
        snap = {"skipped": "--no-snapshot"}
    elif os.environ.get("MTK_CHECKPOINT_SNAPSHOT", "") == "0":
        snap = {"skipped": "MTK_CHECKPOINT_SNAPSHOT=0"}
    else:
        subject = "MTK checkpoint %s (%s @ %s)\n\n" % (uuid, fm["branch"], fm["sha"])
        snap = snapshot(st, uuid, subject + render_frontmatter(fm) + "\n" + render_next(r, next_command))
    pr = gh_pr(root, st["branch"] if st else "", "number,state,url,isDraft,baseRefName,statusCheckRollup",
               flags["offline"])
    note = render_note(new, uuid, fm, st, snap, pr, rows, units_reason, next_command)
    os.makedirs(os.path.dirname(note_abs), exist_ok=True)
    with open(note_abs, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(note)

    # 5. Record the checkpoint on the artifact, then the event.
    r["checkpoint_path"] = note_rel
    r["handoff_path"] = note_rel  # read by the workflow Claude-Artifact renderer
    r["checkpoint"] = {
        "path": note_rel, "sha": st["sha"] if st else "", "branch": fm["branch"], "worktree": fm["worktree"],
        "at": now, "state": state, "snapshot": snap, "pr": pr, "ignore": ignore,
    }
    new["updated_at"] = now
    write_json_atomic(art_path, new)
    snap_word = ("moved" if snap.get("moved") else "unchanged") if snap.get("commit") else (
        "error" if snap.get("error") else "skipped")
    append_event(wf_dir, uuid, now, "checkpoint_written",
                 {"path": note_rel, "sha": fm["sha"], "branch": fm["branch"], "state": state,
                  "snapshot": snap_word, "pr_checked": bool(pr.get("checked"))})
    print("workflow-artifact: checkpoint %s -> %s" % (uuid, note_rel))
    return 0


# ------------------------------------------------------------------ resume --

def compute_drift(root, r, offline):
    """Return (drift text, pr_checked word). Read-only; never prints 'none' for a check it skipped."""
    cp = r.get("checkpoint")
    if not isinstance(cp, dict):
        return "no checkpoint recorded", "false"
    items, notes, unchecked = [], [], []
    wt = cp.get("worktree")
    if isinstance(wt, str) and wt and wt != "-" and not os.path.isdir(wt):
        items.append("worktree %s gone" % wt)
    branch, sha = cp.get("branch"), cp.get("sha")
    rc, _, _ = git(root, "rev-parse", "--show-toplevel")
    in_git = rc == 0
    pr_word = "offline" if offline else "false"
    if not in_git:
        unchecked.append("not in a git repository")
    elif not (isinstance(branch, str) and branch and branch != "-"):
        unchecked.append("checkpoint recorded no branch (detached or none)")
    else:
        rc, tip, _ = git(root, "rev-parse", "-q", "--verify", "refs/heads/" + branch)
        if rc != 0:
            items.append("branch %s gone" % branch)
        else:
            tip = tip.strip()
            rc, cur, _ = git(root, "symbolic-ref", "--short", "-q", "HEAD")
            cur = cur.strip() if rc == 0 else ""
            if cur != branch:
                items.append("on branch %s, note is for %s" % (cur or "(detached HEAD)", branch))
            if isinstance(sha, str) and sha:
                if tip != sha:
                    rc, n, _ = git(root, "rev-list", "--count", "%s..%s" % (sha, tip))
                    items.append("sha moved %s→%s (%s commits)" % (sha[:7], tip[:7], n.strip() if rc == 0 else "?"))
            else:
                unchecked.append("checkpoint recorded no sha")
        pr = gh_pr(root, branch, "number,state", offline)
        if pr.get("checked"):
            pr_word = "true"
            if not pr.get("none"):
                state = str(pr.get("state") or "").upper()
                if state in ("MERGED", "CLOSED"):
                    items.append("PR #%s %s" % (pr.get("number"), state.lower()))
        elif not offline:
            notes.append("PR not checked: %s" % pr.get("reason"))
    if items:
        drift = "; ".join(items)
    elif unchecked:
        drift = "unchecked (%s)" % "; ".join(unchecked)
    else:
        drift = "none"
    if offline:
        drift += "; PR not checked (offline)"
    elif notes:
        drift += " (%s)" % "; ".join(notes)
    return drift, pr_word


def cmd_resume(root, wf_dir, uuid, args):
    offline = porcelain = False
    for a in args:
        if a == "--offline":
            offline = True
        elif a == "--porcelain":
            porcelain = True
        else:
            raise Fail("unknown flag: %s" % a)
    _, doc = load_doc(wf_dir, uuid)
    r = doc["results"]
    note_rel = r.get("checkpoint_path") or note_relpath(doc, uuid)
    note_shown = r.get("checkpoint_path") or "(none written)"
    drift, pr_word = compute_drift(root, r, offline)
    cmd = r.get("next_command") if isinstance(r.get("next_command"), str) and r.get("next_command") else None
    next_command = one_line(cmd or default_next_command(doc, note_rel))
    needs = len(as_list(r.get("needs_user")))
    if porcelain:
        for k, v in (("uuid", uuid), ("type", doc.get("workflow_type", "?")), ("phase", doc.get("phase_cursor", "?")),
                     ("status", doc.get("status", "?")), ("note", note_shown), ("drift", drift),
                     ("pr_checked", pr_word), ("next_command", next_command), ("needs_user", needs)):
            print("%s=%s" % (k, one_line(v)))
        return 0
    print("RESUME %s (%s, %s, %s) — note: %s" % (uuid, doc.get("workflow_type", "?"), doc.get("phase_cursor", "?"),
                                                doc.get("status", "?"), note_shown))
    print("drift: %s" % drift)
    print("next_command: %s" % next_command)
    print("needs_user: %d open question(s) — see the note" % needs)
    return 0


# -------------------------------------------------------------------- main --

def main(argv):
    root = wf_dir = None
    while argv and argv[0] in ("--root", "--wf-dir"):
        if len(argv) < 2:
            raise Fail("%s needs a value" % argv[0])
        if argv[0] == "--root":
            root = argv[1]
        else:
            wf_dir = argv[1]
        argv = argv[2:]
    if not root or not wf_dir or len(argv) < 1:
        raise Fail("usage: workflow-checkpoint.py --root <dir> --wf-dir <dir> <checkpoint|resume> <uuid> [flags]")
    sub, rest = argv[0], argv[1:]
    uuid = rest[0] if rest else ""
    if not uuid or uuid.startswith("--"):
        raise Fail("%s requires <uuid>" % sub)
    if sub == "checkpoint":
        return cmd_checkpoint(root, wf_dir, uuid, rest[1:])
    if sub == "resume":
        return cmd_resume(root, wf_dir, uuid, rest[1:])
    raise Fail("unknown subcommand: %s" % sub)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Fail as e:
        warn(str(e))
        sys.exit(1)
