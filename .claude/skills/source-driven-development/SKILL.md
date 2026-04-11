---
name: source-driven-development
description: Use when framework, SDK, or library behavior is unfamiliar or version-sensitive — verify from authoritative sources before implementing.
license: MIT
compatibility:
  - claude-code
  - cursor
  - codex
trigger: unfamiliar-api|version-sensitive|sdk-uncertainty|framework-behavior
skip_when: well-understood-local-patterns|no-external-dependencies
---

# Source-Driven Development

## Overview

When framework behavior matters, memory is not enough. Verify unfamiliar APIs against authoritative sources and call out anything that remains unverified.

## When To Use

- New or unfamiliar .NET, EF Core, AWS SDK, or package APIs
- Version-sensitive framework behavior
- Performance or security-sensitive framework usage
- Conflicting assumptions between repo patterns and tool memory

### When NOT To Use

- Well-understood local code patterns already validated in the repo and unchanged by version differences

## Workflow

1. Identify the uncertain API or behavior.
2. Check whether the repo already demonstrates the same API safely.
3. If not, consult authoritative documentation.
4. Distinguish clearly between:
   - verified from source
   - inferred from local codebase pattern
   - still uncertain
5. Implement only after the uncertainty is resolved or explicitly surfaced.

## Rules

- Do not present guessed framework behavior as fact.
- Prefer authoritative sources over memory.
- If the behavior cannot be verified, state that plainly.

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "This API probably behaves like the last one I used" | Similar names cause production bugs. Verify the actual contract. |
| "The repo uses something like this, so it's fine" | Similar is not identical. Check the exact API and version. |
| "I'll fix it if it breaks" | Source checks are cheaper than post-failure recovery. |

## Red Flags

- New framework usage with no evidence behind it
- Version-sensitive assumptions stated as certainty
- Security or transaction behavior guessed from memory

## Verification

- [ ] Uncertain APIs were identified
- [ ] Authoritative sources or proven repo patterns were used
- [ ] Remaining uncertainty, if any, was surfaced explicitly
