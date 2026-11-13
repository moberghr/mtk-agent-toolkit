#!/usr/bin/env bash
# Seeds a git repo with a batch CSV import that is not restart-safe.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

mkdir -p .claude
printf 'python\n' > .claude/tech-stack
cat > AGENTS.md <<'DOC'
# order-import

Python 3.12 nightly job that imports order CSV files into the reporting database.

## Build & Test

    python -m pytest -q
DOC
printf '@AGENTS.md\n' > CLAUDE.md

mkdir -p inbox "done"
cat > import_job.py <<'SRC'
import csv
import shutil
from pathlib import Path

BATCH_SIZE = 500


def run(db, inbox=Path("inbox"), done=Path("done")):
    for path in sorted(inbox.glob("*.csv")):
        with path.open(newline="") as fh:
            batch = []
            for row in csv.DictReader(fh):
                batch.append(row)
                if len(batch) == BATCH_SIZE:
                    db.insert_rows("orders", batch)
                    batch = []
            if batch:
                db.insert_rows("orders", batch)
        shutil.move(str(path), done / path.name)
SRC
touch inbox/.keep done/.keep
git add -A
git commit -q -m "Add nightly order import"
