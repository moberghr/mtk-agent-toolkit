---
description: Contract for trigger/strength frontmatter on .claude/rules/*.md, consumed by hooks/rule-trigger.sh
globs: [".claude/rules/**"]
alwaysApply: false
---

# Rule Frontmatter Contract

`.claude/rules/*.md` files carry two layers of metadata:

| Layer | Keys | Consumed by | When it acts |
|---|---|---|---|
| **Wake-up** | `paths`, `axes` | the model, via `INDEX.md` | model decides to read a rule |
| **Trigger** | `trigger`, `strength` | `hooks/rule-trigger.sh` | a tool call actually matches |

The wake-up layer is an *instruction* — the model is asked to pull the right rule. Under
context pressure an instruction is a suggestion. The trigger layer binds the same rule to
the moment it is needed, deterministically, and is what this document specifies.

## Schema

```yaml
---
paths:                       # existing wake-up layer, unchanged
  - "hooks/**"
axes:
  decision: process
  topic: hooks
  scope: global
trigger:                     # optional — omit and the rule is never hook-delivered
  tool: "Edit|Write"         # REQUIRED inside trigger. ERE alternation, or "*" for any
  pattern: "rm[[:space:]]+-rf"   # optional. ERE matched against the haystack (below)
  path: "^(hooks|scripts)/"      # optional. ERE matched against the repo-relative path
strength: inject             # optional, default `inject`
---
```

### `trigger.tool` (required when `trigger` is present)

Extended-regex alternation anchored to the whole tool name: `Bash`, `Edit|Write`, `*`.
**A rule with no `trigger.tool` is omitted from `triggers.index` entirely** — it is not
given a wildcard row, because a wildcard would fire the rule on every tool call.

### The haystack that `pattern` matches

| Tool | Haystack |
|---|---|
| `Bash` | the command string |
| everything else | the target file path |

### `trigger.path`

Matched against the **repo-relative** path and **ANDed** with `pattern`. Use it to scope a
content rule to a subtree. Path matching tolerates macOS case-insensitive filesystems: the
same checkout can present as `/Users/x/Dev/repo` and `/Users/x/dev/repo`, and the hook
retries the prefix strip case-insensitively so path rules do not silently stop matching.

### `strength`

| Value | Behaviour | Exit |
|---|---|---|
| `inject` (default) | Advisory. Delivers the rule text; never blocks. Re-delivers on every match. | 0 |
| `require-read` | Blocks **once** with the rule text, records delivery, then lets the retry through. | 2, then 0 |
| `block` | Blocks every matching call. | 2 |

**A blocking strength always ships the rule text with the denial.** This is not a courtesy.
A block that withholds its reason leaves the model guessing at what compliance looks like
and measurably destroys task completion; a block that explains itself does not. Same
principle as `hooks/scope-guard.sh`, which prints the offending path *and* the remedy.

Default to `inject`. Promoting a rule to `block` changes the behaviour of every session in
every repo that installs the toolkit — treat it as a reviewed change, not a tweak.

## Delivery state and compaction re-arm

`require-read` deliveries are recorded in a per-repo temp ledger so the rule does not block
the same session repeatedly.

Compaction invalidates that ledger: a rule delivered *before* a compaction was summarised
away along with everything else, so the ledger would claim it is still in context when it
is not. The `SessionStart` hook with matcher `compact` runs
`hooks/rule-trigger.sh --rearm`, which clears the ledger so each rule fires again the next
time its trigger matches.

## Regenerating the index

`.claude/rules/triggers.index` is generated — never hand-edited:

```bash
bash scripts/build-rule-index.sh          # regenerate INDEX.md + triggers.index
bash scripts/build-rule-index.sh --check  # CI: fail if either is stale
```

`scripts/validate-toolkit.sh` runs the `--check` form, so a rule edited without
regenerating fails validation.

Columns are tab-separated: `name`, `tool`, `pattern`, `path`, `strength`, `source`.

## Writing patterns

- The value after `key:` is taken **verbatim** to end-of-line, with surrounding quotes
  stripped. Do not double-escape: write `\.` for a literal dot, not `\\.`.
- Prefer POSIX classes (`[[:space:]]`) over `\s` — the matcher is `grep -E`.
- Keep patterns specific. A rule that fires on every `Edit` is worse than no rule: it
  spends context on every call and trains the reader to ignore the channel.

## Fail-open contract

`rule-trigger.sh` runs on every matching tool call. Malformed frontmatter, a missing index,
an unreadable source file, or any unexpected error **must exit 0**. A broken rule degrades
delivery; it must never wedge a session. Only an intentional `block` / `require-read`
decision may exit 2.
