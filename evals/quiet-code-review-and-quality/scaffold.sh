#!/usr/bin/env bash
# Seeds a git repo with a config loader, then leaves an uncommitted change that shortens the
# default timeout and adds an environment override.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

mkdir -p .claude
printf 'python\n' > .claude/tech-stack
cat > AGENTS.md <<'DOC'
# app-config

Python 3.12 configuration loader shared by the worker services.

## Build & Test

    python -m pytest -q
DOC
printf '@AGENTS.md\n' > CLAUDE.md

cat > config_loader.py <<'SRC'
DEFAULTS = {"timeout": 30, "retries": 3}


def load(overrides=None):
    cfg = dict(DEFAULTS)
    cfg.update(overrides or {})
    return cfg
SRC
git add -A
git commit -q -m "Add config loader"

cat > config_loader.py <<'SRC'
import os

DEFAULTS = {"timeout": 10, "retries": 3}


def load(overrides=None):
    cfg = dict(DEFAULTS)
    env_timeout = os.environ.get("APP_TIMEOUT")
    if env_timeout:
        cfg["timeout"] = int(env_timeout)
    cfg.update(overrides or {})
    return cfg
SRC
