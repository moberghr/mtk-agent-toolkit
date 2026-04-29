# Pressure Test — PreCompact Snapshot Hook

> Adversarial test for `hooks/pre-compact-snapshot.sh`.
> The hook must never block compaction, never lose data, and never interfere with in-flight git operations.

## Setup

```bash
cd "$(mktemp -d)"
git init -q
git commit --allow-empty -q -m "init"
HOOK="$OLDPWD/hooks/pre-compact-snapshot.sh"
```

## Scenarios

### S1 — Dirty tree, auto-compaction → snapshot saved

```bash
echo "work-in-progress" > a.txt
echo '{"trigger":"auto"}' | bash "$HOOK"
git stash list | grep mtk-precompact   # must show one stash
cat a.txt                              # must still contain "work-in-progress"
cat .claude/observability/precompact-snapshots.log  # must contain "saved"
```

**Pass:** stash exists, working tree unchanged, log entry recorded.
**Fail:** any of those missing.

### S2 — Clean tree → no snapshot

```bash
git add a.txt && git commit -q -m "save"
echo '{"trigger":"auto"}' | bash "$HOOK"
git stash list | grep mtk-precompact && echo "FAIL: stash created on clean tree"
```

**Pass:** no stash, no log entry.

### S3 — Manual /compact → no snapshot

```bash
echo "more work" >> a.txt
echo '{"trigger":"manual"}' | bash "$HOOK"
git stash list | grep mtk-precompact && echo "FAIL: stash on manual compact"
```

**Pass:** no stash created. Manual compaction is user-initiated; the user owns the choice to save or not.

### S4 — Rebase in progress → skipped

```bash
# Simulate by touching the marker file
GIT_DIR="$(git rev-parse --git-dir)"
mkdir -p "$GIT_DIR/rebase-merge"
echo "more work" >> a.txt
echo '{"trigger":"auto"}' | bash "$HOOK"
git stash list | grep mtk-precompact && echo "FAIL: stashed during rebase"
grep "skipped" .claude/observability/precompact-snapshots.log  # must show skip
rm -rf "$GIT_DIR/rebase-merge"
```

**Pass:** no stash, log records skipped reason.

### S5 — Untracked files only → snapshot saved

```bash
echo "new file" > untracked.txt
echo '{"trigger":"auto"}' | bash "$HOOK"
git stash list | grep mtk-precompact   # must show stash
[ -f untracked.txt ]                   # must still exist after re-apply
```

**Pass:** untracked files captured and restored.

### S6 — Not a git repo → silent exit

```bash
cd "$(mktemp -d)"
echo '{"trigger":"auto"}' | bash "$HOOK"
echo "exit=$?"   # must be 0
```

**Pass:** exit 0, no error output, no log file created.

### S7 — Empty stdin → still safe

```bash
bash "$HOOK" < /dev/null
echo "exit=$?"   # must be 0
```

**Pass:** treats missing payload as auto-compaction (default), runs normally.

## Recovery flow

### S8 — `mtk-recover.sh` lists and applies

```bash
# After S1
echo "q" | bash scripts/mtk-recover.sh   # must list one snapshot, exit 0
```

**Pass:** snapshot is listed with `present` status.

## Red flags

- Hook exits non-zero on any input (must always exit 0)
- Stash created but working tree modified (apply must succeed)
- Log file written outside `.claude/observability/`
- Hook delays compaction more than 8 seconds
- Hook runs `git stash drop` automatically (recovery is the engineer's choice)
