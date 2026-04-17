# Parallelism Patterns for MTK Skills

> Short reference for skill authors and entry-point orchestrators. When to issue tool
> calls in parallel, when to force sequential order, and the canonical patterns MTK
> uses for reference loading, reviewer agents, and deferred-tool hydration.

## Why this matters

Modern Claude models (Opus 4.7, Sonnet 4.6) can issue multiple tool calls in a
single message. Parallelism turns sequential waits into overlapped work:

- Three `Read` calls for three reference files go out in one turn, not three.
- Two independent reviewer agents (`test-reviewer`, `architecture-reviewer`) run
  concurrently in forked subagent contexts.
- Multiple deferred tools load with one `ToolSearch` call (`select:A,B,C`).

The model-level rule: **issue independent tool calls in the same message block
(multiple tool uses per response).** Sequential calls are for genuine
dependencies — later-tool input depends on earlier-tool output.

## When parallelism helps

| Pattern | Example |
|---|---|
| Read-many independent files | Phase 0 ref loading in `/mtk implement` |
| Fan out reviewers | Stage 2 review: `test-reviewer` + `architecture-reviewer` |
| Batch-load deferred tools | `ToolSearch` with `select:AskUserQuestion,TaskCreate,TaskUpdate` |
| Parallel `Glob` + `Grep` | Discover file paths and search their contents together |
| Diff + branch + log inspection | `git diff`, `git branch --show-current`, `git log` — all unrelated |

## When parallelism hurts

| Anti-pattern | Why |
|---|---|
| Writing two edits to the same file in parallel | Last write wins, losing one edit |
| `Read` → parse → `Read` of a path found inside the first | Second read depends on the first |
| Parallel `Bash` calls that race on the same working-dir state | Build, test, or fs races |
| Interactive prompts (`AskUserQuestion`) in parallel with other work | Human can't answer two questions at once |

Rule of thumb: if Call B's input would mention Call A's output, they cannot be parallel.

## Canonical patterns used by MTK

### Pattern 1 — Parallel reference loading

When an entry skill's Phase 0 needs coding guidelines, the security checklist,
and architecture principles, load all three in one message:

```
Read(.claude/references/dotnet/coding-guidelines.md)
Read(.claude/references/security-checklist.md)
Read(.claude/references/architecture-principles.md)
```

All three as separate tool uses in the same assistant turn. Do not stream them sequentially.

### Pattern 2 — Parallel Stage 2 review

`test-reviewer` and `architecture-reviewer` operate on orthogonal axes and do
not share state. Spawn them in one message:

```
Agent(subagent_type: "test-reviewer",        prompt: …)
Agent(subagent_type: "architecture-reviewer", prompt: …)
```

Stage 1 (`compliance-reviewer`) stays sequential — it gates Stage 2. Stage 2
inside itself is parallel.

### Pattern 3 — Deferred-tool batch load

When multiple deferred tools are needed (e.g. `AskUserQuestion` + task tools),
one `ToolSearch` call loads them all:

```
ToolSearch(query: "select:AskUserQuestion,TaskCreate,TaskUpdate,TaskList")
```

Do not loop one at a time.

### Pattern 4 — Parallel discovery

When opening an unfamiliar area, issue the discovery tools together:

```
Glob(pattern: "**/*Handler.cs")
Grep(pattern: "IRequestHandler<",  type: "cs")
Read(CLAUDE.md)
Read(.claude/tech-stack)
```

The results compose cleanly because none of them depend on each other.

## Pitfall: parallel `Agent` calls with overlapping output contracts

Two subagents can both try to `Write` the same artifact if their prompts don't
carve up responsibilities. Always assign a distinct output contract per agent
(e.g. "test-reviewer produces a `test-coverage-report.md` section;
architecture-reviewer produces a `boundary-report.md` section"). Or collect
findings in-memory and merge after both return.

## Measurement

A crude check: after running a batched operation, estimate how many
round-trips would have been needed if sequential. Three refs loaded in parallel
= one RTT instead of three. If your batch shows no savings, you probably had
hidden dependencies.

## References

- Anthropic tool-use docs — "making multiple tool calls in parallel."
- `.claude/skills/context-engineering/SKILL.md` — `## Parallel Loading` section
  directs skill authors to this doc.
- `.claude/skills/implement/SKILL.md` — Phase 0 and Phase 4 Stage 2 apply the
  patterns above.
