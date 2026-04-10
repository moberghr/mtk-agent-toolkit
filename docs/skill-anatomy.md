# Skill Anatomy

This document defines the structure and expectations for skills in this repository.

## File Location

Every skill lives in its own directory under `.claude/skills/`:

```text
.claude/skills/
  skill-name/
    SKILL.md
```

## Required Frontmatter

```yaml
---
name: skill-name
description: What this skill does and when to use it.
---
```

Rules:

- `name` must be lowercase and hyphen-separated
- `name` should match the directory name
- `description` should explain both what the skill does and when it applies

## Required Sections

1. `# Title`
2. `## Overview`
3. `## When To Use`
4. `## Workflow`
5. `## Verification`

## Strongly Recommended Sections

1. `### When NOT To Use`
2. `## Common Rationalizations`
3. `## Red Flags`
4. `## Rules`

## Authoring Principles

1. Process over reference text
2. Specific steps over vague guidance
3. Evidence over assumption
4. Anti-rationalization for any step an agent might skip
5. Progressive disclosure — keep shared checklist material in references when possible; load references at the phase where they are first needed, not all upfront
6. Cross-reference related skills instead of duplicating workflow logic
7. **CSO principle (Condition-based Skill Descriptions):** Descriptions must trigger on conditions, not summarize workflows. A workflow summary causes the agent to follow the description instead of reading the full SKILL.md. Write descriptions that answer "when should this activate?" not "what does this do?"
   - Bad: "Create an executable feature spec with manifests and batches"
   - Good: "Use when the task is a new feature, breaking change, or multi-file change"
8. **Self-escalation:** Skills and agents should explicitly permit stopping with BLOCKED or NEEDS_CONTEXT status rather than producing uncertain output

## Good Skill Boundaries

- Planning skill: produces specs, manifests, approvals
- Implementation skill: executes approved work in batches
- Debugging skill: reproduces, narrows, fixes, verifies
- Review skill: defines review priorities and reporting
- Security skill: enforces trust-boundary and compliance discipline

## Bad Skill Boundaries

- One skill containing the entire end-to-end lifecycle
- One-off skills tied to one command's reporting format
- Skills that duplicate installation or release mechanics
