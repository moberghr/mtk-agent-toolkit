#!/usr/bin/env bash
# Seeds a git repo with a summary helper whose output limit is counted in model tokens.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

mkdir -p .claude
printf 'python\n' > .claude/tech-stack
cat > AGENTS.md <<'DOC'
# release-notes

Python 3.12 tool that drafts release-note summaries from merged pull requests.

## Build & Test

    python -m pytest -q
DOC
printf '@AGENTS.md\n' > CLAUDE.md

cat > summarize.py <<'SRC'
MAX_TOKENS = 2000


def build_request(pull_requests):
    text = "\n".join("- " + pr["title"] for pr in pull_requests)
    return {
        "max_tokens": MAX_TOKENS,
        "prompt": "Summarize these merged pull requests as release notes:\n" + text,
    }
SRC
git add -A
git commit -q -m "Add release-note summary request"
