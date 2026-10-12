#!/usr/bin/env bash
# Seeds a git repo with one small, working shell script to be explained.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

cat > backup.sh <<'SRC'
#!/usr/bin/env bash
set -euo pipefail
SRC_DIR=${1:?usage: backup.sh <dir> [dest]}
DEST=${2:-$HOME/backups}
KEEP=5

mkdir -p "$DEST"
stamp=$(date +%Y%m%d-%H%M%S)
name=$(basename "$SRC_DIR")
tar -czf "$DEST/$name-$stamp.tar.gz" -C "$(dirname "$SRC_DIR")" "$name"

ls -1t "$DEST"/"$name"-*.tar.gz | tail -n +$((KEEP + 1)) | while read -r old; do
  rm -- "$old"
done
SRC

cat > AGENTS.md <<'DOC'
# backup-tools

Small Bash utility repository.

## Build & Test

No automated tests.
DOC
printf '@AGENTS.md\n' > CLAUDE.md

chmod +x backup.sh
git add -A
git commit -q -m "Add backup script"
