#!/usr/bin/env bash
set -euo pipefail

# review-receipt.sh — diff-bound review receipts for the push gate.
#
# A receipt records that a full review PASSed for exactly the change the branch
# would push. It is bound to a change id, not to a branch name or a timestamp:
#
#   range      <merge-base>..HEAD, where merge-base is taken against
#              1. HEAD's upstream (@{upstream}) when one is set, else
#              2. the remote default branch (refs/remotes/origin/HEAD), else
#              3. the local branch `main`.
#   change_id  sha256( merge-base sha + "\n" + `git diff <merge-base>..HEAD` bytes )
#              The diff runs with external diff drivers, textconv, colour, rename
#              detection and the prefix/relative/order config pinned off, so a
#              user's git config cannot change the id. Any new commit or amended
#              content yields a new id; a message-only amend does not (same diff).
#
# Only committed content is covered: uncommitted edits are not part of the
# range. Once a branch has an upstream, the range is the unpushed commits only,
# so new commits after the first push need a new review.
#
# Receipts live at ~/.mtk/receipts/<sha256(repo realpath)>/<change_id>.json.
# Qualifying reviews only: a PASS from implement Phase 4 or from
# code-review-and-quality with every lane run. pre-commit-review never writes
# one — it is a fast staged-diff check with no push range. The script refuses
# any verdict other than PASS.
#
# Security: the receipts directories are created 0700 and receipt files are
# written 0600 (umask 077) through a temp file in the same directory and a
# rename. ~/.mtk, ~/.mtk/receipts and the per-repo directory must each be a real
# directory owned by the current user, never a symlink, and a receipt path that
# is a symlink is refused on write and ignored on check. Any refusal exits 2.
#
# Usage:
#   review-receipt.sh write --lanes <csv> --rigor <level> [--verdict PASS]
#   review-receipt.sh check
#   review-receipt.sh id
#   review-receipt.sh --help
#
# Subcommands:
#   write   record a PASS receipt for the current range; prints the receipt path.
#   check   first line `receipt: covered change_id=<id>` or
#           `receipt: missing change_id=<id> range=<mb>..<head> commits=<n>`,
#           then (missing only) the uncovered commits, at most 20 lines.
#   id      print `<change_id> <merge_base> <head> <base_ref>`.
#
# Exit codes:
#   0  write: receipt stored · check: a receipt covers the range (or the range
#      is empty) · id: printed
#   1  check: no receipt covers the current range
#   2  error: usage, not a git repository, no commit, no resolvable base,
#      python3 missing, or an ownership/symlink check refused

usage() {
  # Render the header from `# Usage:` to the blank line that ends it (a
  # sentinel range, so added lines never truncate the help).
  sed -n '/^# Usage:/,/^$/p' "$0" | sed -e 's/^# \{0,1\}//'
}

die() { # $1=message
  printf 'review-receipt: %s\n' "$1" >&2
  exit 2
}

MAX_LOG_LINES=20

SUB="${1:-}"
case "$SUB" in
  -h|--help|help) usage; exit 0 ;;
  write|check|id) shift ;;
  '') usage >&2; exit 2 ;;
  *) printf 'review-receipt: unknown subcommand: %s\n' "$SUB" >&2; usage >&2; exit 2 ;;
esac

LANES="" RIGOR="" VERDICT="PASS"
while [ $# -gt 0 ]; do
  case "$1" in
    --lanes) [ $# -ge 2 ] || die "--lanes needs a value"; LANES="$2"; shift 2 ;;
    --lanes=*) LANES="${1#--lanes=}"; shift ;;
    --rigor) [ $# -ge 2 ] || die "--rigor needs a value"; RIGOR="$2"; shift 2 ;;
    --rigor=*) RIGOR="${1#--rigor=}"; shift ;;
    --verdict) [ $# -ge 2 ] || die "--verdict needs a value"; VERDICT="$2"; shift 2 ;;
    --verdict=*) VERDICT="${1#--verdict=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [ "$SUB" = "write" ]; then
  [ -n "$LANES" ] || die "write needs --lanes <csv>"
  [ -n "$RIGOR" ] || die "write needs --rigor <level>"
  case "$LANES" in *[!A-Za-z0-9_,-]*) die "--lanes takes a comma-separated list of lane names" ;; esac
  case "$RIGOR" in *[!A-Za-z]*) die "--rigor takes a level name (e.g. HIGH)" ;; esac
  [ "$VERDICT" = "PASS" ] || die "only PASS verdicts are recorded (got: ${VERDICT:0:40})"
fi

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v git >/dev/null 2>&1 || die "git is required"

# --- Range ----------------------------------------------------------------
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git work tree"
REPO_REAL="$(cd "$TOP" 2>/dev/null && pwd -P)" || die "cannot resolve the repository path"
HEAD_SHA="$(git rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null)" || die "HEAD has no commit"

BASE_REF=""
if BASE_REF="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" \
  && [ -n "$BASE_REF" ] && git rev-parse --verify -q "${BASE_REF}^{commit}" >/dev/null 2>&1; then
  :
elif BASE_REF="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" \
  && [ -n "$BASE_REF" ] && git rev-parse --verify -q "${BASE_REF}^{commit}" >/dev/null 2>&1; then
  :
elif git rev-parse --verify -q 'refs/heads/main^{commit}' >/dev/null 2>&1; then
  BASE_REF="main"
else
  die "no base to compare against: no upstream, no origin/HEAD and no main branch"
fi

MB="$(git merge-base "$BASE_REF" "$HEAD_SHA" 2>/dev/null)" || die "no merge-base between $BASE_REF and HEAD"
[ -n "$MB" ] || die "no merge-base between $BASE_REF and HEAD"

# Pinned diff: every option that config or attributes could otherwise change.
CHANGE_ID="$(
  git -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.relative=false \
    -c diff.suppressBlankEmpty=false -c diff.context=3 \
    -c diff.interHunkContext=0 -c core.quotePath=true \
    diff --no-ext-diff --no-textconv --no-color --binary --full-index --no-renames \
    --diff-algorithm=myers --indent-heuristic --src-prefix=a/ --dst-prefix=b/ \
    --ignore-submodules=none --submodule=short -O/dev/null \
    "$MB" "$HEAD_SHA" 2>/dev/null \
  | python3 -I -c '
import hashlib, sys
h = hashlib.sha256()
h.update(sys.argv[1].encode() + b"\n")
for chunk in iter(lambda: sys.stdin.buffer.read(65536), b""):
    h.update(chunk)
print(h.hexdigest())
' "$MB"
)" || die "could not compute the change id"
case "$CHANGE_ID" in
  *[!0-9a-f]*|'') die "could not compute the change id" ;;
esac

if [ "$SUB" = "id" ]; then
  printf '%s %s %s %s\n' "$CHANGE_ID" "$MB" "$HEAD_SHA" "$BASE_REF"
  exit 0
fi

[ -n "${HOME:-}" ] || die "HOME is not set"

# --- Receipt store (python: lstat-based ownership/symlink checks) ---------
umask 077
rc=0
python3 -I - "$SUB" "${HOME%/}" "$REPO_REAL" "$CHANGE_ID" "$MB" "$HEAD_SHA" "$BASE_REF" \
  "$LANES" "$RIGOR" "$VERDICT" <<'PY' || rc=$?
import hashlib, json, os, stat, sys, tempfile, time

sub, home, repo, change_id, mb, head, base_ref, lanes, rigor, verdict = sys.argv[1:11]
uid = os.getuid()


def refuse(msg):
    sys.stderr.write("review-receipt: refused: %s\n" % msg)
    sys.exit(2)


def owned_dir(path, create):
    """Return True when path is a real directory owned by us (created 0700 if
    create and absent), False when absent and not create; refuse otherwise."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        if not create:
            return False
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            pass
        except OSError as e:
            refuse("cannot create %s: %s" % (path, e.strerror))
        st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode):
        refuse("%s is a symlink" % path)
    if not stat.S_ISDIR(st.st_mode):
        refuse("%s is not a directory" % path)
    if st.st_uid != uid:
        refuse("%s is not owned by the current user" % path)
    return True


repo_key = hashlib.sha256(repo.encode()).hexdigest()
levels = [os.path.join(home, ".mtk"), os.path.join(home, ".mtk", "receipts"),
          os.path.join(home, ".mtk", "receipts", repo_key)]
target = os.path.join(levels[-1], change_id + ".json")

if sub == "write":
    for d in levels:
        owned_dir(d, True)
    # The two inner levels are ours alone: tighten them if they predate us.
    for d in levels[1:]:
        if stat.S_IMODE(os.lstat(d).st_mode) != 0o700:
            os.chmod(d, 0o700)
    try:
        st = os.lstat(target)
        if stat.S_ISLNK(st.st_mode):
            refuse("%s is a symlink" % target)
        if not stat.S_ISREG(st.st_mode):
            refuse("%s is not a regular file" % target)
    except FileNotFoundError:
        pass
    receipt = {
        "schema": 1,
        "change_id": change_id,
        "merge_base": mb,
        "head": head,
        "base_ref": base_ref,
        "lanes": [x for x in lanes.split(",") if x],
        "rigor": rigor.upper(),
        "verdict": verdict,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    fd, tmp = tempfile.mkstemp(prefix=".receipt-", suffix=".tmp", dir=levels[-1])
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(receipt, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    print(target)
    sys.exit(0)

# check: a receipt counts only through owned, non-symlink levels, as a regular
# owned file whose content names this change id with a PASS verdict.
for d in levels:
    if not owned_dir(d, False):
        sys.exit(1)
try:
    st = os.lstat(target)
except FileNotFoundError:
    sys.exit(1)
if stat.S_ISLNK(st.st_mode):
    refuse("%s is a symlink" % target)
if not stat.S_ISREG(st.st_mode) or st.st_uid != uid:
    refuse("%s is not a regular file owned by the current user" % target)
try:
    with open(target, "r") as fh:
        data = json.load(fh)
except (OSError, ValueError):
    sys.exit(1)
if not isinstance(data, dict) or data.get("change_id") != change_id or data.get("verdict") != "PASS":
    sys.exit(1)
sys.exit(0)
PY

case "$rc" in
  0) ;;
  1) ;;
  *) exit 2 ;;
esac

if [ "$SUB" = "write" ]; then
  exit 0
fi

COUNT="$(git rev-list --count "$MB..$HEAD_SHA" 2>/dev/null)" || COUNT=""
case "$COUNT" in ''|*[!0-9]*) die "could not count commits in $MB..$HEAD_SHA" ;; esac

if [ "$rc" -eq 0 ] || [ "$COUNT" -eq 0 ]; then
  printf 'receipt: covered change_id=%s\n' "$CHANGE_ID"
  exit 0
fi

printf 'receipt: missing change_id=%s range=%s..%s commits=%s\n' \
  "$CHANGE_ID" "${MB:0:12}" "${HEAD_SHA:0:12}" "$COUNT"
git log --no-color --no-decorate --oneline --max-count="$MAX_LOG_LINES" "$MB..$HEAD_SHA" 2>/dev/null || true
if [ "$COUNT" -gt "$MAX_LOG_LINES" ]; then
  printf '... and %s more\n' "$((COUNT - MAX_LOG_LINES))"
fi
exit 1
