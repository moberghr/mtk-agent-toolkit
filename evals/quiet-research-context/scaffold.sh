#!/usr/bin/env bash
# Seeds a git repo with two Pydantic 1.10 models and the pinned requirement.
set -euo pipefail
git init -q -b main .
git config user.email eval@example.com
git config user.name Eval

mkdir -p .claude
printf 'python\n' > .claude/tech-stack
cat > AGENTS.md <<'DOC'
# customers

Python 3.12 customer data models shared by the order services.

## Build & Test

    python -m pytest -q
DOC
printf '@AGENTS.md\n' > CLAUDE.md

cat > requirements.txt <<'SRC'
pydantic==1.10.13
SRC
cat > models.py <<'SRC'
from pydantic import BaseModel, validator


class Customer(BaseModel):
    id: int
    email: str

    @validator("email")
    def email_has_at(cls, value):
        if "@" not in value:
            raise ValueError("invalid email")
        return value.lower()

    class Config:
        orm_mode = True


class Order(BaseModel):
    id: int
    customer_id: int
    total_cents: int
SRC
git add -A
git commit -q -m "Add customer and order models"
